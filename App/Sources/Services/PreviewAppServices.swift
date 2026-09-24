// DEBUG only: an in-memory `AppServices` for SwiftUI previews and view/model tests. It holds
// whatever state the caller sets (readings included — it never makes one up, S1) and records the
// calls it receives, so a test can assert what the UI asked for. Nothing here talks to Bluetooth,
// the Keychain, the network, Trio or the notification center.

#if DEBUG
import AlertEngine
import Foundation
import GlucoseCore
import GlucoseStore
import NightscoutKit
import WidgetCore

@MainActor
final class PreviewAppServices: AppServices {
    /// Calls received, in order, e.g. "pair(1234)", "setTrioBridgeEnabled(true)".
    private(set) var calls: [String] = []

    var readingsStore: [GlucoseReading]
    var latestLiveReading: GlucoseReading?
    var previousLiveReading: GlucoseReading?
    var clockMismatchLatchedFor: Date?
    var sensorState: SensorState
    var sensorSession: SensorSession?
    var canStopSession = false
    var hasStoredSensor = false
    var storedSensorSerial: String?
    var acceptedCalibrationRange: ClosedRange<Int>? = 40...400
    var recentCalibrations: [CalibrationRecord] = []
    var trio: TrioBridgeSummary = .off
    var nightscout = NightscoutSummary(siteURL: nil, hasToken: false, upload: .off)
    var dexcomShare = DexcomShareSummary(accountName: nil, hasPassword: false, receiverSerialNumber: nil, region: .us, upload: .off)
    var historyImport: HistoryImportState?
    var alertSettings = AlertSettings.defaults
    var alertDelivery = AlertDeliveryReport.unknown
    var bluetoothAuthorization = BluetoothAuthorization.notDetermined
    var storage = StorageStatus(availability: .open, summary: nil, retention: .default, lastPurgeAt: nil, lastPurgeRemoved: 0)
    var accent = AccentChoice.default
    var forceQuitGap: ForceQuitGapReport?
    var replay = ReplayStatus.none
    /// Set to make `pair(code:)` / `submitCalibration(_:)` fail.
    var pairingError: PairingError?
    var calibrationRefusal: CalibrationRefusal?

    private var observers: [UUID: AsyncStream<ServiceChange>.Continuation] = [:]

    /// - Parameter readings: stored readings (any source), ascending or not; the caller also sets
    ///   `latestLiveReading` / `previousLiveReading` as a store would report them.
    init(readings: [GlucoseReading] = [], sensorState: SensorState = .notPaired, sensorSession: SensorSession? = nil) {
        self.readingsStore = readings.sorted { $0.date < $1.date }
        self.sensorState = sensorState
        self.sensorSession = sensorSession
    }

    /// Tells observers something changed (tests set a property, then call this).
    func send(_ change: ServiceChange) {
        for continuation in observers.values { continuation.yield(change) }
    }

