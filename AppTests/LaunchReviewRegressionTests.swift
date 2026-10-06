// Regression tests adopted from the launch-order re-review's probes (FU-B2, at 39aaff8):
// m4 — a failed open must not disable the memoryless clock-change check;
// m5 — the launch Trio hold must not withhold valid readings (future App Group newest, failed open);
// m6 — the latch survives an older reading held before the open; plus the stale-latch and payload
// date parsing probes. Real `LiveAppServices` with a scripted sensor (see LaunchOrderTests).

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
final class LaunchReviewRegressionTests: XCTestCase {
    private let trioGroup = "group.org.nightscout.ABCDE12345.trio.trio-app-group"

    final class UptimeBox: @unchecked Sendable {
        var value: Uptime?
        init(_ value: Uptime?) { self.value = value }
    }

    private struct Launch {
        let services: LiveAppServices
        let sensor: ScriptedSensorDevice
        let clock: PipelineTestClock
        let preferences: AppPreferences
        let trioStore: RecordingTrioStore
        let widget: RecordingWidgetPublisher
        let session: SensorSession
        let uptime: UptimeBox
    }

    private func makeLaunch(
        now: Date, seed: [GlucoseReading] = [], persistedLatch: Date? = nil, trioPayload: Data? = nil,
        uptime: Uptime? = nil,
        openStore: (@Sendable (URL, any DiagnosticLog) async throws -> GlucoseStore)? = nil
    ) async throws -> Launch {
        let directory = PipelineFixtures.temporaryDirectory()
        let databaseURL = directory.appendingPathComponent("GlucoseStore/readings.sqlite")
        if !seed.isEmpty {
            let store = try await GlucoseStore.production(at: databaseURL)
            _ = try await store.insert(seed)
        }
        let clock = PipelineTestClock(now)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "launch-review-\(UUID().uuidString)"))
        let preferences = AppPreferences(defaults: defaults)
        preferences.trioBridgeEnabled = true
        preferences.developerLiveOutputs = true
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
        if let trioPayload { trioStore.setData(trioPayload, forKey: TrioAppGroupContract.readingsKey) }
        let widget = RecordingWidgetPublisher()
        let box = UptimeBox(uptime)
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
        dependencies.uptime = { box.value }
        if let openStore { dependencies.openStore = openStore }
        return Launch(services: LiveAppServices(dependencies), sensor: sensor, clock: clock, preferences: preferences,
                      trioStore: trioStore, widget: widget, session: session, uptime: box)
    }

    private func reading(_ value: Int, at date: Date, launch: Launch, backfill: Bool = false) -> GlucoseReading {
        GlucoseReading(
            id: GlucoseReading.sensorID(serial: PipelineFixtures.serial, sensorTimestamp: UInt32(date.timeIntervalSince(launch.session.start))),
            date: date, value: .mgdl(value), trendRate: 0, isBackfill: backfill, source: .sensor, sensorSerial: PipelineFixtures.serial
        )
    }

    private func payload(dt: String) -> Data {
        Data("[{\"DT\":\"\(dt)\",\"ST\":\"\(dt)\",\"Trend\":4,\"Value\":111,\"direction\":\"Flat\"}]".utf8)
    }

    // MARK: - m5: Trio hold with an implausible App Group newest and a failed open

    func test_S5_trioHoldWithAFutureAppGroupNewestAndAFailedOpenStillFeedsTrio() async throws {
        let now = Date()
        let futureMs = Int64((now.timeIntervalSince1970 + 3_600) * 1000)
        let foreign = payload(dt: "/Date(\(futureMs))/")
        let launch = try await makeLaunch(now: now, trioPayload: foreign) { _, _ in throw FlakyRepository.DiskFull() }
        let services = launch.services
        await services.bootstrap()
        XCTAssertNil(services.productionStore)
        var delivered = 0
        for minute in stride(from: 0, through: 25, by: 5) {
            launch.clock.set(now.addingTimeInterval(TimeInterval(minute * 60)))
            launch.sensor.deliver(reading(100 + minute, at: launch.clock.now.addingTimeInterval(-5), launch: launch))
            delivered += 1
            await waitUntil("reading \(delivered) processed") { services.sensorPipeline.receivedReadingCount >= delivered && services.sensorPipeline.isIdle }
            await services.sendTrioAlertInput()
        }
        let unchanged = launch.trioStore.data(forKey: TrioAppGroupContract.readingsKey) == foreign
        XCTAssertFalse(unchanged, "valid live readings for 25 min must reach Trio (or the starvation must surface)")
        XCTAssertEqual(launch.trioStore.payload.first?["Value"] as? Int, 125, "the newest live reading is Trio's newest")
        XCTAssertEqual(services.trio.heldBackReadings, 0)
    }

    // MARK: - m1: DT parsing of malformed payloads

    func test_trioPayloadNewestDateIgnoresMalformedEntries() {
        func newest(_ text: String?) -> Date? {
            TrioCoordinator.newestReadingDate(in: text.map { Data($0.utf8) })
        }
        let unreadable: [String?] = [
            nil, "not json", "{}", "[1,2]", "[{\"DT\":5}]", "[{\"DT\":\"12345\"}]", "[{\"DT\":\"/Date(abc)/\"}]",
            "[{\"DT\":\"/Date(1426292016000-0700)/\"}]", "[{\"DT\":\")123(\"}]", "[{\"DT\":\"/Date()/\"}]",
            "[{\"DT\":\"/Date(nan)/\"}]", "[{\"DT\":\"/Date(inf)/\"}]", "[]",
        ]
        for text in unreadable {
            XCTAssertNil(newest(text), "\(text ?? "nil") has no usable reading time")
        }
        XCTAssertEqual(newest("[{\"DT\":\"/Date(abc)/\"},{\"DT\":\"/Date(1758007800123)/\"}]")?.timeIntervalSince1970, 1_758_007_800.123)
        // A huge date parses, and is then refused as a floor for being in the future (m5 test above).
        XCTAssertGreaterThan(newest("[{\"DT\":\"/Date(1e300)/\"}]") ?? .distantPast, Date())
    }

    // MARK: - m6: latch with a re-delivered older reading held before the open

    func test_S1_latchKeptWhenAnOlderReadingIsHeldBeforeTheOpen() async throws {
        let now = Date()
        let start = now.addingTimeInterval(-2 * 86_400)
        let rDate = now.addingTimeInterval(-120)
        let r = GlucoseReading(id: GlucoseReading.sensorID(serial: PipelineFixtures.serial, sensorTimestamp: UInt32(rDate.timeIntervalSince(start))),
                               date: rDate, value: .mgdl(120), trendRate: 0, isBackfill: false, source: .sensor, sensorSerial: PipelineFixtures.serial)
        let gate = OpenGate()
        let launch = try await makeLaunch(now: now, seed: [r], persistedLatch: rDate) { url, diagnostics in
            await gate.wait()
            return try await GlucoseStore.production(at: url, diagnostics: diagnostics)
        }
        let services = launch.services
        let bootstrap = Task { await services.bootstrap() }
        await waitUntil("active") { services.sensorPipeline.completedDrainCount >= 1 }
        launch.sensor.deliver(reading(118, at: rDate.addingTimeInterval(-300), launch: launch, backfill: true))
        await waitUntil("held") { services.sensorPipeline.receivedReadingCount >= 1 && services.sensorPipeline.isIdle }
        services.updateClockMismatchLatch(now: launch.clock.now)
        XCTAssertEqual(services.clockMismatchLatchedFor, rDate, "an older held reading must not clear R's latch")
        await gate.open()
        await bootstrap.value
        await waitUntil("idle") { services.sensorPipeline.isIdle && services.sensorPipeline.heldReadingCount == 0 }
        services.updateClockMismatchLatch(now: launch.clock.now)
        XCTAssertEqual(services.latestLiveReading?.id, r.id)
        XCTAssertEqual(services.clockMismatchLatchedFor, rDate)
        XCTAssertTrue(launch.widget.published.allSatisfy { $0 == r.id })
    }

    // MARK: - B1 fix: a stale latch after a store reset / new sensor

    func test_S1_staleLatchIsHarmlessAndClearsOnTheNextReading() async throws {
        let now = Date()
        let old = now.addingTimeInterval(-3 * 86_400)
        let launch = try await makeLaunch(now: now, persistedLatch: old) // empty store (reset / new install of the DB)
        let services = launch.services
        await services.bootstrap()
        await waitUntil("idle") { services.sensorPipeline.isIdle }
        services.updateClockMismatchLatch(now: launch.clock.now)
        let n = reading(130, at: now.addingTimeInterval(-5), launch: launch)
        launch.sensor.deliver(n)
        await waitUntil("stored") { services.sensorPipeline.storedReadingCount >= 1 && services.sensorPipeline.isIdle }
        services.updateClockMismatchLatch(now: launch.clock.now)
        XCTAssertEqual(services.latestLiveReading?.id, n.id)
        XCTAssertNil(services.clockMismatchLatchedFor, "a new, plausible reading clears a latch held for a reading that no longer exists")
        XCTAssertNil(launch.preferences.clockMismatch.latchedFor)
    }

    // MARK: - m4: the memoryless clock check during a failed open

    func test_S1_failedOpenStillDetectsAClockChange() async throws {
        let now = Date()
        let boot = "test-boot"
        let launch = try await makeLaunch(now: now, uptime: Uptime(seconds: 10_000, boot: boot)) { _, _ in throw FlakyRepository.DiskFull() }
        let services = launch.services
        await services.bootstrap()
        let n = reading(140, at: now.addingTimeInterval(-60), launch: launch)
        launch.sensor.deliver(n)
        await waitUntil("held") { services.sensorPipeline.receivedReadingCount >= 1 && services.sensorPipeline.isIdle }
        services.updateClockMismatchLatch(now: launch.clock.now)
        // The phone clock is set back 30 min; 40 real minutes pass with no reading.
        launch.uptime.value = Uptime(seconds: 10_000 + 40 * 60, boot: boot)
        launch.clock.set(now.addingTimeInterval(10 * 60))
        services.updateClockMismatchLatch(now: launch.clock.now)
        let direct = ClockMismatchMonitor.check(
            ClockMismatchState(latchedFor: nil, lastCheckWallClock: now, lastCheckUptime: Uptime(seconds: 10_000, boot: boot)),
            latest: n, previous: nil, now: launch.clock.now, uptime: launch.uptime.value
        )
        XCTAssertEqual(direct.latchedFor, n.date, "the monitor itself latches the shown reading on a clock change")
        XCTAssertEqual(services.latestLiveReading?.id, n.id, "the held reading is shown as the latest")
        XCTAssertEqual(services.clockMismatchLatchedFor, n.date, "the clock change must latch the shown reading")
    }

    // MARK: - m5: a launch hold is bounded and visible

    /// Phase 3 carry-over (supersedes the 2-minute release): a reading held back at launch (not newer
    /// than the App Group's newest) is never written on its own — not after 2 minutes, not on a retry,
    /// not when the store fails to open — so Trio's newest never moves backwards. It goes out with
    /// the next newer reading. While held it is shown in the summary.
    func test_S5_trioHeldReadingsNeverMoveTrioBackwardsAndGoOutWithTheNextNewerReading() async {
        let store = RecordingTrioStore()
        let clock = PipelineTestClock(PipelineFixtures.start)
        let newestBefore = PipelineFixtures.reading(.mgdl(121), at: PipelineFixtures.start.addingTimeInterval(-300))
        let previous = TrioCoordinator(appGroupID: trioGroup, store: store, diagnostics: NullDiagnosticLog(), clock: clock.closure)
        previous.configure(enabled: true, liveOutputsAllowed: true)
        await previous.publish([newestBefore], session: PipelineFixtures.session)

        let relaunched = TrioCoordinator(appGroupID: trioGroup, store: store, diagnostics: NullDiagnosticLog(), clock: clock.closure)
        relaunched.configure(enabled: true, liveOutputsAllowed: true)
        let older = PipelineFixtures.reading(.mgdl(118), at: PipelineFixtures.start.addingTimeInterval(-900), backfill: true)
        await relaunched.publish([older], session: PipelineFixtures.session)
        XCTAssertEqual(relaunched.summary.heldBackReadings, 1)
        XCTAssertEqual(relaunched.summary.heldBackSince, PipelineFixtures.start)

        clock.advance(by: 10 * 60)
        await relaunched.retry(session: PipelineFixtures.session)
        let anotherOlder = PipelineFixtures.reading(.mgdl(119), at: PipelineFixtures.start.addingTimeInterval(-600), backfill: true)
        await relaunched.publish([anotherOlder], session: PipelineFixtures.session)
        XCTAssertEqual(store.payload.compactMap { $0["Value"] as? Int }, [121], "held readings are never written on their own")
        XCTAssertEqual(relaunched.summary.heldBackReadings, 2)

        let newer = PipelineFixtures.reading(.mgdl(123), at: PipelineFixtures.start.addingTimeInterval(10 * 60))
        clock.set(newer.date.addingTimeInterval(5))
        await relaunched.publish([newer], session: PipelineFixtures.session)
        XCTAssertEqual(store.payload.compactMap { $0["Value"] as? Int }, [123, 119, 118], "they go out with the next newer reading")
        XCTAssertEqual(relaunched.summary.heldBackReadings, 0)
        XCTAssertNil(relaunched.summary.heldBackSince)
    }

    /// A hold counts as starving Trio once it has lasted the starvation threshold (a backstop: the
    /// 2-minute release normally ends it long before), so the Trio bridge alert can fire.
    func test_S5_aLongHoldCountsAsStarvingTrio() {
        var summary = TrioBridgeSummary.off
        summary.isEnabled = true
        summary.liveOutputsAllowed = true
        summary.heldBackReadings = 2
        summary.heldBackSince = PipelineFixtures.start
        summary.refreshStarvation(now: PipelineFixtures.start.addingTimeInterval(14 * 60))
        XCTAssertFalse(summary.isStarving)
        summary.refreshStarvation(now: PipelineFixtures.start.addingTimeInterval(15 * 60))
        XCTAssertTrue(summary.isStarving)
        guard case .writeFailing = summary.alertInput else { return XCTFail("a long hold must raise the Trio bridge alert") }
    }
}
