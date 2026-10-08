// Phase 3 failure-mode pass, services side (HANDOFF §9 Phase 3; docs/failure-modes.md): each test
// drives the real `LiveAppServices` (scripted sensor, a production database in a temporary
// directory, fake notification center / audio / AlarmKit / Trio App Group, an injected clock) through
// one failure and its recovery, and asserts what the person sees, what alerts, what Trio gets and
// what is stored. Every row of docs/failure-modes.md names the test that proves it.

import AlertEngine
import Foundation
import G7Kit
import GlucoseCore
import GlucoseStore
import NightscoutKit
import TrioBridge
import WidgetCore
import XCTest
@testable import Sensor

/// One "process" of the app over persistence that a second process can share (relaunch tests).
@MainActor
final class LiveServicesHarness {
    /// What survives a relaunch: the database file, the preferences suite, Trio's App Group, the
    /// notification center (iOS keeps pending notifications), the alarm list, the clocks.
    @MainActor
    final class Persistence {
        let directory = PipelineFixtures.temporaryDirectory()
        let suiteName = "failure-mode-\(UUID().uuidString)"
        let clock: PipelineTestClock
        let uptime: UptimeBox
        let center: RecordingNotificationCenter
        let alarms: RecordingSystemAlarms?
        let trioStore: any TrioSharedStore & TrioPayloadReading
        let session: SensorSession

        var databaseURL: URL { directory.appendingPathComponent("GlucoseStore/readings.sqlite") }
        /// D45/D47: what AppEnvironment reads before creating the G7 source. `settingsWrite` replaces
        /// the file write (tests make it fail).
        var settingsWrite: (@Sendable (Data, URL) throws -> Void)?
        var connectionSettings: SensorConnectionSettingsStore {
            SensorConnectionSettingsStore(fileURL: directory.appendingPathComponent("SensorConnection.json"),
                                          write: settingsWrite ?? SensorConnectionSettingsStore.writeAtomically)
        }

        init(now: Date, trioStore: (any TrioSharedStore & TrioPayloadReading)? = nil, alarms: Bool = false, uptime: Uptime? = nil) {
            clock = PipelineTestClock(now)
            self.uptime = UptimeBox(uptime)
            center = RecordingNotificationCenter(clock: clock)
            self.alarms = alarms ? RecordingSystemAlarms() : nil
            self.trioStore = trioStore ?? RecordingTrioStore()
            session = SensorSession(
                serial: PipelineFixtures.serial, start: now.addingTimeInterval(-2 * 86_400), warmUpEndsAt: now.addingTimeInterval(-2 * 86_400 + 27 * 60),
                expiresAt: now.addingTimeInterval(8 * 86_400), gracePeriodEndsAt: now.addingTimeInterval(8 * 86_400 + 12 * 3_600)
            )
        }

        var preferences: AppPreferences {
            AppPreferences(defaults: UserDefaults(suiteName: suiteName)!)
        }

        func reading(_ value: GlucoseValue, at date: Date, backfill: Bool = false) -> GlucoseReading {
            GlucoseReading(
                id: GlucoseReading.sensorID(serial: PipelineFixtures.serial, sensorTimestamp: UInt32(date.timeIntervalSince(session.start))),
                date: date, value: value, trendRate: 0, isBackfill: backfill, source: .sensor, sensorSerial: PipelineFixtures.serial
            )
        }
    }

    final class UptimeBox: @unchecked Sendable {
        // @unchecked Sendable: only touched from the test's main actor.
        var value: Uptime?
        init(_ value: Uptime?) { self.value = value }
    }

