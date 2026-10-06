// The launch order at composition level (Phase 2 follow-up review, M1 and B1): the real
// `LiveAppServices` with a scripted sensor, a temporary production database whose opening the test
// controls, fake alert ports, an in-memory Trio App Group and a recording widget.
//
// - The pipeline is activated before the store opens: a reading delivered during the open reaches
//   the alert engine and Trio at once; once open, Trio is re-seeded from the store.
// - A failed open is surfaced: `storeOpenFailingSince`, then the storage-failure alert after
//   `AlertLimits.storageFailingMinutes`, while the persisted clock latch is kept.
// - The clock-mismatch latch and the widget survive a relaunch: nothing is judged or published
//   against an unknown latest reading while the store opens (B1).

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

@MainActor
final class LaunchOrderTests: XCTestCase {
    private let trioGroup = "group.org.nightscout.ABCDE12345.trio.trio-app-group"

    private struct Launch {
        let services: LiveAppServices
        let sensor: ScriptedSensorDevice
        let clock: PipelineTestClock
        let preferences: AppPreferences
        let center: RecordingNotificationCenter
        let trioStore: RecordingTrioStore
        let widget: RecordingWidgetPublisher
        let databaseURL: URL
        let session: SensorSession
    }

    /// - Parameter openStore: how the production database opens (default: at once).
    private func makeLaunch(
        now: Date,
        seed: [GlucoseReading] = [],
        persistedLatch: Date? = nil,
        openStore: (@Sendable (URL, any DiagnosticLog) async throws -> GlucoseStore)? = nil
    ) async throws -> Launch {
        let directory = PipelineFixtures.temporaryDirectory()
        let databaseURL = directory.appendingPathComponent("GlucoseStore/readings.sqlite")
        if !seed.isEmpty {
            let store = try await GlucoseStore.production(at: databaseURL)
            _ = try await store.insert(seed)
        }
        let clock = PipelineTestClock(now)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "launch-order-\(UUID().uuidString)"))
        let preferences = AppPreferences(defaults: defaults)
        preferences.trioBridgeEnabled = true
        preferences.developerLiveOutputs = true // D20: this DEBUG test needs the Trio path
        if let persistedLatch {
            preferences.clockMismatch = ClockMismatchState(latchedFor: persistedLatch, lastCheckWallClock: nil, lastCheckUptime: nil)
        }
        let session = SensorSession(
            serial: PipelineFixtures.serial, start: now.addingTimeInterval(-2 * 86_400), warmUpEndsAt: now.addingTimeInterval(-2 * 86_400 + 27 * 60),
            expiresAt: now.addingTimeInterval(8 * 86_400), gracePeriodEndsAt: now.addingTimeInterval(8 * 86_400 + 12 * 3_600)
        )
        let sensor = ScriptedSensorDevice(session: session)
        let diagnostics = RingBufferDiagnosticLog(fileURL: nil)
        let center = RecordingNotificationCenter(clock: clock)
        let trioStore = RecordingTrioStore()
        let widget = RecordingWidgetPublisher()
        var dependencies = LiveAppServices.Dependencies(
            g7: sensor, diagnostics: diagnostics, preferences: preferences, credentials: InMemoryCredentialStore(),
            trio: TrioCoordinator(appGroupID: trioGroup, store: trioStore, diagnostics: diagnostics, clock: clock.closure),
            uploads: UploadCoordinator(credentials: InMemoryCredentialStore(), queueDirectory: directory.appendingPathComponent("Uploads"),
                                       deviceName: "Test", transport: NeverCalledTransport(), diagnostics: diagnostics),
            alertPorts: AlertPorts(notificationCenter: center, audio: RecordingAudioPlayer(clock: clock), alarms: nil,
                                   configuration: PipelineFixtures.utcConfiguration, diagnostics: diagnostics),
            widget: widget, databaseURL: databaseURL, httpTransport: NeverCalledTransport(), launchReplay: nil
        )
        dependencies.clock = clock.closure
        dependencies.uptime = { nil }
        if let openStore { dependencies.openStore = openStore }
        let services = LiveAppServices(dependencies)
        return Launch(services: services, sensor: sensor, clock: clock, preferences: preferences, center: center,
                      trioStore: trioStore, widget: widget, databaseURL: databaseURL, session: session)
    }

    private func reading(_ value: GlucoseValue, at date: Date, launch: Launch) -> GlucoseReading {
        GlucoseReading(
            id: GlucoseReading.sensorID(serial: PipelineFixtures.serial, sensorTimestamp: UInt32(date.timeIntervalSince(launch.session.start))),
            date: date, value: value, trendRate: 0, isBackfill: false, source: .sensor, sensorSerial: PipelineFixtures.serial
        )
    }

    private func seedReadings(at dates: [Date], now: Date) -> [GlucoseReading] {
        let start = now.addingTimeInterval(-2 * 86_400)
        return dates.map { date in
            GlucoseReading(
                id: GlucoseReading.sensorID(serial: PipelineFixtures.serial, sensorTimestamp: UInt32(date.timeIntervalSince(start))),
                date: date, value: .mgdl(110), trendRate: 0, isBackfill: false, source: .sensor, sensorSerial: PipelineFixtures.serial
            )
        }
    }

    // MARK: - Activation before the open; re-seed after it

    func test_S5_launchFeedsAlertsAndTrioBeforeTheStoreOpensThenReseeds() async throws {
        let now = Date()
        let seeded = seedReadings(at: [-20, -15, -10].map { now.addingTimeInterval($0 * 60) }, now: now)
        let gate = OpenGate()
        let launch = try await makeLaunch(now: now, seed: seeded) { url, diagnostics in
            await gate.wait()
            return try await GlucoseStore.production(at: url, diagnostics: diagnostics)
        }
        let services = launch.services
        let bootstrap = Task { await services.bootstrap() }
        await waitUntil("pipeline active") { services.sensorPipeline.completedDrainCount >= 1 }
        XCTAssertNil(services.productionStore, "the store is still opening")

        let urgent = reading(.mgdl(50), at: now.addingTimeInterval(-5), launch: launch)
        launch.sensor.deliver(urgent)
        await waitUntil("alerts and Trio got the reading during the open") {
            !launch.center.posted("urgentLow").isEmpty && launch.trioStore.payload.count == 1
        }
        XCTAssertNil(services.productionStore, "alerts and Trio did not wait for the store")

        await gate.open()
        await bootstrap.value
        await waitUntil("held reading stored") { services.sensorPipeline.heldReadingCount == 0 && services.sensorPipeline.isIdle }
        let stored = try await XCTUnwrap(services.productionStore).readings(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(stored.map(\.id), seeded.map(\.id) + [urgent.id])
        // Re-seeded after the open: the stored readings joined the payload, the newest stays first.
        XCTAssertEqual(launch.trioStore.payload.count, 4)
        XCTAssertEqual(launch.trioStore.payload.first?["Value"] as? Int, 50)
    }

    // MARK: - A failed open is surfaced

    /// A wake after a failed open retries it. While the retry runs the failure stays visible
    /// ("opening" has no banner, S5); it clears when the retry succeeds.
    func test_S5_aRetriedOpenKeepsTheFailureVisibleUntilItSucceeds() async throws {
        let now = Date()
        let attempts = CallCounter()
        let gate = OpenGate()
        let launch = try await makeLaunch(now: now) { url, diagnostics in
            if attempts.next() == 1 { throw FlakyRepository.DiskFull() }
            await gate.wait()
            return try await GlucoseStore.production(at: url, diagnostics: diagnostics)
        }
        let services = launch.services
        await services.bootstrap()
        guard case .failed = services.storage.availability else {
            return XCTFail("the failed open must be surfaced: \(services.storage.availability)")
        }

        launch.sensor.deliver(state: .active(sessionStart: launch.session.start, expiresAt: launch.session.expiresAt))
        await waitUntil("the wake retries the open") { attempts.value >= 2 }
        guard case .failed = services.storage.availability else {
            return XCTFail("the failure stays visible while the retry runs: \(services.storage.availability)")
        }
        await gate.open()
        await waitUntil("open") { services.productionStore != nil }
        XCTAssertEqual(services.storage.availability, .open)
    }

    func test_S5_failedStoreOpenRaisesTheStorageAlertAndKeepsThePersistedLatch() async throws {
        let now = Date()
        let latched = now.addingTimeInterval(-600)
        let launch = try await makeLaunch(now: now, persistedLatch: latched) { _, _ in
            throw FlakyRepository.DiskFull()
        }
        let services = launch.services
        await services.bootstrap()
        XCTAssertNil(services.productionStore)
        XCTAssertEqual(services.sensorPipeline.storeOpenFailingSince, now)
        guard case .failed = services.storage.availability else {
            return XCTFail("the failed open must be surfaced: \(services.storage.availability)")
        }

        launch.clock.advance(by: TimeInterval(AlertLimits.storageFailingMinutes * 60 + 60))
        let drains = services.sensorPipeline.completedDrainCount
        services.sensorPipeline.retryHeldEvents()
        await waitUntil("a drain attempt") { services.sensorPipeline.completedDrainCount > drains && services.sensorPipeline.isIdle }
        guard case .firing = services.productionAlerts?.phase(of: .storageFailing) else {
            return XCTFail("the storage-failure alert must fire: \(String(describing: services.productionAlerts?.phase(of: .storageFailing)))")
        }
        services.updateClockMismatchLatch(now: launch.clock.now)
        XCTAssertEqual(services.clockMismatchLatchedFor, latched, "with no store the latest reading is unknown: the latch is kept")
        XCTAssertEqual(launch.preferences.clockMismatch.latchedFor, latched)
        XCTAssertTrue(launch.widget.published.isEmpty, "no widget snapshot without a known latest reading")
    }

    // MARK: - B1: the clock latch and the widget survive the launch

    func test_S1_clockLatchAndWidgetSurviveTheLaunch() async throws {
        let now = Date()
        let latest = seedReadings(at: [now.addingTimeInterval(-120)], now: now)[0]
        let gate = OpenGate()
        let launch = try await makeLaunch(now: now, seed: [latest], persistedLatch: latest.date) { url, diagnostics in
            await gate.wait()
            return try await GlucoseStore.production(at: url, diagnostics: diagnostics)
        }
        let services = launch.services
        let bootstrap = Task { await services.bootstrap() }
        await waitUntil("pipeline active") { services.sensorPipeline.completedDrainCount >= 1 }
        // Wakes while the store is still opening (a state from the sensor, a foreground tick).
        launch.sensor.deliver(state: .active(sessionStart: launch.session.start, expiresAt: launch.session.expiresAt))
        await waitUntil("state processed") { services.sensorPipeline.receivedStateCount >= 2 && services.sensorPipeline.isIdle }
        services.updateClockMismatchLatch(now: launch.clock.now)
        XCTAssertNil(services.productionStore)
        XCTAssertEqual(services.clockMismatchLatchedFor, latest.date, "the latch is not judged against an unknown latest reading")
        XCTAssertEqual(launch.preferences.clockMismatch.latchedFor, latest.date)
        XCTAssertTrue(launch.widget.published.isEmpty, "no snapshot before the latest reading is known")

        await gate.open()
        await bootstrap.value
        await waitUntil("idle") { services.sensorPipeline.isIdle }
        services.updateClockMismatchLatch(now: launch.clock.now)
        XCTAssertEqual(services.latestLiveReading?.id, latest.id)
        XCTAssertEqual(services.clockMismatchLatchedFor, latest.date, "the latch for R survives the relaunch")
        XCTAssertEqual(launch.preferences.clockMismatch.latchedFor, latest.date)
        XCTAssertFalse(launch.widget.published.isEmpty)
        XCTAssertTrue(launch.widget.published.allSatisfy { $0 == latest.id }, "every snapshot carries the latest reading: \(launch.widget.published)")
    }

    // MARK: - D43: expiry reminders at foreground

    /// Notifications denied while the sensor is paired: the reminders cannot be scheduled. The user
    /// allows notifications in iOS Settings and comes back: the reminders become pending.
    func test_S5_remindersBecomePendingWhenNotificationsAreAllowedAndTheAppComesToTheForeground() async throws {
        let now = Date()
        let launch = try await makeLaunch(now: now)
        let services = launch.services
        launch.center.permissions.authorization = .denied
        await services.bootstrap()
        launch.sensor.deliver(state: .active(sessionStart: launch.session.start, expiresAt: launch.session.expiresAt))
        await waitUntil("active state processed") { services.sensorPipeline.receivedStateCount >= 2 && services.sensorPipeline.isIdle }
        XCTAssertTrue(launch.center.pending("sensorExpiringIn24Hours").isEmpty, "denied: nothing could be scheduled")

        launch.center.permissions.authorization = .authorized
        await services.handleForeground()
        defer { services.handleBackground() }
        XCTAssertFalse(launch.center.pending("sensorExpiringIn24Hours").isEmpty, "allowed + foreground: the 24-hour reminder is pending")
        XCTAssertFalse(launch.center.pending("sensorExpiringIn2Hours").isEmpty)
        XCTAssertFalse(launch.center.pending("sensorGracePeriod").isEmpty)
        XCTAssertEqual(launch.center.pending("sensorExpiringIn24Hours").first?.fireDate,
                       launch.session.expiresAt.addingTimeInterval(-24 * 3_600))
    }

    /// A reminder the system dropped (or never kept) is added again when the app becomes active.
    func test_S5_foregroundAddsAgainAReminderTheSystemDropped() async throws {
        let now = Date()
        let launch = try await makeLaunch(now: now)
        let services = launch.services
        await services.bootstrap()
        launch.sensor.deliver(state: .active(sessionStart: launch.session.start, expiresAt: launch.session.expiresAt))
        await waitUntil("active state processed") { services.sensorPipeline.receivedStateCount >= 2 && services.sensorPipeline.isIdle }
        let reminder = try XCTUnwrap(launch.center.pending("sensorExpiringIn24Hours").first)
        launch.center.removePending(identifiers: [reminder.identifier])
        XCTAssertTrue(launch.center.pending("sensorExpiringIn24Hours").isEmpty)

        await services.handleForeground()
        defer { services.handleBackground() }
        XCTAssertEqual(launch.center.pending("sensorExpiringIn24Hours").first?.fireDate, reminder.fireDate)
    }

    // MARK: - m1: Trio's newest reading never moves backwards at launch

    func test_trioFirstWriteAfterRelaunchNeverMovesTrioBackwards() async throws {
        let store = RecordingTrioStore()
        let start = PipelineFixtures.start
        let a = PipelineFixtures.reading(.mgdl(120), at: start.addingTimeInterval(-600))
        let b = PipelineFixtures.reading(.mgdl(121), at: start.addingTimeInterval(-300))
        let previous = TrioCoordinator(appGroupID: trioGroup, store: store, diagnostics: NullDiagnosticLog(), clock: { start })
        previous.configure(enabled: true, liveOutputsAllowed: true)
        await previous.publish([a, b], session: PipelineFixtures.session)
        XCTAssertEqual(store.payload.count, 2)

        // Relaunch: a new coordinator over the same App Group.
        let relaunched = TrioCoordinator(appGroupID: trioGroup, store: store, diagnostics: NullDiagnosticLog(), clock: { start })
        relaunched.configure(enabled: true, liveOutputsAllowed: true)
        let olderBackfill = PipelineFixtures.reading(.mgdl(118), at: start.addingTimeInterval(-900), backfill: true)
        let result = await relaunched.publish([olderBackfill], session: PipelineFixtures.session)
        XCTAssertNil(result, "an older reading alone is held, not written")
        XCTAssertEqual(store.payload.count, 2)
        XCTAssertEqual(store.payload.first?["Value"] as? Int, 121, "Trio's newest is unchanged")

        let newer = PipelineFixtures.reading(.mgdl(119), at: start.addingTimeInterval(-10))
        await relaunched.publish([newer], session: PipelineFixtures.session)
        XCTAssertEqual(store.payload.first?["Value"] as? Int, 119, "a newer reading moves Trio forward")
        XCTAssertEqual(store.payload.count, 2, "and carries the held reading with it")

        await relaunched.reseed(with: [a, b], session: PipelineFixtures.session)
        XCTAssertEqual(store.payload.compactMap { $0["Value"] as? Int }, [119, 121, 120, 118])
    }

    /// The re-seed alone (no newer reading yet) releases the held readings into the stored window.
    func test_trioReseedReleasesHeldReadingsWithTheStoredOnes() async throws {
        let store = RecordingTrioStore()
        let start = PipelineFixtures.start
        let b = PipelineFixtures.reading(.mgdl(121), at: start.addingTimeInterval(-300))
        let previous = TrioCoordinator(appGroupID: trioGroup, store: store, diagnostics: NullDiagnosticLog(), clock: { start })
        previous.configure(enabled: true, liveOutputsAllowed: true)
        await previous.publish([b], session: PipelineFixtures.session)

        let relaunched = TrioCoordinator(appGroupID: trioGroup, store: store, diagnostics: NullDiagnosticLog(), clock: { start })
        relaunched.configure(enabled: true, liveOutputsAllowed: true)
        let older = PipelineFixtures.reading(.mgdl(118), at: start.addingTimeInterval(-900), backfill: true)
        await relaunched.publish([older], session: PipelineFixtures.session)
        await relaunched.reseed(with: [b], session: PipelineFixtures.session)
        XCTAssertEqual(store.payload.compactMap { $0["Value"] as? Int }, [121, 118])
        XCTAssertEqual(TrioCoordinator.newestReadingDate(in: store.data(forKey: TrioAppGroupContract.readingsKey)), b.date.roundedToMilliseconds)
    }
}

