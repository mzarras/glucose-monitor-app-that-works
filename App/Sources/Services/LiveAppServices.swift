// The live `AppServices`: the sensor pipeline (G7Kit → GlucoseStore → gate → Trio, alerts, uploads,
// widget), its lifecycle, and the facade the UI reads. Built once by `AppEnvironment`.
//
// Lifecycle (docs/architecture.md "Lifecycle"):
// 1. init (early in launch): the G7 source already exists (CoreBluetooth state restoration); its
//    pipeline starts consuming at once and holds every event; `start(pairingCode: nil)`.
// 2. bootstrap, as soon as protected data is available (at once in a normal launch; after the first
//    unlock when iOS relaunched the app for Bluetooth after a reboot): preferences, the alert service
//    (restoring its snapshot), Trio, uploads and the widget are attached; the pipeline is activated
//    first — alerts and Trio get held and new readings at once — and the store is opened alongside
//    (readings wait in memory until it is, the D42 path); the G7 source is started again if it could
//    not read its pairing before; the force-quit gap is checked. Once the store is open: the latest
//    reading is read, the widget may publish and the clock latch may update (not before: the latest
//    reading is unknown until then, review B1), Trio is re-seeded, retention runs.
// 3. Every drain attempt is a wake: storage health and alert tick, widget, clock-mismatch check,
//    pipeline heartbeat.
// 4. Foreground: permissions, `.foreground` (expiry reminders, D43), drain attempt (storage, tick),
//    Trio retry, upload flush, retention, a 60 s ticker.
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
        /// The G7 source (`G7CGMSource`; a scripted double in launch-order tests).
        let g7: any SensorDevice
        let diagnostics: RingBufferDiagnosticLog
        let preferences: AppPreferences
        let credentials: any CredentialStore
        let trio: TrioCoordinator
        let uploads: UploadCoordinator
        let alertPorts: AlertPorts
        let widget: (any AppWidgetPublishing)?
        /// `Application Support/GlucoseStore/readings.sqlite` (PROGRESS D25).
        let databaseURL: URL
        let httpTransport: any HTTPTransport
        /// DEBUG: the launch argument `-replayScenario` (and options) to start with.
        let launchReplay: LaunchReplay?
        /// The phone clock (the pipeline's `now`, the alert engine's wall clock); tests inject one.
        var clock: @Sendable () -> Date = { Date() }
        /// The monotonic clock with its boot (clock-fault detection); nil where it does not apply.
        var uptime: @MainActor () -> Uptime? = { SystemAlertClock().uptime }
        /// Whether protected data (Keychain `AfterFirstUnlock`, files `completeUntilFirstUserAuthentication`)
        /// is readable — false before the first unlock after a reboot; tests simulate that.
        var isProtectedDataAvailable: @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable }
        /// Opens the production database; tests delay it or make it fail.
        var openStore: @Sendable (URL, any DiagnosticLog) async throws -> GlucoseStore = { url, diagnostics in
            try await GlucoseStore.production(at: url, diagnostics: diagnostics)
        }
        /// The foreground ticker's period (drain attempt, Trio retry, heartbeat, clock check); tests
        /// shorten it.
        var foregroundTickInterval: Duration = .seconds(60)
        /// D45/D47: the sensor connection settings file the G7 source was created with
        /// (`SensorConnectionSettings`; production: Application Support/SensorConnection.json).
        /// The default, a file in a fresh temporary directory, is for tests.
        var connectionSettings = SensorConnectionSettingsStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("SensorConnection-\(UUID().uuidString).json")
        )
        /// Review m5: what `connectionSettings` held when the G7 source was created — read once, by
        /// `AppEnvironment`, and handed to both. Nil: read it here (tests that need no source).
        var connectionLaunch: SensorConnectionSettingsLoad?
        /// Review m2/m3: the G7 source's credential store, which refuses deletions the person did not
        /// ask for. Nil where the source has no Keychain store (scripted tests).
        var credentialGuard: GuardedG7CredentialStore?
    }

    struct LaunchReplay: Equatable {
        var scenario: String
        var speed: Double
        var startMinute: Double
    }

    // MARK: Components

    let g7: any SensorDevice
    let diagnostics: RingBufferDiagnosticLog
    let preferences: AppPreferences
    let credentials: any CredentialStore
    let trioCoordinator: TrioCoordinator
    let uploads: UploadCoordinator
    let alertPorts: AlertPorts
    let widget: (any AppWidgetPublishing)?
    let databaseURL: URL
    let httpTransport: any HTTPTransport
    let launchReplay: LaunchReplay?
    /// The phone clock and the monotonic clock (see `Dependencies`).
    let now: @Sendable () -> Date
    let uptime: @MainActor () -> Uptime?
    private let openStore: @Sendable (URL, any DiagnosticLog) async throws -> GlucoseStore
    private let protectedDataAvailable: @MainActor () -> Bool
    private let foregroundTickInterval: Duration
    let connectionSettingsStore: SensorConnectionSettingsStore
    let credentialGuard: GuardedG7CredentialStore?
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
    private var bootstrapTask: Task<Void, Never>?
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
    /// False until the first `refreshStoredSensor` after bootstrap has read the source (B's onboarding
    /// baseline for "a sensor is stored now that was not before").
    private(set) var storedSensorKnown = false
    private(set) var storedSensorSerial: String?
    /// D45/D47, as saved (and as the G7 source was created with at launch).
    var connectionSettings = SensorConnectionSettings.defaults
    /// Review m2/m3: the connection setting cannot be trusted (the file was unreadable, or a failed
    /// switch could not be rolled back, or G7Kit was kept from deleting a pairing of the other mode).
    /// The source stays stopped until the person chooses Listen or Pair again; nil when fine.
    var connectionSettingProblem: String?
    /// False in listen mode (calibrate in the Dexcom app); read from the source.
    var supportsCalibration = true
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
        now = dependencies.clock
        uptime = dependencies.uptime
        openStore = dependencies.openStore
        protectedDataAvailable = dependencies.isProtectedDataAvailable
        foregroundTickInterval = dependencies.foregroundTickInterval
        connectionSettingsStore = dependencies.connectionSettings
        credentialGuard = dependencies.credentialGuard
        let loaded = dependencies.connectionLaunch ?? dependencies.connectionSettings.load()
        connectionSettings = loaded.settings
        supportsCalibration = loaded.settings.mode != .listen
        connectionSettingProblem = loaded.problem
        historyImports = HistoryImportCoordinator(diagnostics: dependencies.diagnostics)
        sensorPipeline = ReadingPipeline(name: "sensor", source: dependencies.g7, diagnostics: dependencies.diagnostics, now: dependencies.clock)
        // B1: no widget snapshot until the store is open — before that the latest reading is
        // unknown, and a snapshot without it would clear the widget's clock-mismatch latch.
        sensorPipeline.publishesWidget = false

        sensorPipeline.onChange = { [weak self] change in
            if change == .storage {
                self?.updateStorageAvailability()
            } else {
                self?.send(change)
            }
        }
        sensorPipeline.onBatchProcessed = { [weak self] in self?.sensorBatchProcessed() }
        // Audit m1: G7Kit's publication floor follows every successful store write.
        sensorPipeline.outputs.readingsStored = { [weak self] _ in
            Task { await self?.updateG7StoredFloor() }
        }
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
            // assumeIsolated is sound here: `queue: .main` makes NotificationCenter run this block
            // on OperationQueue.main, i.e. the main thread, whoever posts the notification (UIKit
            // posts it on the main thread anyway). The block's type is not @MainActor, so the
            // compiler cannot see that; assumeIsolated states it and traps if it is ever wrong
            // (e.g. someone changes `queue:` to nil), rather than racing silently.
            MainActor.assumeIsolated {
                self?.protectedDataDidBecomeAvailable()
            }
        }
        log(.app, "launch: G7 source created (restore id \(G7Configuration.defaultRestoreIdentifier)), \(connectionSettings.g7Mode.summary)"
            + (connectionSettings.recordsRawGlucosePackets ? ", raw glucose packet recording on (D47)" : ""))
        if let problem = loaded.problem {
            log(.sensor, "connection setting unreadable, the sensor is not connected until Listen or Pair is chosen again: \(problem)")
        }
        noteRefusedDeletion()
        logMonotonicClock()
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
        if isReplaying { return replayClockMismatch.latch(for: latestLiveReading) }
        #endif
        return clockMismatch.latch(for: latestLiveReading)
    }

    func updateClockMismatchLatch(now: Date) {
        #if DEBUG
        if let replayRun {
            // Replay time does not follow the phone's clocks: latch rule only, on replay time.
            let next = ClockMismatchMonitor.check(replayClockMismatch, latest: latestLiveReading, previous: previousLiveReading, now: replayRun.now(), uptime: nil)
            if next.latch(for: latestLiveReading) != replayClockMismatch.latch(for: latestLiveReading) { send(.health) }
            replayClockMismatch = next
            return
        }
        #endif
        guard isBootstrapped else { return }
        // B1: while the store is still opening the latest reading is unknown (only readings that
        // arrived since launch are known), so the persisted latch is left as it is. Once the open
        // has succeeded or failed the check runs: after a failed open, readings waiting for the
        // store are shown as the latest, and a clock change must still latch them (review m4). An
        // older reading never clears a latch held for a newer one (`ClockMismatchMonitor`).
        guard productionStore != nil || storeOpenError != nil else { return }
        let next = ClockMismatchMonitor.check(clockMismatch, latest: latestLiveReading, previous: previousLiveReading, now: now, uptime: uptime())
        if next.latchedFor != clockMismatch.latchedFor || next.olderLatched != clockMismatch.olderLatched {
            log(.app, next.latchedFor.map { "clock mismatch latched for the reading at \($0.ISO8601Format())" + (next.olderLatched.map { " and \($0.count) older" } ?? "") } ?? "clock mismatch cleared")
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
        case .notAvailableInListenMode: return .notAvailableInListenMode
        }
    }

    func forgetSensor() async {
        // The person's own action: G7Kit may delete the pairing (GuardedG7CredentialStore).
        if let credentialGuard {
            await credentialGuard.allowingDeletion { await g7.forgetSensor() }
        } else {
            await g7.forgetSensor()
        }
        log(.sensor, "sensor forgotten")
        // G7Kit's forget stops the source. In pairing mode it stays stopped until `pair(code:)`.
        // In listen mode ("Stop following this sensor", D45) no code is needed: look for the Dexcom
        // app's connection to the next sensor at once, or nothing would be followed until a relaunch.
        if isListening, !isReplaying {
            g7Started = false
            await startG7()
            log(.sensor, "listening again for the Dexcom app's connection to the next sensor")
        }
        await refreshStoredSensor()
        await updateTrioHeartbeat()
        send(.sensor)
    }

    /// Re-reads whether the G7 source has a stored sensor; a change is a `.sensor` change.
    func refreshStoredSensor() async {
        let has = await g7.hasStoredSensor
        let serial = await g7.storedSensorSerial
        // Before bootstrap the pairing record may be unreadable (first unlock): not yet known.
        let known = storedSensorKnown || isBootstrapped
        guard has != hasStoredSensor || serial != storedSensorSerial || known != storedSensorKnown else { return }
        let serialChanged = serial != storedSensorSerial
        hasStoredSensor = has
        storedSensorSerial = serial
        storedSensorKnown = known
        send(.sensor)
        if serialChanged { await updateG7StoredFloor() }
    }

    func startG7() async {
        guard !isReplaying, !g7Started else { return }
        // Review m2/m3: never started on a connection setting that cannot be trusted.
        guard connectionSettingProblem == nil else { return }
        do {
            try await g7.start(pairingCode: nil)
            g7Started = true
        } catch {
            // Before the first unlock the pairing record cannot be read; the source reports
            // `.failed(credentialsUnavailable)` and is started again when protected data arrives.
            log(.sensor, "G7 start failed, retrying when protected data is available: \(error)")
            noteRefusedDeletion()
        }
    }

    // MARK: - Calibration

    var acceptedCalibrationRange: ClosedRange<Int>? { isReplaying ? nil : g7.acceptedCalibrationRange }

    func submitCalibration(_ request: CalibrationRequest) async throws(CalibrationRefusal) {
        guard !isReplaying else { throw .notPaired }
        do throws(CalibrationRefusal) {
            try await g7.submitCalibration(request)
            record(CalibrationRecord(request: request, status: .queued, refusal: nil, updatedAt: now()))
        } catch {
            record(CalibrationRecord(request: request, status: nil, refusal: CalibrationRefusalReason(error), updatedAt: now()))
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
        changed.updatedAt = now()
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

    /// `UIApplication.protectedDataDidBecomeAvailableNotification` (the first unlock after a reboot).
    func protectedDataDidBecomeAvailable() {
        log(.app, "protected data became available")
        Task {
            await bootstrap()
            await startG7()
            await openStoreIfNeeded()
        }
    }

    /// Runs once, as soon as protected data is available (see the file comment). Concurrent callers
    /// (launch, foreground, protected-data notification) all wait for the one bootstrap.
    func bootstrap() async {
        if isBootstrapped { return }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        guard protectedDataAvailable() else {
            updateStorageAvailability()
            log(.app, "waiting for the first unlock: preferences, Keychain and database are unreadable until then")
            return
        }
        let task = Task { await self.performBootstrap() }
        bootstrapTask = task
        await task.value
    }

    private func performBootstrap() async {
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

        configureTrio()
        trioCoordinator.start()
        await applyUploadConfiguration()
        sensorPipeline.outputs.widget = widget
        attachOutputs()
        await sendTrioAlertInput(force: true)

        isBootstrapped = true
        log(.app, "bootstrapped (launched by Bluetooth restoration: \(launchedByBluetoothRestoration))")
        // Alerts and Trio first: the pipeline is activated before the store opens, so a slow open
        // (a long migration) never delays them. Readings that arrive before the store is open go to
        // Trio and the alert engine at once and are stored when it opens (the D42 path).
        sensorPipeline.activate()
        let storeOpening = Task { await self.openStoreIfNeeded() }
        await startG7()
        await refreshConnectionFromSource()
        await refreshStoredSensor()
        await updateTrioHeartbeat()
        updateClockMismatchLatch(now: now())
        await storeOpening.value
        for change in [ServiceChange.readings, .sensor, .calibration, .trio, .uploads, .historyImport, .alertSettings, .alertDelivery, .storage, .health, .appearance] {
            send(change)
        }

        #if DEBUG
        if let launchReplay {
            await startReplay(scenario: launchReplay.scenario, speed: launchReplay.speed, startingAtMinute: launchReplay.startMinute)
        }
        #endif
    }

    func makeProductionAlerts() -> AlertService {
        alertPorts.makeProductionService(
            settings: alertSettings, snapshot: preferences.alertEngineSnapshot, clock: PipelineAlertClock(now: now, uptime: uptime)
        ) { [weak self] snapshot in
            self?.preferences.alertEngineSnapshot = snapshot
        }
    }

    /// Attaches (or detaches) the Trio bridge and the uploaders to the active pipeline, following
    /// the user's switches and D20.
    func attachOutputs() {
        let trio = trioCoordinator
        // Read at the moment of use, so a replaced uploader is picked up and a released one is not
        // kept alive (Phase 2 review M2).
        let uploaders: @MainActor () -> [ReadingUploader] = { [weak self] in self?.uploads.activeUploaders ?? [] }
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
        // The first attempt shows "opening". A retry after a failed open (every wake retries) keeps
        // the failure showing until it succeeds: "opening" has no banner, so a slow retry must not
        // hide the storage problem (S5), nor make the banner flicker on every wake.
        if storeOpenError == nil {
            storage.availability = .opening
            send(.storage)
        }
        do {
            let store = try await openStore(databaseURL, diagnostics)
            productionStore = store
            storeOpenError = nil
            sensorPipeline.storeOpenFailingSince = nil
            sensorPipeline.attach(store: store)
            observeStoreChanges(store)
            log(.store, "database open at \(databaseURL.lastPathComponent)")
            updateStorageAvailability()
            await sensorPipeline.storeDidChange()
            // The latest reading is known now: the widget and the clock latch may be updated.
            sensorPipeline.publishesWidget = true
            await sensorPipeline.publishWidget()
            updateClockMismatchLatch(now: now())
            await reseedTrio()
            await updateG7StoredFloor()
            await purgeIfDue()
            await refreshStorageSummary()
        } catch {
            storeOpenError = String(describing: error)
            if protectedDataAvailable() {
                // D42: the storage-failure alert input, from the first failed open of this run.
                sensorPipeline.storeOpenFailingSince = sensorPipeline.storeOpenFailingSince ?? now()
            }
            log(.store, "database could not be opened: \(error)")
            updateStorageAvailability()
            // Readings held back from Trio at launch stay held: they go out with the next newer
            // reading (Phase 3 carry-over: never written alone, so Trio's newest never moves back).
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
            storeOpen: productionStore != nil, protectedDataAvailable: protectedDataAvailable(),
            openError: storeOpenError, insertProblem: sensorPipeline.storeProblem, heldReadings: sensorPipeline.heldReadingCount
        )
        guard next != storage.availability else { return }
        storage.availability = next
        send(.storage)
    }

    // MARK: - Wakes and foreground

    /// After every batch of sensor events (each is a wake-up).
    private func sensorBatchProcessed() {
        updateClockMismatchLatch(now: now())
        writePipelineHeartbeat()
        updateStorageAvailability()
        if isBootstrapped, productionStore == nil, storeOpenError != nil, protectedDataAvailable() {
            Task { await openStoreIfNeeded() }
        }
    }

    /// Persists the last pipeline activity for force-quit gap detection (HANDOFF §4.6).
    func writePipelineHeartbeat() {
        guard isBootstrapped else { return }
        preferences.pipelineHeartbeat = PipelineHeartbeat(
            at: now(), sensorWasActive: ForceQuitGapDetector.sensorIsActive(sensorPipeline.sensorState), boot: uptime()?.boot
        )
    }

    private func detectForceQuitGap() {
        let gap = ForceQuitGapDetector.gap(
            lastHeartbeat: preferences.pipelineHeartbeat, launchedByBluetoothRestoration: launchedByBluetoothRestoration,
            now: now(), boot: uptime()?.boot
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
        // A drain attempt: stores waiting readings, sends the storage health and a tick (D42).
        activePipeline.retryHeldEvents()
        // Re-reads permissions (and rebuilds pending reminders if notifications were just allowed in
        // iOS Settings), then `.foreground`: expiry reminders refused or dropped are added again
        // (D43). During a DEBUG replay run the replay service gets it (its reminders are the
        // replay's); production gets one when the run ends (LiveAppServices+Replay `resumeSensor`).
        await refreshAlertDelivery()
        await activeAlerts?.send(.foreground)
        if !isReplaying {
            await trioCoordinator.retry(session: sensorPipeline.sensorSession)
            await updateTrioHeartbeat()
        }
        uploads.flushIfDue()
        await purgeIfDue()
        updateClockMismatchLatch(now: now())
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

    /// About once a minute while in the foreground: a pipeline drain attempt (stores waiting
    /// readings, alert storage input and tick; docs/alerts.md §9), Trio retry (docs/trio-bridge.md:
    /// retry a failed write without waiting for a reading) and heartbeat-key check, clock check.
    private func startForegroundTicker() {
        guard foregroundTicker == nil else { return }
        let interval = foregroundTickInterval
        foregroundTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                // A drain attempt: waiting readings, storage health, tick (D42).
                self.activePipeline.retryHeldEvents()
                if !self.isReplaying {
                    await self.trioCoordinator.retry(session: self.sensorPipeline.sensorSession)
                    await self.updateTrioHeartbeat()
                }
                self.updateClockMismatchLatch(now: now())
                self.writePipelineHeartbeat()
            }
        }
    }

    // MARK: - Diagnostics

    /// Once per launch: the monotonic clock and whether its boot session (`kern.bootsessionuuid`) is
    /// readable on this phone. docs/alerts.md §10 step 5 asks for this line: without the boot
    /// session, a wall-clock rollback with no input in between is not detected and only the
    /// latest-wall-clock fallback applies.
    private func logMonotonicClock() {
        guard let uptime = uptime() else {
            log(.alert, "monotonic clock: unavailable; clock-change detection uses the latest wall clock only")
            return
        }
        let seconds = Int(uptime.seconds)
        if let boot = uptime.boot {
            log(.alert, "monotonic clock: \(seconds) s since boot, boot session \(boot) (kern.bootsessionuuid readable)")
        } else {
            log(.alert, "monotonic clock: \(seconds) s since boot, boot session unreadable (kern.bootsessionuuid): a clock rollback with no input in between is not detected; the latest-wall-clock fallback applies")
        }
    }

    func log(_ category: DiagnosticEvent.Category, _ message: String) {
        diagnostics.record(DiagnosticEvent(date: now(), category: category, message: message))
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

extension LiveAppServices.Dependencies {
    /// The same dependencies with the sensor connection settings file the G7 source was created with,
    /// what it held at launch (read once, review m5) and the source's guarded credential store.
    func with(connectionSettings: SensorConnectionSettingsStore, launch: SensorConnectionSettingsLoad,
              credentialGuard: GuardedG7CredentialStore?) -> Self {
        var copy = self
        copy.connectionSettings = connectionSettings
        copy.connectionLaunch = launch
        copy.credentialGuard = credentialGuard
        return copy
    }
}