    final class Flag: @unchecked Sendable {
        // @unchecked Sendable: `value` is only read and written while holding `lock`.
        private let lock = NSLock()
        private var stored: Bool
        init(_ value: Bool) { stored = value }
        var value: Bool {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    let persistence: Persistence
    let services: LiveAppServices
    let sensor: ScriptedSensorDevice
    let audio: RecordingAudioPlayer
    let widget = RecordingWidgetPublisher()
    let protectedData: Flag
    let storeOpens: Flag
    /// The Keychain stand-in, shared by the services and the uploaders (as in production).
    let credentials = InMemoryCredentialStore()

    /// - Parameters:
    ///   - protectedData: false simulates a launch before the first unlock after a reboot.
    ///   - storeOpens: false makes opening the database fail (disk full, I/O error) until set true.
    ///   - uploadTransport: what the uploaders send through (default: fails the test if used).
    ///   - foregroundTickInterval: the foreground ticker's period (default: production's 60 s).
    init(_ persistence: Persistence, trioEnabled: Bool = true, protectedData: Bool = true, storeOpens: Bool = true,
         launchedByBluetoothRestoration: Bool = false, uploadTransport: (any HTTPTransport)? = nil,
         foregroundTickInterval: Duration? = nil, credentialGuard: GuardedG7CredentialStore? = nil,
         forecastFeed: ForecastService.Feed = .none) {
        self.persistence = persistence
        self.protectedData = Flag(protectedData)
        self.storeOpens = Flag(storeOpens)
        let preferences = persistence.preferences
        preferences.trioBridgeEnabled = trioEnabled
        preferences.developerLiveOutputs = true // D20: these DEBUG tests need the Trio path
        sensor = ScriptedSensorDevice(session: persistence.session)
        // As AppEnvironment does: the file is read once (review m5); the source starts in its mode.
        let connectionLaunch = persistence.connectionSettings.load()
        sensor.configure(mode: connectionLaunch.settings.g7Mode)
        // Before the first unlock G7Kit cannot read its pairing record and `start` fails.
        sensor.startFails = !protectedData
        audio = RecordingAudioPlayer(clock: persistence.clock)
        let diagnostics = RingBufferDiagnosticLog(fileURL: nil)
        let clock = persistence.clock
        var dependencies = LiveAppServices.Dependencies(
            g7: sensor, diagnostics: diagnostics, preferences: preferences, credentials: credentials,
            trio: TrioCoordinator(appGroupID: "group.org.nightscout.ABCDE12345.trio.trio-app-group", store: persistence.trioStore,
                                  diagnostics: diagnostics, clock: clock.closure),
            uploads: UploadCoordinator(credentials: credentials, queueDirectory: persistence.directory.appendingPathComponent("Uploads"),
                                       deviceName: "Test", transport: uploadTransport ?? NeverCalledTransport(), diagnostics: diagnostics),
            alertPorts: AlertPorts(notificationCenter: persistence.center, audio: audio, alarms: persistence.alarms,
                                   configuration: PipelineFixtures.utcConfiguration, diagnostics: diagnostics),
            widget: widget, databaseURL: persistence.databaseURL, httpTransport: NeverCalledTransport(), launchReplay: nil
        )
        dependencies.clock = clock.closure
        if let foregroundTickInterval { dependencies.foregroundTickInterval = foregroundTickInterval }
        dependencies.connectionSettings = persistence.connectionSettings
        dependencies.connectionLaunch = connectionLaunch
        dependencies.credentialGuard = credentialGuard
        dependencies.forecastFeed = forecastFeed // D57: no host and no network unless a test passes one
        let uptime = persistence.uptime
        dependencies.uptime = { uptime.value }
        let protected = self.protectedData
        dependencies.isProtectedDataAvailable = { protected.value }
        let opens = self.storeOpens
        dependencies.openStore = { url, diagnostics in
            guard opens.value else { throw FlakyRepository.DiskFull() }
            return try await GlucoseStore.production(at: url, diagnostics: diagnostics, now: clock.closure)
        }
        services = LiveAppServices(dependencies)
        services.launchedByBluetoothRestoration = launchedByBluetoothRestoration
    }

    var alerts: AlertService? { services.productionAlerts }

    func phase(_ kind: AlertKind) -> AlertPhase? { alerts?.phase(of: kind) }

    func isFiring(_ kind: AlertKind) -> Bool {
        if case .firing = phase(kind) { return true }
        return false
    }

    /// Delivers readings / states and waits until the pipeline has handled them.
    func deliver(_ reading: GlucoseReading) async {
        let before = services.sensorPipeline.receivedReadingCount
        sensor.deliver(reading)
        let pipeline = services.sensorPipeline
        await waitUntil("reading handled") { pipeline.receivedReadingCount > before && pipeline.isIdle }
    }

    func deliver(state: SensorState) async {
        let before = services.sensorPipeline.receivedStateCount
        sensor.deliver(state: state)
        let pipeline = services.sensorPipeline
        await waitUntil("state handled") { pipeline.receivedStateCount > before && pipeline.isIdle }
    }

    /// A wake with nothing new (foreground ticker, BLE event): one drain attempt.
    func wake() async {
        let pipeline = services.sensorPipeline
        let drains = pipeline.completedDrainCount
        pipeline.retryHeldEvents()
        await waitUntil("drain attempt") { pipeline.completedDrainCount > drains && pipeline.isIdle }
    }

    var activeState: SensorState { .active(sessionStart: persistence.session.start, expiresAt: persistence.session.expiresAt) }
}

/// Reads the `latestReadings` payload back (both Trio store doubles provide it).
protocol TrioPayloadReading {
    var payload: [[String: Any]] { get }
}

extension RecordingTrioStore: TrioPayloadReading {}

/// Trio's App Group that cannot be written: the build is not entitled to it (S5).
final class UnwritableTrioStore: TrioSharedStore, TrioPayloadReading, @unchecked Sendable {
    // @unchecked Sendable: stateless.
    func checkAccess() throws(TrioBridgeError) {
        throw .appGroupUnavailable(groupID: "group.org.nightscout.ABCDE12345.trio.trio-app-group", reason: .notEntitled)
    }
    func data(forKey key: String) -> Data? { nil }
    func setData(_ data: Data, forKey key: String) {}
    func string(forKey key: String) -> String? { nil }
    func setString(_ value: String, forKey key: String) {}
    func removeValue(forKey key: String) {}
    var payload: [[String: Any]] { [] }
}

/// Trio's App Group where writes stop sticking (the suite drops them: a full disk, a system that
/// refuses the defaults write): `setData` / `setString` change nothing while `failing`, so the
/// bridge's read-back fails (`readBackMismatch`). Otherwise an in-memory suite like
/// `RecordingTrioStore` (whose writes never fail).
final class FailingTrioStore: TrioSharedStore, TrioPayloadReading, @unchecked Sendable {
    // @unchecked Sendable: `inner` is Sendable and `isFailing` is only touched while holding `lock`.
    private let inner = RecordingTrioStore()
    private let lock = NSLock()
    private var isFailing: Bool

    init(failing: Bool = false) { isFailing = failing }

    var failing: Bool {
        get { lock.withLock { isFailing } }
        set { lock.withLock { isFailing = newValue } }
    }