    func changes() -> AsyncStream<ServiceChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: ServiceChange.self, bufferingPolicy: .unbounded)
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.observers[id] = nil }
        }
        return stream
    }

    func readings(from start: Date, to end: Date) async throws -> [GlucoseReading] {
        readingsStore.filter { $0.date >= start && $0.date < end }
    }

    func updateClockMismatchLatch(now: Date) {
        calls.append("updateClockMismatchLatch")
    }

    func pair(code: String) async throws(PairingError) {
        calls.append("pair(\(code))")
        if let pairingError { throw pairingError }
        sensorState = .searching
        send(.sensor)
    }

    func pairAgain(code: String) async throws(PairingError) {
        calls.append("pairAgain(\(code))")
        if let pairingError { throw pairingError }
        sensorState = .searching
        send(.sensor)
    }

    func forgetSensor() async {
        calls.append("forgetSensor")
        sensorState = .notPaired
        sensorSession = nil
        hasStoredSensor = false
        storedSensorSerial = nil
        send(.sensor)
    }

    func submitCalibration(_ request: CalibrationRequest) async throws(CalibrationRefusal) {
        calls.append("submitCalibration(\(request.mgdl))")
        if let calibrationRefusal {
            recentCalibrations.insert(CalibrationRecord(request: request, status: nil, refusal: CalibrationRefusalReason(calibrationRefusal), updatedAt: request.takenAt), at: 0)
            send(.calibration)
            throw calibrationRefusal
        }
        recentCalibrations.insert(CalibrationRecord(request: request, status: .queued, refusal: nil, updatedAt: request.takenAt), at: 0)
        send(.calibration)
    }

    func setTrioBridgeEnabled(_ enabled: Bool) async {
        calls.append("setTrioBridgeEnabled(\(enabled))")
        trio.isEnabled = enabled
        send(.trio)
    }

    func saveNightscout(url: String, token: String?) async throws(ServiceConfigurationError) {
        calls.append("saveNightscout")
        do {
            nightscout.siteURL = try NightscoutSite(url).baseURL.absoluteString
        } catch {
            throw .invalidNightscoutURL(String(describing: error))
        }
        if let token { nightscout.hasToken = !token.isEmpty }
        nightscout.upload.isConfigured = nightscout.hasToken
        send(.uploads)
    }

    func setNightscoutUploadEnabled(_ enabled: Bool) async {
        calls.append("setNightscoutUploadEnabled(\(enabled))")
        nightscout.upload.isEnabled = enabled
        send(.uploads)
    }

    func saveDexcomShare(accountName: String, password: String?, receiverSerialNumber: String) async throws(ServiceConfigurationError) {
        calls.append("saveDexcomShare")
        guard !accountName.isEmpty, !receiverSerialNumber.isEmpty, password.map({ !$0.isEmpty }) ?? dexcomShare.hasPassword else {
            throw .incompleteDexcomShareCredentials
        }
        dexcomShare.accountName = accountName
        dexcomShare.receiverSerialNumber = receiverSerialNumber
        dexcomShare.hasPassword = true
        dexcomShare.upload.isConfigured = true
        send(.uploads)
    }

    func setDexcomShareRegion(_ region: DexcomShareRegion) async {
        calls.append("setDexcomShareRegion(\(region.rawValue))")
        dexcomShare.region = region
        send(.uploads)
    }

    func setDexcomShareEnabled(_ enabled: Bool) async {
        calls.append("setDexcomShareEnabled(\(enabled))")
        dexcomShare.upload.isEnabled = enabled
        send(.uploads)
    }

    func retryUploads() async {
        calls.append("retryUploads")
    }

    func startNightscoutImport(scope: NightscoutImportScope) {
        calls.append("startNightscoutImport")
        historyImport = HistoryImportState(
            origin: .nightscout, phase: .running, readingsImported: 0, readingsSkippedByStore: 0, coveredFrom: nil, coveredTo: nil,
            skipped: [:], rejectedFutureDated: 0, startedAt: Date(), finishedAt: nil
        )
        send(.historyImport)
    }

    func startClarityImport(fileData: Data, timeZone: TimeZone) {
        calls.append("startClarityImport(\(timeZone.identifier))")
        historyImport = HistoryImportState(
            origin: .clarityCSV, phase: .running, readingsImported: 0, readingsSkippedByStore: 0, coveredFrom: nil, coveredTo: nil,
            skipped: [:], rejectedFutureDated: 0, startedAt: Date(), finishedAt: nil
        )
        send(.historyImport)
    }

    func cancelHistoryImport() {
        calls.append("cancelHistoryImport")
        historyImport?.phase = .cancelled
        send(.historyImport)
    }

    func updateAlertSettings(_ settings: AlertSettings) async {
        calls.append("updateAlertSettings")
        alertSettings = settings
        send(.alertSettings)
    }

    func refreshAlertDelivery() async {
        calls.append("refreshAlertDelivery")
    }

    func requestNotificationAuthorization() async {
        calls.append("requestNotificationAuthorization")
    }

    func requestUrgentLowAlarmAuthorization() async {
        calls.append("requestUrgentLowAlarmAuthorization")
    }

    func previewSound(_ sound: AlertSoundID) -> Bool {
        calls.append("previewSound(\(sound.rawValue))")
        return true
    }

    func stopSoundPreview() {
        calls.append("stopSoundPreview")
    }

    func handleAlertAction(_ action: AlertUserAction) async {
        calls.append("handleAlertAction(\(action))")
    }

    func setRetention(_ policy: RetentionPolicy) async {
        calls.append("setRetention(\(policy.rawValue))")
        storage.retention = policy
        send(.storage)
    }

    func refreshStorageSummary() async {
        calls.append("refreshStorageSummary")
    }

    func exportAllReadingsCSV() async throws -> URL {
        calls.append("exportAllReadingsCSV")
        return FileManager.default.temporaryDirectory.appendingPathComponent("preview-readings.csv")
    }

    func exportDiagnostics() async throws -> URL {
        calls.append("exportDiagnostics")
        return FileManager.default.temporaryDirectory.appendingPathComponent("preview-diagnostics.txt")
    }

    func setAccent(_ accent: AccentChoice) {
        calls.append("setAccent(\(accent.rawValue))")
        self.accent = accent
        send(.appearance)
    }

    func dismissForceQuitGap() {
        calls.append("dismissForceQuitGap")
        forceQuitGap = nil
        send(.health)
    }

    func startReplay(scenario: String, speed: Double) async {
        calls.append("startReplay(\(scenario))")
        replay.activeScenario = scenario
        replay.speed = speed
        send(.replay)
    }

    func stopReplay() async {
        calls.append("stopReplay")
        replay.activeScenario = nil
        replay.speed = nil
        send(.replay)
    }

    func setDeveloperLiveOutputsEnabled(_ enabled: Bool) async {
        calls.append("setDeveloperLiveOutputsEnabled(\(enabled))")
        replay.developerLiveOutputsEnabled = enabled
        send(.replay)
    }
}
#endif
