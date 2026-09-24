// The live `AppServices`: the sensor pipeline (G7Kit → GlucoseStore → gate → Trio, alerts, uploads,
// widget), its lifecycle, and the facade the UI reads. Built once by `AppEnvironment`.
//
// Lifecycle (docs/architecture.md "Lifecycle"):
// 1. init (early in launch): the G7 source already exists (CoreBluetooth state restoration); its
//    pipeline starts consuming at once and holds every event; `start(pairingCode: nil)`.
// 2. bootstrap, as soon as protected data is available (at once in a normal launch; after the first
//    unlock when iOS relaunched the app for Bluetooth after a reboot): preferences, the alert service
//    (restoring its snapshot), Trio, uploads and the widget are attached, the pipeline is activated
//    (held states flow), the store is opened and attached (held readings flow), the G7 source is
//    started again if it could not read its pairing before, Trio is re-seeded, the force-quit gap is
//    checked, retention runs.
// 3. Every processed batch is a wake: alert tick, widget, clock-mismatch check, pipeline heartbeat.
// 4. Foreground: permissions, alert tick, Trio retry, upload flush, retention, a 60 s ticker.
//
// Area-specific parts are in the LiveAppServices+*.swift extensions.

import AlertEngine
import CoreBluetooth
import Foundation
import G7Kit
import GlucoseCore
import GlucoseStore
import NightscoutKit
import UIKit
import WidgetCore

@MainActor
final class LiveAppServices: AppServices {
    /// Everything the composition root builds for this class.
    struct Dependencies {
        let g7: G7CGMSource
        let diagnostics: RingBufferDiagnosticLog
        let preferences: AppPreferences
        let credentials: any CredentialStore
        let trio: TrioCoordinator
        let uploads: UploadCoordinator
        let alertPorts: AlertPorts
        let widget: LiveWidgetPublisher?
        /// `Application Support/GlucoseStore/readings.sqlite` (PROGRESS D25).
        let databaseURL: URL
        let httpTransport: any HTTPTransport
        /// DEBUG: the launch argument `-replayScenario` (and options) to start with.
        let launchReplay: LaunchReplay?
    }

    struct LaunchReplay: Equatable {
        var scenario: String
        var speed: Double
        var startMinute: Double
    }

    // MARK: Components

    let g7: G7CGMSource
    let diagnostics: RingBufferDiagnosticLog
    let preferences: AppPreferences
    let credentials: any CredentialStore
    let trioCoordinator: TrioCoordinator
    let uploads: UploadCoordinator
    let alertPorts: AlertPorts
    let widget: LiveWidgetPublisher?
    let databaseURL: URL
    let httpTransport: any HTTPTransport
    let launchReplay: LaunchReplay?
    let systemClock = SystemAlertClock()
    let historyImports: HistoryImportCoordinator

    /// The G7 pipeline, for the whole process.
    let sensorPipeline: ReadingPipeline
    /// The production database, once open.
    private(set) var productionStore: GlucoseStore?
    /// The production alert service; nil before bootstrap and during a DEBUG replay run.
    var productionAlerts: AlertService?
    #if DEBUG
    var replayRun: ReplayRun?
    var replaySpeed: Double?
    #endif

    // MARK: State

    private var observers: [UUID: AsyncStream<ServiceChange>.Continuation] = [:]
    private(set) var isBootstrapped = false
    private var isBootstrapping = false
    var g7Started = false
    private var storeOpenError: String?
    private var isOpeningStore = false
    private var foregroundTicker: Task<Void, Never>?
    private var storeChangesTask: Task<Void, Never>?
    private var calibrationTask: Task<Void, Never>?
    private var protectedDataObserver: NSObjectProtocol?
    var launchedByBluetoothRestoration = false
    var pendingNotificationResponses: [(kind: NotificationResponseKind, userInfo: [String: String])] = []
    var lastTrioAlertInput: TrioBridgeStatus?
    private(set) var clockMismatch = ClockMismatchState.initial
    #if DEBUG
    var replayClockMismatch = ClockMismatchState.initial
    #endif

    // Facade values kept here (read by the UI).
    private(set) var recentCalibrations: [CalibrationRecord] = []
    private(set) var forceQuitGap: ForceQuitGapReport?
    var alertSettings = AlertSettings.defaults
    var alertDelivery = AlertDeliveryReport.unknown
    var storage = StorageStatus(availability: .opening, summary: nil, retention: .default, lastPurgeAt: nil, lastPurgeRemoved: 0)
    private(set) var accent = AccentChoice.default
    private(set) var hasStoredSensor = false
    private(set) var storedSensorSerial: String?
    var nightscoutHasToken = false
    var shareAccountName: String?
    var shareHasPassword = false