    func checkAccess() throws(TrioBridgeError) {}
    func data(forKey key: String) -> Data? { inner.data(forKey: key) }
    func setData(_ data: Data, forKey key: String) {
        guard !failing else { return }
        inner.setData(data, forKey: key)
    }
    func string(forKey key: String) -> String? { inner.string(forKey: key) }
    func setString(_ value: String, forKey key: String) {
        guard !failing else { return }
        inner.setString(value, forKey: key)
    }
    func removeValue(forKey key: String) { inner.removeValue(forKey: key) }
    var payload: [[String: Any]] { inner.payload }
}

/// AlarmKit stand-in: records alarms; permission can be revoked, after which the system list
/// cannot be read and its alarms are gone (what iOS does).
@MainActor
final class RecordingSystemAlarms: SystemAlarmScheduling {
    var authorization: SystemAlarmAuthorization = .authorized
    private(set) var scheduled: [UUID: SystemAlarmRequest] = [:]
    private var listingFails = false

    func requestAuthorization() async -> SystemAlarmAuthorization { authorization }

    func schedule(_ request: SystemAlarmRequest) async throws {
        guard authorization == .authorized else { throw SystemAlarmError.unavailable }
        scheduled[request.id] = request
    }

    func cancel(ids: [UUID]) {
        for id in ids { scheduled[id] = nil }
    }

    func cancelAll() throws {
        scheduled = [:]
        if listingFails { throw SystemAlarmError.unavailable }
    }

    func activeAlarmIDs() -> Set<UUID>? { listingFails ? nil : Set(scheduled.keys) }

    /// The user turned alarms off in iOS Settings: pending alarms are gone, the list is unreadable.
    func revoke() {
        authorization = .denied
        scheduled = [:]
        listingFails = true
    }
}

@MainActor
final class FailureModeTests: XCTestCase {
    // MARK: - App killed by the system, relaunched by Bluetooth state restoration

    func test_S5_systemKillThenBluetoothRelaunchResumesAlertsMissedReadingsAndTrio() async throws {
        let now = Date()
        let persistence = LiveServicesHarness.Persistence(now: now)
        let first = LiveServicesHarness(persistence)
        await first.services.bootstrap()
        await first.deliver(state: first.activeState)
        let urgent = persistence.reading(.mgdl(50), at: now.addingTimeInterval(-10))
        await first.deliver(urgent)
        XCTAssertTrue(first.isFiring(.urgentLow))
        XCTAssertEqual(persistence.trioStore.payload.count, 1)
        XCTAssertNotNil(persistence.preferences.alertEngineSnapshot, "the alert engine's state is persisted after every input")

        // iOS terminates the process; 4 minutes later a sensor event relaunches it (state restoration).
        persistence.clock.set(now.addingTimeInterval(4 * 60))
        let second = LiveServicesHarness(persistence, launchedByBluetoothRestoration: true)
        await second.services.bootstrap()
        await waitUntil("idle") { second.services.sensorPipeline.isIdle }

        XCTAssertTrue(second.isFiring(.urgentLow), "the urgent-low episode survives the relaunch (not re-fired, not lost)")
        XCTAssertEqual(persistence.center.posted("urgentLow").count, 1, "not posted again by the relaunch")
        XCTAssertEqual(second.services.latestLiveReading?.id, urgent.id, "the stored reading is the latest again")
        XCTAssertNil(second.services.forceQuitGap, "a Bluetooth relaunch is never a force-quit gap")
        XCTAssertEqual(persistence.trioStore.payload.count, 1, "Trio keeps the reading (re-seeded from the store)")
        XCTAssertGreaterThanOrEqual(second.sensor.startCount, 1, "the sensor source is started again")

        // No reading since: missed readings counts from the last reading of the first process.
        persistence.clock.set(urgent.date.addingTimeInterval(16 * 60))
        await second.wake()
        XCTAssertTrue(second.isFiring(.missedReadings), "the missed-readings timer resumes from the last reading, not from the relaunch")
    }

    // MARK: - Bluetooth off / unauthorized

    func test_S5_bluetoothOffAndUnauthorizedRaiseTheAlertAndRecover() async throws {
        let now = Date()
        let persistence = LiveServicesHarness.Persistence(now: now)
        let harness = LiveServicesHarness(persistence)
        await harness.services.bootstrap()
        await harness.deliver(state: harness.activeState)
        await harness.deliver(persistence.reading(.mgdl(120), at: now.addingTimeInterval(-10)))

        await harness.deliver(state: .bluetoothUnavailable(.poweredOff))
        XCTAssertEqual(harness.services.sensorState, .bluetoothUnavailable(.poweredOff), "the UI's banner input")
        XCTAssertTrue(harness.isFiring(.bluetoothUnavailable))
        XCTAssertFalse(persistence.center.posted("bluetoothUnavailable").isEmpty)
        // Suspended with Bluetooth off nothing wakes the app: the pending missed-readings
        // notifications still fire on time (S5).
        XCTAssertFalse(persistence.center.pending("missedReadings").isEmpty)

        persistence.clock.advance(by: 5 * 60)
        await harness.deliver(state: harness.activeState)
        await harness.deliver(persistence.reading(.mgdl(118), at: persistence.clock.now.addingTimeInterval(-5)))
        XCTAssertFalse(harness.isFiring(.bluetoothUnavailable), "cleared when the sensor is back")

        await harness.deliver(state: .bluetoothUnavailable(.unauthorized))
        XCTAssertTrue(harness.isFiring(.bluetoothUnavailable), "permission revoked raises it again")
    }

    // MARK: - Notification and alarm permissions