private extension Date {
    /// The payload's `/Date(<ms>)/` precision.
    var roundedToMilliseconds: Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}

/// Holds the production database's opening until the test opens the gate.
/// Counts calls from any thread.
final class CallCounter: @unchecked Sendable {
    // @unchecked Sendable: `count` is only read and written while holding `lock`.
    private let lock = NSLock()
    private var count = 0
    /// Counts this call and returns its number (1 for the first).
    func next() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}

actor OpenGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// Records which latest reading each widget snapshot carried (nil = none).
@MainActor
final class RecordingWidgetPublisher: AppWidgetPublishing {
    var accent = AccentChoice.default
    private(set) var published: [String?] = []

    func publish(latestLive: GlucoseReading?, previousLive: GlucoseReading?, recent: [GlucoseReading], sensorState: SensorState, now: Date) {
        published.append(latestLive?.id)
    }
}

/// A `SensorDevice` the test drives: readings and states on demand, a fixed session, no Bluetooth.
final class ScriptedSensorDevice: SensorDevice, @unchecked Sendable {
    // @unchecked Sendable: `session` is only read and written while holding `lock`; the
    // continuations are Sendable.
    let readings: AsyncStream<GlucoseReading>
    let state: AsyncStream<SensorState>
    let calibrationUpdates: AsyncStream<CalibrationUpdate>
    private let readingsContinuation: AsyncStream<GlucoseReading>.Continuation
    private let stateContinuation: AsyncStream<SensorState>.Continuation
    private let lock = NSLock()
    private var session: SensorSession?