    init(_ dependencies: Dependencies) {
        g7 = dependencies.g7
        diagnostics = dependencies.diagnostics
        preferences = dependencies.preferences
        credentials = dependencies.credentials
        trioCoordinator = dependencies.trio
        uploads = dependencies.uploads
        alertPorts = dependencies.alertPorts
        widget = dependencies.widget
        databaseURL = dependencies.databaseURL
        httpTransport = dependencies.httpTransport
        launchReplay = dependencies.launchReplay
        historyImports = HistoryImportCoordinator(diagnostics: dependencies.diagnostics)
        sensorPipeline = ReadingPipeline(name: "sensor", source: dependencies.g7, diagnostics: dependencies.diagnostics, now: { Date() })

        sensorPipeline.onChange = { [weak self] change in self?.send(change) }
        sensorPipeline.onBatchProcessed = { [weak self] in self?.sensorBatchProcessed() }
        sensorPipeline.outputs.sensorStateProcessed = { [weak self] _ in
            Task {
                await self?.refreshStoredSensor()
                await self?.updateTrioHeartbeat()
            }
        }
        trioCoordinator.onChange = { [weak self] summary in self?.trioSummaryChanged(summary) }
        uploads.onChange = { [weak self] in self?.send(.uploads) }
        // Consume the G7 streams for the whole process (CGMSource stream rules), holding events
        // until bootstrap.
        sensorPipeline.startConsuming()
        calibrationTask = Task { [weak self, g7 = dependencies.g7] in
            for await update in g7.calibrationUpdates {
                self?.noteCalibration(update)
            }
        }
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.protectedDataDidBecomeAvailable()
            }
        }
        log(.app, "launch: G7 source created (restore id \(G7Configuration.defaultRestoreIdentifier))")
        Task { await self.startG7() }
    }

    // MARK: - Change notifications

    func changes() -> AsyncStream<ServiceChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: ServiceChange.self, bufferingPolicy: .unbounded)
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.observers[id] = nil }
        }
        return stream
    }

    func send(_ change: ServiceChange) {
        for continuation in observers.values { continuation.yield(change) }
    }

    // MARK: - Active source (the sensor, or a DEBUG replay run)

    var activePipeline: ReadingPipeline {
        #if DEBUG
        if let replayRun { return replayRun.pipeline }
        #endif
        return sensorPipeline
    }

    var activeStore: (any GlucoseReadingRepository)? { activePipeline.store }

    var activeAlerts: AlertService? {
        #if DEBUG
        if let replayRun { return replayRun.alerts }
        #endif
        return productionAlerts
    }

    var isReplaying: Bool {
        #if DEBUG
        return replayRun != nil
        #else
        return false
        #endif
    }

    /// D20: DEBUG builds keep the Trio bridge and uploaders off unless the developer switch is on.
    var liveOutputsAllowed: Bool {
        #if DEBUG
        return preferences.developerLiveOutputs
        #else
        return true
        #endif
    }

    // MARK: - Readings

    var latestLiveReading: GlucoseReading? { activePipeline.latestLiveReading }
    var previousLiveReading: GlucoseReading? { activePipeline.previousLiveReading }

    func readings(from start: Date, to end: Date) async throws -> [GlucoseReading] {
        guard let store = activeStore else { throw StoreNotOpen() }
        return try await store.readings(from: start, to: end)
    }

    struct StoreNotOpen: Error, CustomStringConvertible {
        var description: String { "The reading database is not open yet" }
    }

    var clockMismatchLatchedFor: Date? {
        #if DEBUG
        if isReplaying { return replayClockMismatch.latchedFor }
        #endif
        return clockMismatch.latchedFor
    }

    func updateClockMismatchLatch(now: Date) {
        #if DEBUG
        if let replayRun {
            // Replay time does not follow the phone's clocks: latch rule only, on replay time.
            let next = ClockMismatchMonitor.check(replayClockMismatch, latest: latestLiveReading, previous: previousLiveReading, now: replayRun.now(), uptime: nil)
            if next.latchedFor != replayClockMismatch.latchedFor { send(.health) }
            replayClockMismatch = next
            return
        }
        #endif
        guard isBootstrapped else { return }
        let next = ClockMismatchMonitor.check(clockMismatch, latest: latestLiveReading, previous: previousLiveReading, now: now, uptime: systemClock.uptime)
        if next.latchedFor != clockMismatch.latchedFor {
            log(.app, next.latchedFor.map { "clock mismatch latched for the reading at \($0.ISO8601Format())" } ?? "clock mismatch cleared")
            send(.health)
        }
        clockMismatch = next
        preferences.clockMismatch = next
    }

    // MARK: - Sensor

    var sensorState: SensorState { activePipeline.sensorState ?? .notPaired }
    var sensorSession: SensorSession? { activePipeline.sensorSession }
    var canStopSession: Bool { isReplaying ? false : G7CGMSource.supportsStopSession }

    func pair(code: String) async throws(PairingError) {
        guard !isReplaying else { throw .replayActive }
        do {
            try await g7.pair(code: code)
            g7Started = true
            log(.sensor, "pairing a new sensor")
        } catch let error as G7StartError {
            throw Self.pairingError(error)
        } catch {
            throw .credentialStoreFailed(String(describing: error))
        }
        await refreshStoredSensor()
        await updateTrioHeartbeat()
    }

    func pairAgain(code: String) async throws(PairingError) {
        guard !isReplaying else { throw .replayActive }
        do {
            try await g7.pairAgain(code: code)
            g7Started = true
            log(.sensor, "pairing the stored sensor again")
        } catch let error as G7StartError {
            // `.noSensorToPairAgain` is surfaced (the UI asks for a new sensor's code); never
            // silently turned into a new-sensor pairing (D37).
            throw Self.pairingError(error)
        } catch {
            throw .credentialStoreFailed(String(describing: error))
        }
        await refreshStoredSensor()
        await updateTrioHeartbeat()
    }

    static func pairingError(_ error: G7StartError) -> PairingError {
        switch error {
        case .invalidPairingCode: return .invalidCode
        case .credentialStoreFailed(let message): return .credentialStoreFailed(message)
        case .noSensorToPairAgain: return .noSensorToPairAgain
        }
    }

    func forgetSensor() async {
        await g7.forgetSensor()
        log(.sensor, "sensor forgotten")
        await refreshStoredSensor()
        await updateTrioHeartbeat()
        send(.sensor)
    }

    /// Re-reads whether the G7 source has a stored sensor; a change is a `.sensor` change.
    func refreshStoredSensor() async {
        let has = await g7.hasStoredSensor
        let serial = await g7.storedSensorSerial
        guard has != hasStoredSensor || serial != storedSensorSerial else { return }
        hasStoredSensor = has
        storedSensorSerial = serial
        send(.sensor)
    }

    func startG7() async {
        guard !isReplaying, !g7Started else { return }
        do {
            try await g7.start(pairingCode: nil)
            g7Started = true
        } catch {
            // Before the first unlock the pairing record cannot be read; the source reports
            // `.failed(credentialsUnavailable)` and is started again when protected data arrives.
            log(.sensor, "G7 start failed, retrying when protected data is available: \(error)")
        }
    }

    // MARK: - Calibration

    var acceptedCalibrationRange: ClosedRange<Int>? { isReplaying ? nil : g7.acceptedCalibrationRange }

    func submitCalibration(_ request: CalibrationRequest) async throws(CalibrationRefusal) {
        guard !isReplaying else { throw .notPaired }
        do throws(CalibrationRefusal) {
            try await g7.submitCalibration(request)
            record(CalibrationRecord(request: request, status: .queued, refusal: nil, updatedAt: Date()))
        } catch {
            record(CalibrationRecord(request: request, status: nil, refusal: CalibrationRefusalReason(error), updatedAt: Date()))
            throw error
        }
    }

    private func noteCalibration(_ update: CalibrationUpdate) {
        guard let index = recentCalibrations.firstIndex(where: { $0.request.id == update.requestID }) else {
            log(.sensor, "calibration update for an unknown request: \(update.status)")
            return
        }
        var changed = recentCalibrations[index]
        changed.status = update.status
        changed.updatedAt = Date()
        record(changed)
    }

    /// Keeps the 20 most recent, newest first, persisted (chart markers survive a relaunch).
    private func record(_ calibration: CalibrationRecord) {
        recentCalibrations.removeAll { $0.id == calibration.id }
        recentCalibrations.insert(calibration, at: 0)
        recentCalibrations = Array(recentCalibrations.sorted { $0.request.takenAt > $1.request.takenAt }.prefix(20))
        if isBootstrapped { preferences.recentCalibrations = recentCalibrations }
        send(.calibration)
    }

    // MARK: - DEBUG replay status (the controls are in LiveAppServices+Replay.swift)

    var replay: ReplayStatus {
        #if DEBUG
        return ReplayStatus(
            availableScenarios: ReplayScenarioNames.all,
            activeScenario: replayRun?.scenario.rawValue,
            speed: replayRun == nil ? nil : replaySpeed,
            developerLiveOutputsEnabled: isBootstrapped && preferences.developerLiveOutputs
        )
        #else
        return .none
        #endif
    }

    // MARK: - Permissions, appearance, health

    var bluetoothAuthorization: BluetoothAuthorization {
        switch CBCentralManager.authorization {
        case .allowedAlways: return .allowed
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    func setAccent(_ accent: AccentChoice) {
        self.accent = accent
        preferences.accent = accent
        widget?.accent = accent
        send(.appearance)
        Task { await activePipeline.publishWidget() }
    }

    func dismissForceQuitGap() {
        forceQuitGap = nil
        preferences.forceQuitGap = nil
        send(.health)
    }

    // MARK: - Bootstrap (protected data available)

    private func protectedDataDidBecomeAvailable() {
        log(.app, "protected data became available")
        Task {
            await bootstrap()
            await startG7()
            await openStoreIfNeeded()
        }
    }

    /// Runs once, as soon as protected data is available. See the file comment.
    func bootstrap() async {
        guard !isBootstrapped, !isBootstrapping else { return }
        guard UIApplication.shared.isProtectedDataAvailable else {
            storage.availability = .waitingForFirstUnlock(heldReadings: sensorPipeline.heldReadingCount)
            log(.app, "waiting for the first unlock: preferences, Keychain and database are unreadable until then")
            send(.storage)
            return
        }
        isBootstrapping = true
        defer { isBootstrapping = false }

        diagnostics.loadSaved()
        accent = preferences.accent
        widget?.accent = accent
        recentCalibrations = preferences.recentCalibrations
        clockMismatch = preferences.clockMismatch
        forceQuitGap = preferences.forceQuitGap
        storage.retention = preferences.retention
        storage.lastPurgeAt = preferences.lastPurgeAt
        historyImports.onChange = { [weak self] state, finished in self?.historyImportChanged(state, finished: finished) }
        if let last = preferences.lastHistoryImport { historyImports.restore(last) }
        detectForceQuitGap()
        loadSharingSecrets()

        // Alerts first, so the held states reach them in order.
        alertSettings = preferences.alertSettings
        let alerts = makeProductionAlerts()
        productionAlerts = alerts
        sensorPipeline.outputs.alerts = alerts
        await alerts.start()
        await connectIntentBridge()
        await deliverPendingNotificationResponses()
        alertDelivery = AlertDeliveryReport(of: alerts)
        send(.alertDelivery)

        trioCoordinator.configure(enabled: preferences.trioBridgeEnabled, liveOutputsAllowed: liveOutputsAllowed)
        trioCoordinator.start()
        await applyUploadConfiguration()
        sensorPipeline.outputs.widget = widget
        attachOutputs()
        await sendTrioAlertInput(force: true)

        isBootstrapped = true
        log(.app, "bootstrapped (launched by Bluetooth restoration: \(launchedByBluetoothRestoration))")
        sensorPipeline.activate()
        await openStoreIfNeeded()
        await startG7()
        await refreshStoredSensor()
        await updateTrioHeartbeat()
        updateClockMismatchLatch(now: Date())
        send(.health)

        #if DEBUG
        if let launchReplay {
            await startReplay(scenario: launchReplay.scenario, speed: launchReplay.speed, startingAtMinute: launchReplay.startMinute)
        }
        #endif
    }

    func makeProductionAlerts() -> AlertService {
        alertPorts.makeProductionService(
            settings: alertSettings, snapshot: preferences.alertEngineSnapshot, clock: PipelineAlertClock.system()
        ) { [weak self] snapshot in
            self?.preferences.alertEngineSnapshot = snapshot
        }
    }

    /// Attaches (or detaches) the Trio bridge and the uploaders to the active pipeline, following
    /// the user's switches and D20.
    func attachOutputs() {
        let trio = trioCoordinator.activeBridge
        let uploaders = uploads.activeUploaders
        let flush: @MainActor () -> Void = { [weak self] in self?.uploads.flushIfDue() }
        sensorPipeline.outputs.trio = trio
        sensorPipeline.outputs.uploaders = uploaders
        sensorPipeline.outputs.flushUploads = flush
        #if DEBUG
        if let replayRun {
            replayRun.pipeline.outputs.trio = trio
            replayRun.pipeline.outputs.uploaders = uploaders
            replayRun.pipeline.outputs.flushUploads = flush
        }
        #endif
        send(.trio)
        send(.uploads)
    }

    // MARK: - Store

    func openStoreIfNeeded() async {
        guard isBootstrapped, productionStore == nil, !isOpeningStore else { return }
        isOpeningStore = true
        defer { isOpeningStore = false }
        storage.availability = .opening
        send(.storage)
        do {
            let store = try await GlucoseStore.production(at: databaseURL, diagnostics: diagnostics)
            productionStore = store
            storeOpenError = nil
            sensorPipeline.attach(store: store)
            observeStoreChanges(store)
            log(.store, "database open at \(databaseURL.lastPathComponent)")
            updateStorageAvailability()
            await reseedTrio()
            await purgeIfDue()
            await refreshStorageSummary()
        } catch {
            storeOpenError = String(describing: error)
            log(.store, "database could not be opened: \(error)")
            updateStorageAvailability()
        }
    }

    private func observeStoreChanges(_ store: GlucoseStore) {
        let changes = store.changes()
        let pipeline = sensorPipeline
        storeChangesTask = Task {
            for await _ in changes {
                await pipeline.storeDidChange()
            }
        }
    }

    func updateStorageAvailability() {
        let next = StoreAvailability.derive(
            storeOpen: productionStore != nil, protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
            openError: storeOpenError, insertProblem: sensorPipeline.storeProblem, heldReadings: sensorPipeline.heldReadingCount
        )
        guard next != storage.availability else { return }
        storage.availability = next
        send(.storage)
    }

    // MARK: - Wakes and foreground

    /// After every batch of sensor events (each is a wake-up).
    private func sensorBatchProcessed() {
        updateClockMismatchLatch(now: Date())
        writePipelineHeartbeat()
        updateStorageAvailability()
    }

    /// Persists the last pipeline activity for force-quit gap detection (HANDOFF §4.6).
    func writePipelineHeartbeat() {
        guard isBootstrapped else { return }
        preferences.pipelineHeartbeat = PipelineHeartbeat(
            at: Date(), sensorWasActive: ForceQuitGapDetector.sensorIsActive(sensorPipeline.sensorState), boot: systemClock.uptime?.boot
        )
    }

    private func detectForceQuitGap() {
        let gap = ForceQuitGapDetector.gap(
            lastHeartbeat: preferences.pipelineHeartbeat, launchedByBluetoothRestoration: launchedByBluetoothRestoration,
            now: Date(), boot: systemClock.uptime?.boot
        )
        if let gap {
            forceQuitGap = gap
            preferences.forceQuitGap = gap
            log(.app, "no pipeline activity from \(gap.from.ISO8601Format()) to \(gap.to.ISO8601Format()) while the sensor was active: force-quit gap")
        }
    }

    /// The app came to the foreground.
    func handleForeground() async {
        await bootstrap()
        guard isBootstrapped else { return }
        await startG7()
        await openStoreIfNeeded()
        activePipeline.retryHeldEvents()
        await refreshAlertDelivery()
        await activeAlerts?.send(.tick)
        await trioCoordinator.retry(session: sensorPipeline.sensorSession)
        uploads.flushIfDue()
        await purgeIfDue()
        updateClockMismatchLatch(now: Date())
        writePipelineHeartbeat()
        startForegroundTicker()
    }

    func handleBackground() {
        foregroundTicker?.cancel()
        foregroundTicker = nil
        writePipelineHeartbeat()
        let diagnostics = self.diagnostics
        Task.detached(priority: .utility) { try? diagnostics.save() }
    }

    /// About once a minute while in the foreground: alert tick (docs/alerts.md §9), Trio retry
    /// (docs/trio-bridge.md: retry a failed write without waiting for a reading), clock check.
    private func startForegroundTicker() {
        guard foregroundTicker == nil else { return }
        foregroundTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                await self.activeAlerts?.send(.tick)
                if !self.isReplaying {
                    await self.trioCoordinator.retry(session: self.sensorPipeline.sensorSession)
                }
                self.updateClockMismatchLatch(now: Date())
                self.writePipelineHeartbeat()
            }
        }
    }

    // MARK: - Diagnostics

    func log(_ category: DiagnosticEvent.Category, _ message: String) {
        diagnostics.record(DiagnosticEvent(date: Date(), category: category, message: message))
    }
}

extension StoreAvailability {
    /// S5: what Settings and the storage banner show about the reading database.
    static func derive(storeOpen: Bool, protectedDataAvailable: Bool, openError: String?, insertProblem: String?, heldReadings: Int) -> StoreAvailability {
        if !storeOpen {
            if !protectedDataAvailable { return .waitingForFirstUnlock(heldReadings: heldReadings) }
            if let openError { return .failed(message: openError) }
            return .opening
        }
        if let insertProblem {
            return .failed(message: "\(heldReadings) reading(s) are held in memory: \(insertProblem)")
        }
        return .open
    }
}