    func test_S5_notificationsDeniedStillPlaysTheInAppSoundAndIsSurfaced() async throws {
        let now = Date()
        let persistence = LiveServicesHarness.Persistence(now: now)
        persistence.center.permissions.authorization = .denied
        let harness = LiveServicesHarness(persistence)
        await harness.services.bootstrap()
        await harness.deliver(state: harness.activeState)
        await harness.deliver(persistence.reading(.mgdl(50), at: now.addingTimeInterval(-10)))

        XCTAssertTrue(harness.isFiring(.urgentLow))
        XCTAssertTrue(persistence.center.posted.isEmpty, "iOS refuses every notification")
        XCTAssertTrue(harness.audio.plays.contains { $0.fileName == AlertSoundCatalog.fileName(.cascade) }, "the in-app sound still plays")
        XCTAssertTrue(harness.services.alertDelivery.problems.contains(.notificationsDenied), "Settings says why")
    }

    func test_S5_notificationsRevokedLaterIsSurfacedOnForeground() async throws {
        let now = Date()
        let persistence = LiveServicesHarness.Persistence(now: now)
        let harness = LiveServicesHarness(persistence)
        await harness.services.bootstrap()
        XCTAssertFalse(harness.services.alertDelivery.problems.contains(.notificationsDenied))

        persistence.center.permissions.authorization = .denied
        await harness.services.handleForeground()
        defer { harness.services.handleBackground() }
        XCTAssertTrue(harness.services.alertDelivery.problems.contains(.notificationsDenied))

        await harness.deliver(state: harness.activeState)
        await harness.deliver(persistence.reading(.mgdl(52), at: persistence.clock.now.addingTimeInterval(-10)))
        XCTAssertTrue(harness.audio.plays.contains { $0.fileName == AlertSoundCatalog.fileName(.cascade) }, "urgent low still sounds in the app")
    }

    func test_S7_alarmPermissionRevokedWithRepeatsPendingFallsBackToTheInAppSound() async throws {
        let now = Date()
        let persistence = LiveServicesHarness.Persistence(now: now, alarms: true)
        let harness = LiveServicesHarness(persistence)
        await harness.services.bootstrap()
        await harness.deliver(state: harness.activeState)
        await harness.deliver(persistence.reading(.mgdl(50), at: now.addingTimeInterval(-10)))
        let alarms = try XCTUnwrap(persistence.alarms)
        XCTAssertFalse(alarms.scheduled.isEmpty, "urgent low and its repeats are system alarms")
        let soundsBefore = harness.audio.plays.count

        alarms.revoke()
        // The next wake is at the first repeat: its alarm is gone, so the app plays the sound itself.
        persistence.clock.advance(by: TimeInterval(AlertLimits.urgentLowDefaultRepeatMinutes * 60))
        await harness.deliver(persistence.reading(.mgdl(49), at: persistence.clock.now.addingTimeInterval(-5)))
        XCTAssertTrue(harness.isFiring(.urgentLow))
        XCTAssertGreaterThan(harness.audio.plays.count, soundsBefore, "the due repeat plays in the app when its alarm vanished")
        await harness.services.refreshAlertDelivery()
        XCTAssertTrue(harness.services.alertDelivery.problems.contains(.urgentLowAlarmDenied), "Settings says alarms are off")
    }

    // MARK: - Reboot: a Bluetooth relaunch before the first unlock

    func test_S5_rebootBeforeFirstUnlockWaitsThenRecoversEverything() async throws {
        let now = Date()
        let persistence = LiveServicesHarness.Persistence(now: now)
        let harness = LiveServicesHarness(persistence, protectedData: false, launchedByBluetoothRestoration: true)
        await harness.services.bootstrap()
        XCTAssertFalse(harness.services.isBootstrapped, "nothing is read before the first unlock")
        XCTAssertNil(harness.services.productionStore)
        guard case .waitingForFirstUnlock = harness.services.storage.availability else {
            return XCTFail("the store waits for the first unlock: \(harness.services.storage.availability)")
        }
        harness.sensor.deliver(state: .failed(G7FailureReason.credentialsUnavailable))
        await waitUntil("state received") { harness.services.sensorPipeline.receivedStateCount >= 2 }
        let startsBefore = harness.sensor.startCount

        // The person unlocks the phone.
        harness.protectedData.value = true
        harness.sensor.startFails = false
        harness.services.protectedDataDidBecomeAvailable()
        await waitUntil("bootstrapped and open") { harness.services.isBootstrapped && harness.services.productionStore != nil }
        XCTAssertGreaterThan(harness.sensor.startCount, startsBefore, "the G7 source is started again once its pairing is readable")
        XCTAssertEqual(harness.services.storage.availability, .open)
        await harness.deliver(state: harness.activeState)
        await harness.deliver(persistence.reading(.mgdl(54), at: persistence.clock.now.addingTimeInterval(-10)))
        XCTAssertTrue(harness.isFiring(.urgentLow), "alerts work after the unlock")
        XCTAssertEqual(persistence.trioStore.payload.count, 1, "Trio gets readings after the unlock")
    }

    // MARK: - Disk full / unwritable outputs

    func test_S5_trioAppGroupWriteFailureRaisesTheTrioAlert() async throws {
        let now = Date()
        let persistence = LiveServicesHarness.Persistence(now: now, trioStore: UnwritableTrioStore())
        let harness = LiveServicesHarness(persistence)
        await harness.services.bootstrap()
        await harness.deliver(state: harness.activeState)
        await harness.deliver(persistence.reading(.mgdl(120), at: now.addingTimeInterval(-10)))
        // No manual alert input: the bridge's status reaches the alert engine on its own.
        await waitUntil("the Trio bridge alert fires") { harness.isFiring(.trioBridge) }
        XCTAssertTrue(harness.services.trio.isFailing)
        XCTAssertNotNil(harness.services.trio.lastErrorDescription)
    }