    init(session: SensorSession?) {
        (readings, readingsContinuation) = AsyncStream.makeStream(of: GlucoseReading.self, bufferingPolicy: .unbounded)
        (state, stateContinuation) = AsyncStream.makeStream(of: SensorState.self, bufferingPolicy: .unbounded)
        (calibrationUpdates, _) = AsyncStream.makeStream(of: CalibrationUpdate.self, bufferingPolicy: .unbounded)
        self.session = session
        stateContinuation.yield(.searching)
    }

    var currentSession: SensorSession? {
        get async { lock.withLock { session } }
    }

    private var starts = 0
    private var failsToStart = false
    /// How many times `start(pairingCode:)` was called (a relaunch, the first unlock).
    var startCount: Int { lock.withLock { starts } }
    /// True: `start` fails as G7Kit's does before the first unlock (pairing record unreadable).
    var startFails: Bool {
        get { lock.withLock { failsToStart } }
        set { lock.withLock { failsToStart = newValue } }
    }

    func start(pairingCode: String?) async throws {
        let fails = lock.withLock { () -> Bool in
            starts += 1
            return failsToStart
        }
        if fails { throw G7StartError.credentialStoreFailed("Keychain unavailable before the first unlock") }
    }
    func stop() async {}
    func pair(code: String) async throws {
        if lock.withLock({ currentMode == .listen }) { throw G7StartError.notAvailableInListenMode }
    }
    func pairAgain(code: String) async throws {
        if lock.withLock({ currentMode == .listen }) { throw G7StartError.notAvailableInListenMode }
    }
    func forgetSensor() async {}
    var heartbeatTarget: G7HeartbeatTarget? { get async { nil } }
    var hasStoredSensor: Bool { get async { true } }
    var storedSensorSerial: String? { get async { PipelineFixtures.serial } }