    /// Audit m4: a Trio App Group write that fails (the suite drops it; the bridge's read-back
    /// catches it), end to end — the reading arrives from the sensor, the `trioBridge` alert fires
    /// and is posted with no other prompt, Settings › Trio and the Now banner show the failure, and
    /// it all clears when writes stick again (S5).
    func test_S5_trioWriteFailureAlertsAndShowsInSettingsEndToEnd() async throws {
        let now = Date()
        let store = FailingTrioStore()
        let persistence = LiveServicesHarness.Persistence(now: now, trioStore: store)
        let harness = LiveServicesHarness(persistence)
        await harness.services.bootstrap()
        let model = AppModel.launch(services: harness.services, arguments: [],
                                    preferences: AppUIPreferences(defaults: UserDefaults(suiteName: "m4-\(UUID().uuidString)")!),
                                    clock: { persistence.clock.now }, protectedDataAvailable: { true })
        await harness.deliver(state: harness.activeState)
        await harness.deliver(persistence.reading(.mgdl(120), at: now.addingTimeInterval(-10)))
        XCTAssertEqual(store.payload.first?["Value"] as? Int, 120)
        await waitUntil("Settings shows Trio OK") { if case .ok = model.settings.trio.status { return true }; return false }
        XCTAssertFalse(harness.isFiring(.trioBridge))

        // Writes stop sticking. The next reading's write fails.
        store.failing = true
        persistence.clock.advance(by: 5 * 60)
        await harness.deliver(persistence.reading(.mgdl(118), at: persistence.clock.now.addingTimeInterval(-10)))
        await waitUntil("the Trio bridge alert fires") { harness.isFiring(.trioBridge) }
        XCTAssertFalse(persistence.center.posted("trioBridge").isEmpty, "the person is told, not only the engine")
        XCTAssertEqual(store.payload.first?["Value"] as? Int, 120, "Trio still has the last reading that was written")
        XCTAssertTrue(harness.services.trio.isFailing)
        await waitUntil("Settings shows the failure") { if case .failing = model.settings.trio.status { return true }; return false }
        guard case .failing(_, let message) = model.settings.trio.status else { return XCTFail("Settings › Trio") }
        XCTAssertEqual(message, harness.services.trio.lastErrorDescription, "Settings says what failed")
        guard case .failing = model.now.health.trio else { return XCTFail("the Now banner shows the Trio failure: \(model.now.health.trio)") }

        // Writes stick again: the next reading goes through, the alert and Settings clear.
        store.failing = false
        persistence.clock.advance(by: 5 * 60)
        await harness.deliver(persistence.reading(.mgdl(116), at: persistence.clock.now.addingTimeInterval(-10)))
        XCTAssertEqual(store.payload.first?["Value"] as? Int, 116)
        await waitUntil("the Trio bridge alert clears") { !harness.isFiring(.trioBridge) }
        await waitUntil("Settings shows Trio OK again") { if case .ok = model.settings.trio.status { return true }; return false }
    }

    // MARK: - D21 wiring (audit m5)

    /// LOW reaches Trio as 39 and HIGH as 401 through the app's own TrioCoordinator (its D21
    /// OutOfRangePolicy), from the sensor to the App Group payload. Fails if the policy is changed to
    /// withhold (`.doNotWrite`): nothing would be written for either flag.
    func test_S4_lowAndHighReachTrioAs39And401() async throws {
        let now = Date()
        let persistence = LiveServicesHarness.Persistence(now: now)
        let harness = LiveServicesHarness(persistence)
        await harness.services.bootstrap()
        await harness.deliver(state: harness.activeState)

        let low = persistence.reading(.belowRange, at: now.addingTimeInterval(-10))
        await harness.deliver(low)
        let afterLow = persistence.trioStore.payload
        XCTAssertEqual(afterLow.count, 1, "the LOW reading was written, not withheld")
        XCTAssertEqual(afterLow.first?["Value"] as? Int, 39, "D21: LOW → 39 (never 40, S4)")
        XCTAssertEqual(afterLow.first?["DT"] as? String, "/Date(\(GlucoseReading.epochMilliseconds(low.date)))/")

        persistence.clock.advance(by: 5 * 60)
        let high = persistence.reading(.aboveRange, at: persistence.clock.now.addingTimeInterval(-10))
        await harness.deliver(high)
        let afterHigh = persistence.trioStore.payload
        XCTAssertEqual(afterHigh.count, 2, "the HIGH reading was written, not withheld")
        XCTAssertEqual(afterHigh.first?["Value"] as? Int, 401, "D21: HIGH → 401 (never 400, S4); newest first")
        XCTAssertEqual(afterHigh.last?["Value"] as? Int, 39)
        XCTAssertEqual(harness.services.trio.lastErrorDescription, nil)
    }

    // MARK: - Untested wiring (audit m18)

    /// A failed Trio write is retried when the app comes to the foreground, with no new reading.
    func test_S5_failedTrioWriteIsRetriedOnForeground() async throws {
        let now = Date()
        let store = FailingTrioStore(failing: true)
        let persistence = LiveServicesHarness.Persistence(now: now, trioStore: store)
        let harness = LiveServicesHarness(persistence) // production's 60 s ticker: it won't tick here
        await harness.services.bootstrap()
        await harness.deliver(state: harness.activeState)
        let reading = persistence.reading(.mgdl(130), at: now.addingTimeInterval(-10))
        await harness.deliver(reading)
        XCTAssertTrue(store.payload.isEmpty)
        await waitUntil("failing") { harness.services.trio.isFailing }

        store.failing = false
        await harness.services.handleForeground()
        defer { harness.services.handleBackground() }
        XCTAssertEqual(store.payload.first?["Value"] as? Int, 130, "the foreground retry wrote the pending reading")
        await waitUntil("recovered") { !harness.services.trio.isFailing }
    }

    /// A failed Trio write is retried by the foreground ticker (60 s in production; shortened here),
    /// with no new reading and no other prompt.
    func test_S5_failedTrioWriteIsRetriedByTheForegroundTicker() async throws {
        let now = Date()
        let store = FailingTrioStore()
        let persistence = LiveServicesHarness.Persistence(now: now, trioStore: store)
        let harness = LiveServicesHarness(persistence, foregroundTickInterval: .milliseconds(200))
        await harness.services.bootstrap()
        await harness.services.handleForeground()
        defer { harness.services.handleBackground() }
        await harness.deliver(state: harness.activeState)

        store.failing = true
        await harness.deliver(persistence.reading(.mgdl(140), at: now.addingTimeInterval(-10)))
        XCTAssertTrue(store.payload.isEmpty)
        store.failing = false
        await waitUntil("the ticker's retry wrote the pending reading") { store.payload.first?["Value"] as? Int == 140 }
    }

    /// Saving Nightscout credentials flushes the queue at once (the missing-token backoff is 30 min).
    func test_S5_savingNightscoutCredentialsFlushesTheQueueAtOnce() async throws {
        let now = Date()
        let transport = RecordingTransport()
        let persistence = LiveServicesHarness.Persistence(now: now)
        let preferences = persistence.preferences
        preferences.nightscoutUploadEnabled = true
        preferences.nightscoutSiteURL = "https://ns.example.invalid"
        let harness = LiveServicesHarness(persistence, uploadTransport: transport)
        await harness.services.bootstrap()
        await harness.deliver(state: harness.activeState)
        let reading = persistence.reading(.mgdl(125), at: now.addingTimeInterval(-10))
        await harness.deliver(reading)
        await waitUntil("upload failed for the missing token") { harness.services.nightscout.upload.isFailing }
        XCTAssertTrue(transport.requests.isEmpty, "nothing is sent without a token")
        XCTAssertEqual(harness.services.nightscout.upload.status?.queueDepth, 1)

        try await harness.services.saveNightscout(url: "https://ns.example.invalid", token: "new-token")
        let request = try XCTUnwrap(transport.requests.first, "the save flushed the queue without waiting for the backoff")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.host, "ns.example.invalid")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("\"date\":\(GlucoseReading.epochMilliseconds(reading.date))"), body)
        await waitUntil("uploaded") { harness.services.nightscout.upload.status?.queueDepth == 0 }
        XCTAssertFalse(harness.services.nightscout.upload.isFailing)
    }

    /// Found while adding the test above: `applyUploadConfiguration` ran during bootstrap before
    /// `isBootstrapped` was set and read the site through the UI's bootstrap guard (nil), so after
    /// every launch no Nightscout uploader existed until a Nightscout setting was changed — readings
    /// were silently not uploaded and Settings said "No access token is saved".
    func test_S5_savedNightscoutSettingsUploadAfterALaunch() async throws {
        let now = Date()
        let transport = RecordingTransport()
        let persistence = LiveServicesHarness.Persistence(now: now)
        let preferences = persistence.preferences
        preferences.nightscoutUploadEnabled = true
        preferences.nightscoutSiteURL = "https://ns.example.invalid"
        let harness = LiveServicesHarness(persistence, uploadTransport: transport)
        try harness.credentials.write("token", for: .nightscoutToken)
        await harness.services.bootstrap()
        XCTAssertTrue(harness.services.nightscout.upload.isConfigured)
        XCTAssertNotNil(harness.services.nightscout.upload.status, "the uploader exists after launch")

        await harness.deliver(state: harness.activeState)
        let reading = persistence.reading(.mgdl(111), at: now.addingTimeInterval(-10))
        await harness.deliver(reading)
        await waitUntil("uploaded") { !transport.requests.isEmpty }
        let body = String(decoding: transport.requests.first?.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("\"date\":\(GlucoseReading.epochMilliseconds(reading.date))"), body)
    }