    // D45 / D47 / audit m1, recorded.
    private var currentMode: G7ConnectionMode = .primary(slot: .recommendedDefault)
    private var modeChanges: [G7ConnectionMode] = []
    private var failsToSetMode = false
    private var recording: [Bool] = []
    private var floors: [(reading: GlucoseReading?, serial: String)] = []

    /// Starts in `mode` (what `G7Configuration.mode` would say).
    func configure(mode: G7ConnectionMode) { lock.withLock { currentMode = mode } }
    var mode: G7ConnectionMode { get async { lock.withLock { currentMode } } }
    /// Every successful `setMode`, in order.
    var modeHistory: [G7ConnectionMode] { lock.withLock { modeChanges } }
    /// True: `setMode` fails as G7Kit's does when the stored pairing cannot be deleted.
    var setModeFails: Bool {
        get { lock.withLock { failsToSetMode } }
        set { lock.withLock { failsToSetMode = newValue } }
    }
    func setMode(_ mode: G7ConnectionMode) async throws {
        let fails = lock.withLock { failsToSetMode }
        if fails { throw G7StartError.credentialStoreFailed("Keychain unavailable") }
        lock.withLock {
            currentMode = mode
            modeChanges.append(mode)
        }
        deliver(state: mode == .listen ? .searching : .notPaired)
    }
    var supportsCalibration: Bool { get async { lock.withLock { currentMode != .listen } } }
    var recordingChanges: [Bool] { lock.withLock { recording } }
    func setRecordsRawGlucosePackets(_ enabled: Bool) async { lock.withLock { recording.append(enabled) } }
    /// Every `setLatestStoredReading` call, in order.
    var latestStoredReadingCalls: [(reading: GlucoseReading?, serial: String)] { lock.withLock { floors } }
    func setLatestStoredReading(_ reading: GlucoseReading?, forSerial serial: String) async {
        lock.withLock { floors.append((reading, serial)) }
    }
    var acceptedCalibrationRange: ClosedRange<Int> { 40...400 }
    func submitCalibration(_ request: CalibrationRequest) async throws(CalibrationRefusal) {}

    func deliver(_ reading: GlucoseReading) {
        readingsContinuation.yield(reading)
    }

    func deliver(state newState: SensorState) {
        stateContinuation.yield(newState)
    }
}