    /// The Nightscout `device` field is the app's name, `APP_DISPLAY_NAME`: Config/Base.xcconfig →
    /// Info.plist CFBundleDisplayName → `AppIdentity.displayName` → the composition root's uploaders.
    func test_nightscoutDeviceNameIsAppDisplayName() async throws {
        let xcconfig = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/Base.xcconfig")
        let line = try String(contentsOf: xcconfig, encoding: .utf8).split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("APP_DISPLAY_NAME") }
        let configured = try XCTUnwrap(line?.split(separator: "=", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces))
        XCTAssertFalse(configured.isEmpty)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, configured,
                       "the test host is the app; its Info.plist carries APP_DISPLAY_NAME (not AppIdentity's fallback)")

        let transport = RecordingTransport()
        let uploads = AppEnvironment.makeUploads(credentials: InMemoryCredentialStore([.nightscoutToken: "t"]),
                                                 support: PipelineFixtures.temporaryDirectory(), diagnostics: NullDiagnosticLog(),
                                                 transport: transport)
        await uploads.apply(UploadCoordinator.Configuration(
            nightscoutEnabled: true, nightscoutSite: try NightscoutSite("https://ns.example.invalid"), nightscoutHasToken: true,
            shareEnabled: false, shareRegion: .us, shareReceiverSerial: nil, shareHasCredentials: false, liveOutputsAllowed: true
        ))
        let uploader = try XCTUnwrap(uploads.activeUploaders.first)
        let now = Date()
        let session = SensorSession(serial: PipelineFixtures.serial, start: now.addingTimeInterval(-86_400), warmUpEndsAt: now.addingTimeInterval(-86_000),
                                    expiresAt: now.addingTimeInterval(86_400), gracePeriodEndsAt: now.addingTimeInterval(90_000))
        let reading = GlucoseReading(id: "\(PipelineFixtures.serial):86390", date: now.addingTimeInterval(-10), value: .mgdl(120), trendRate: 0,
                                     isBackfill: false, source: .sensor, sensorSerial: PipelineFixtures.serial)
        try await uploader.submit(reading, session: session)
        await uploads.flushNow()
        let body = try XCTUnwrap(transport.requests.first?.httpBody)
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        XCTAssertEqual(entries.first?["device"] as? String, configured)
    }

    // MARK: - Monotonic clock boot session (docs/alerts.md §10 step 5)

    func test_launchLogsTheMonotonicClockBootSessionOnce() async {
        let persistence = LiveServicesHarness.Persistence(now: Date(), uptime: Uptime(seconds: 1_234, boot: "BOOT-SESSION-1"))
        let harness = LiveServicesHarness(persistence)
        await harness.services.bootstrap()
        await harness.services.handleForeground()
        harness.services.handleBackground()
        let lines = harness.services.diagnostics.snapshot.filter { $0.message.hasPrefix("monotonic clock:") }
        XCTAssertEqual(lines.count, 1, "once per launch")
        XCTAssertEqual(lines.first?.category, .alert)
        XCTAssertTrue(lines.first?.message.contains("boot session BOOT-SESSION-1") == true, lines.first?.message ?? "")

        persistence.uptime.value = Uptime(seconds: 1_300, boot: nil)
        let unreadable = LiveServicesHarness(persistence)
        XCTAssertTrue(unreadable.services.diagnostics.snapshot.contains { $0.message.contains("boot session unreadable") },
                      "an unreadable boot session is called out")
    }

    func test_S5_uploadQueueThatCannotBeSavedIsSurfaced() async throws {
        // A queue directory that is a regular file: every save of the queue fails (like a full disk).
        let directory = PipelineFixtures.temporaryDirectory()
        let notADirectory = directory.appendingPathComponent("Uploads")
        try Data("x".utf8).write(to: notADirectory)
        let uploads = UploadCoordinator(credentials: InMemoryCredentialStore([.nightscoutToken: "t"]), queueDirectory: notADirectory,
                                        deviceName: "Test", transport: NeverCalledTransport(), diagnostics: NullDiagnosticLog())
        await uploads.apply(UploadCoordinator.Configuration(
            nightscoutEnabled: true, nightscoutSite: try NightscoutSite("https://example.invalid"), nightscoutHasToken: true,
            shareEnabled: false, shareRegion: .us, shareReceiverSerial: nil, shareHasCredentials: false, liveOutputsAllowed: true
        ))
        let uploader = try XCTUnwrap(uploads.activeUploaders.first)
        let now = Date()
        let session = SensorSession(serial: PipelineFixtures.serial, start: now.addingTimeInterval(-86_400), warmUpEndsAt: now.addingTimeInterval(-86_000),
                                    expiresAt: now.addingTimeInterval(86_400), gracePeriodEndsAt: now.addingTimeInterval(90_000))
        let reading = GlucoseReading(id: "\(PipelineFixtures.serial):86390", date: now.addingTimeInterval(-10), value: .mgdl(120), trendRate: 0,
                                     isBackfill: false, source: .sensor, sensorSerial: PipelineFixtures.serial)
        try await uploader.submit(reading, session: session)
        await waitUntil("summary updated") { uploads.nightscoutSummary.isFailing }
        XCTAssertNotNil(uploads.nightscoutSummary.status?.queueSaveProblem, "the save failure is surfaced (S5)")
        XCTAssertEqual(uploads.nightscoutSummary.status?.queueDepth, 1, "the reading stays queued in memory")
    }

    // MARK: - Clock: compound latch case (Phase 3 carry-over)

    /// A failed open shows an older re-delivered reading; the phone clock changes; the store opens
    /// later. The latch persisted for the newer reading R must still hold when R is the latest again,
    /// and the older reading shown meanwhile must have been latched too.
    func test_S1_latchForANewerReadingSurvivesAClockChangeWhileAnOlderOneIsShown() async throws {
        let now = Date()
        let boot = "boot-compound"
        let persistence = LiveServicesHarness.Persistence(now: now, uptime: Uptime(seconds: 10_000, boot: boot))
        let r = persistence.reading(.mgdl(120), at: now.addingTimeInterval(-120))
        do {
            let seed = try await GlucoseStore.production(at: persistence.databaseURL)
            _ = try await seed.insert([r])
        }
        persistence.preferences.clockMismatch = ClockMismatchState(latchedFor: r.date, lastCheckWallClock: now, lastCheckUptime: Uptime(seconds: 10_000, boot: boot))
        let harness = LiveServicesHarness(persistence, storeOpens: false)
        await harness.services.bootstrap()
        XCTAssertNil(harness.services.productionStore)

        let older = persistence.reading(.mgdl(118), at: r.date.addingTimeInterval(-300), backfill: true)
        await harness.deliver(older)
        harness.services.updateClockMismatchLatch(now: persistence.clock.now)
        XCTAssertEqual(harness.services.latestLiveReading?.id, older.id, "the held older reading is shown")
        XCTAssertEqual(harness.services.clockMismatchLatchedFor, r.date, "R's latch is kept; the older reading is not latched")

        // The clock is set back 30 minutes while 40 real minutes pass.
        persistence.uptime.value = Uptime(seconds: 10_000 + 40 * 60, boot: boot)
        persistence.clock.set(now.addingTimeInterval(10 * 60))
        harness.services.updateClockMismatchLatch(now: persistence.clock.now)
        XCTAssertEqual(harness.services.clockMismatchLatchedFor, older.date, "the reading shown is latched now")
        XCTAssertEqual(persistence.preferences.clockMismatch.latchedFor, r.date, "and R's latch is not overwritten")

        // The disk has room again: the store opens at the next wake, R is the latest again.
        harness.storeOpens.value = true
        await harness.wake()
        await waitUntil("store open") { harness.services.productionStore != nil }
        await waitUntil("idle") { harness.services.sensorPipeline.isIdle && harness.services.sensorPipeline.heldReadingCount == 0 }
        harness.services.updateClockMismatchLatch(now: persistence.clock.now)
        XCTAssertEqual(harness.services.latestLiveReading?.id, r.id)
        XCTAssertEqual(harness.services.clockMismatchLatchedFor, r.date, "R is still latched")
    }

    // MARK: - Facade: storedSensorKnown (Phase 3 carry-over for onboarding's baseline)

    func test_storedSensorKnownIsFalseUntilBootstrapHasReadTheSource() async throws {
        let persistence = LiveServicesHarness.Persistence(now: Date())
        let harness = LiveServicesHarness(persistence, protectedData: false)
        let changes = harness.services.changes()
        await harness.services.bootstrap()
        XCTAssertFalse(harness.services.storedSensorKnown, "before the first unlock the stored sensor is not known")
        XCTAssertFalse(harness.services.hasStoredSensor)

        harness.protectedData.value = true
        harness.sensor.startFails = false
        harness.services.protectedDataDidBecomeAvailable()
        await waitUntil("known") { harness.services.storedSensorKnown }
        XCTAssertTrue(harness.services.hasStoredSensor, "the scripted source has a stored sensor")
        var sawSensorChange = false
        for await change in changes {
            if change == .sensor { sawSensorChange = true; break }
        }
        XCTAssertTrue(sawSensorChange, "the flip is announced as a .sensor change")
        XCTAssertTrue(PreviewAppServices().storedSensorKnown, "stand-ins always know")
    }

    // MARK: - Clock moved forward

    /// A phone clock moved forward between wakes makes the latest reading look older than it is:
    /// that direction is safe (stale, missed readings early), and the memoryless check latches it
    /// too, so its age is not presented as exact.
    func test_S1_clockMovedForwardBetweenWakesLatchesTheShownReading() {
        let t = PipelineFixtures.start
        let reading = PipelineFixtures.reading(.mgdl(120), at: t)
        var state = ClockMismatchMonitor.check(.initial, latest: reading, previous: nil, now: t, uptime: Uptime(seconds: 500, boot: "b"))
        state = ClockMismatchMonitor.check(state, latest: reading, previous: nil, now: t.addingTimeInterval(3 * 3_600), uptime: Uptime(seconds: 500 + 120, boot: "b"))
        XCTAssertEqual(state.latchedFor, reading.date)
    }

    // MARK: - Time zone change and DST

    /// Readings are absolute instants. Across the US fall-back hour, with the phone's time zone
    /// changed twice in between, every reading is stored exactly as delivered and in order, the
    /// latest is the last one, and nothing latches (the wall clock in UTC did not jump).
    func test_S3_timeZoneChangesAndDSTLeaveTimestampsAndTheLatchUntouched() async throws {
        let originalZone = NSTimeZone.default
        defer { NSTimeZone.default = originalZone }
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        // 2030-11-03 05:20 UTC = 01:20 EDT; at 06:00 UTC New York falls back to 01:00 EST.
        let start = Date(timeIntervalSince1970: 1_919_913_600)
        let boot = "boot-dst"
        let persistence = LiveServicesHarness.Persistence(now: start, uptime: Uptime(seconds: 1_000, boot: boot))
        let harness = LiveServicesHarness(persistence)
        await harness.services.bootstrap()
        await harness.deliver(state: harness.activeState)

        var delivered: [GlucoseReading] = []
        for step in 0..<16 { // 05:20 … 06:35 UTC, every 5 minutes
            let date = start.addingTimeInterval(TimeInterval(step * 300))
            persistence.clock.set(date.addingTimeInterval(5))
            persistence.uptime.value = Uptime(seconds: 1_005 + TimeInterval(step * 300), boot: boot)
            if step == 5 { NSTimeZone.default = TimeZone(identifier: "Asia/Tokyo")! }
            if step == 10 { NSTimeZone.default = TimeZone(identifier: "America/New_York")! }
            let reading = persistence.reading(.mgdl(110 + step), at: date)
            delivered.append(reading)
            await harness.deliver(reading)
            harness.services.updateClockMismatchLatch(now: persistence.clock.now)
        }
        let stored = try await XCTUnwrap(harness.services.productionStore).readings(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(stored.map(\.date), delivered.map(\.date), "bit-exact instants, in order, across DST and time-zone changes")
        XCTAssertEqual(stored.map(\.id), delivered.map(\.id))
        XCTAssertEqual(harness.services.latestLiveReading?.id, delivered.last?.id)
        XCTAssertNil(harness.services.clockMismatchLatchedFor, "a time-zone change is not a clock change")
        XCTAssertEqual(persistence.trioStore.payload.count, delivered.count)
    }
}
