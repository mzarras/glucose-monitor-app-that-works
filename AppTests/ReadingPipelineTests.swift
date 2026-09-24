// The reading pipeline against the real store, alert service, Trio bridge and uploader, with fake
// ports (notification center, audio, Trio's App Group, the upload destination) and a test clock.

import AlertEngine
import Foundation
import GlucoseCore
import GlucoseStore
import NightscoutKit
import TrioBridge
import XCTest
@testable import Sensor

@MainActor
final class ReadingPipelineTests: XCTestCase {
    private struct Harness {
        let clock: PipelineTestClock
        let diagnostics: CollectingDiagnosticLog
        let source: ScriptedCGMSource
        let store: GlucoseStore
        let pipeline: ReadingPipeline
        let alerts: AlertService
        let center: RecordingNotificationCenter
        let trioStore: RecordingTrioStore
        let trio: TrioCoordinator
        let destination: RecordingUploadDestination
        let uploader: ReadingUploader
    }

    private var harnesses: [Harness] = []

    override func tearDown() async throws {
        for harness in harnesses { harness.pipeline.stopConsuming() }
        harnesses = []
    }

    private func makeHarness(session: SensorSession? = PipelineFixtures.session, attachStore: Bool = true) async throws -> Harness {
        let clock = PipelineTestClock(PipelineFixtures.start)
        let diagnostics = CollectingDiagnosticLog()
        let source = ScriptedCGMSource(session: session)
        let store = try GlucoseStore.productionInMemory(diagnostics: diagnostics, now: clock.closure)
        let center = RecordingNotificationCenter(clock: clock)
        let ports = AlertPorts(
            notificationCenter: center, audio: RecordingAudioPlayer(clock: clock), alarms: nil,
            configuration: PipelineFixtures.utcConfiguration, diagnostics: diagnostics
        )
        let alerts = ports.makeProductionService(settings: .defaults, snapshot: nil, clock: PipelineAlertClock(now: clock.closure, uptime: nil)) { _ in }
        let trioStore = RecordingTrioStore()
        let trio = TrioCoordinator(appGroupID: "group.org.nightscout.ABCDE12345.trio.trio-app-group", store: trioStore, diagnostics: diagnostics, clock: clock.closure)
        trio.configure(enabled: true, liveOutputsAllowed: true)
        let destination = RecordingUploadDestination()
        let queueFile = PipelineFixtures.temporaryDirectory().appendingPathComponent("queue.json")
        let uploader = try ReadingUploader(destination: destination, queueFile: queueFile, clock: PipelineTestWallClock(clock: clock), log: diagnostics)
        let pipeline = ReadingPipeline(name: "test", source: source, diagnostics: diagnostics, now: clock.closure)
        pipeline.outputs.alerts = alerts
        pipeline.outputs.trio = trio.activeBridge
        pipeline.outputs.uploaders = [uploader]
        await alerts.start()
        pipeline.startConsuming()
        if attachStore { pipeline.attach(store: store) }
        pipeline.activate()
        let harness = Harness(
            clock: clock, diagnostics: diagnostics, source: source, store: store, pipeline: pipeline, alerts: alerts, center: center,
            trioStore: trioStore, trio: trio, destination: destination, uploader: uploader
        )
        harnesses.append(harness)
        return harness
    }

    private func settle(_ harness: Harness, readings: Int, states: Int = 0) async {
        await waitUntil("pipeline processed \(readings) reading(s), \(states) state(s)") {
            harness.pipeline.receivedReadingCount == readings && harness.pipeline.receivedStateCount == states && harness.pipeline.isIdle
        }
    }

    // MARK: - S2

    /// Every newly stored reading passes LiveReadingGate in the pipeline, with the source's current
    /// session and the pipeline clock, before Trio, alerts or uploads see it. Consumers gate again
    /// themselves; their own refusal counters staying at zero proves the pipeline's gate ran first.
    func test_S2_pipelineGatesEveryNewReadingBeforeConsumers() async throws {
        let harness = try await makeHarness()
        let now = PipelineFixtures.start
        let session = PipelineFixtures.session
        let valid = PipelineFixtures.reading(.mgdl(65), at: now.addingTimeInterval(-60))
        let otherSensor = PipelineFixtures.reading(.mgdl(62), at: now.addingTimeInterval(-120), serial: "OTHERG7-99999999")
        let beforeSession = PipelineFixtures.reading(.mgdl(61), at: session.start.addingTimeInterval(-600))
        let duringWarmUp = PipelineFixtures.reading(.mgdl(60), at: session.start.addingTimeInterval(600))
        let nearFuture = PipelineFixtures.reading(.mgdl(66), at: now.addingTimeInterval(30)) // within the 60 s tolerance

        for reading in [otherSensor, beforeSession, duringWarmUp, valid, nearFuture] {
            harness.source.deliver(reading)
        }
        await settle(harness, readings: 5)

        // Stored as history (the source is the first gate), but refused for the consumers.
        let stored = try await harness.store.readings(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(Set(stored.map(\.id)), Set([otherSensor, beforeSession, duringWarmUp, valid, nearFuture].map(\.id)))
        XCTAssertEqual(harness.pipeline.gateRefusalCount, 3)

        // Trio has exactly the two that passed, and never saw the others.
        let payloadDates = harness.trioStore.payload.compactMap { $0["DT"] as? String }
        XCTAssertEqual(payloadDates.count, 2)
        let trioStatus = await harness.trio.bridge!.status
        XCTAssertNil(trioStatus.lastGateRefusal, "the bridge saw a reading the pipeline should have refused")

        // Uploads: queued exactly the two, no gate refusal inside the uploader.
        let uploadStatus = await harness.uploader.status
        XCTAssertEqual(uploadStatus.queueDepth, 2)
        XCTAssertEqual(uploadStatus.refusedByGate, 0, "the uploader saw a reading the pipeline should have refused")

        // Alerts: the valid 65 fired Low (only valid readings reached the engine).
        XCTAssertEqual(harness.center.posted("low").count, 1)
        XCTAssertEqual(harness.alerts.engine.currentReading(at: harness.clock.now)?.date, nearFuture.date)

        // Each refusal is a diagnostic, never silent.
        let refusals = harness.diagnostics.messages.filter { $0.contains("gate refused stored reading") }
        XCTAssertEqual(refusals.count, 3)
    }

    /// A reading refused by the store (here: dated beyond the future tolerance) does not keep the
    /// valid readings of the same delivery out, and never reaches a consumer.
    func test_S2_storeRefusalInABatchKeepsTheValidReadings() async throws {
        let harness = try await makeHarness()
        let now = PipelineFixtures.start
        let valid = PipelineFixtures.reading(.mgdl(120), at: now.addingTimeInterval(-300))
        let farFuture = PipelineFixtures.reading(.mgdl(121), at: now.addingTimeInterval(600))
        // Held until the store is attached so both arrive in one batch.
        harness.pipeline.deactivate()
        harness.source.deliver(valid)
        harness.source.deliver(farFuture)
        await waitUntil("both received") { harness.pipeline.receivedReadingCount == 2 }
        harness.pipeline.activate()
        await settle(harness, readings: 2)

        let stored = try await harness.store.readings(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(stored.map(\.id), [valid.id])
        XCTAssertEqual(harness.pipeline.storeRefusalCount, 1)
        XCTAssertEqual(harness.trioStore.payload.count, 1)
        let uploadStatus = await harness.uploader.status
        XCTAssertEqual(uploadStatus.queueDepth, 1)
    }

    // MARK: - S3

    /// A reading delivered again (a repeated live packet, or its backfill copy with the same id and a
    /// date re-derived within 2 s) is stored once and published once.
    func test_S3_redeliveredReadingIsPublishedOnce() async throws {
        let harness = try await makeHarness()
        let date = PipelineFixtures.start.addingTimeInterval(-60)
        let live = PipelineFixtures.reading(.mgdl(64), at: date)
        let backfillCopy = GlucoseReading(
            id: live.id, date: date.addingTimeInterval(1), value: live.value, trendRate: live.trendRate,
            isBackfill: true, source: .sensor, sensorSerial: live.sensorSerial
        )
        harness.source.deliver(live)
        await settle(harness, readings: 1)
        harness.source.deliver(live)
        harness.source.deliver(backfillCopy)
        await settle(harness, readings: 3)

        XCTAssertEqual(harness.pipeline.storedReadingCount, 1)
        XCTAssertEqual(harness.trioStore.writesOfReadings, 1)
        XCTAssertEqual(harness.trioStore.payload.count, 1)
        XCTAssertEqual(harness.center.posted("low").count, 1)
        _ = await harness.uploader.flush()
        XCTAssertEqual(harness.destination.uploaded.map(\.id), [live.id])
        XCTAssertEqual(harness.destination.uploaded.first?.isBackfill, false, "the stored (first) copy is the one uploaded")
    }

    // MARK: - S6

    /// Imported history goes to the store only. Written by an importer it never enters the pipeline;
    /// delivered through a source by mistake, the pipeline's gate refuses it before any consumer.
    func test_S6_importedReadingsNeverReachConsumers() async throws {
        let harness = try await makeHarness()
        let base = PipelineFixtures.start
        // 1. The importers' path: straight into the store.
        let history = (1...12).map { PipelineFixtures.imported(.mgdl(50 + $0), at: base.addingTimeInterval(TimeInterval(-$0 * 300))) }
        let stored = try await harness.store.insert(history)
        XCTAssertEqual(stored.count, 12)
        await harness.pipeline.storeDidChange()
        // 2. A source delivering an imported reading (never happens; defence in depth).
        let delivered = PipelineFixtures.imported(.belowRange, at: base.addingTimeInterval(-30))
        harness.source.deliver(delivered)
        await settle(harness, readings: 1)

        XCTAssertEqual(harness.pipeline.gateRefusalCount, 1)
        XCTAssertEqual(harness.trioStore.writesOfReadings, 0)
        XCTAssertTrue(harness.trioStore.payload.isEmpty)
        let uploadStatus = await harness.uploader.status
        XCTAssertEqual(uploadStatus.queueDepth, 0)
        XCTAssertEqual(uploadStatus.refusedByGate, 0)
        XCTAssertTrue(harness.center.posted.isEmpty, "an imported LOW or 51 must not alert")
        XCTAssertNil(harness.alerts.engine.currentReading(at: harness.clock.now))
        XCTAssertNil(harness.pipeline.latestLiveReading, "the current value is never imported history")
    }

    // MARK: - S5

    /// Before the first unlock the store cannot open: readings are held in memory (in order), the
    /// storage status says so, nothing reaches a consumer; once the store opens they are stored and
    /// published.
    func test_S5_storeClosedBeforeFirstUnlockSurfacesAndRecovers() async throws {
        let harness = try await makeHarness(attachStore: false)
        let base = PipelineFixtures.start
        let first = PipelineFixtures.reading(.mgdl(100), at: base.addingTimeInterval(-600))
        let second = PipelineFixtures.reading(.mgdl(98), at: base.addingTimeInterval(-300))
        harness.source.deliver(first)
        harness.source.deliver(state: .active(sessionStart: PipelineFixtures.session.start, expiresAt: PipelineFixtures.session.expiresAt))
        harness.source.deliver(second)
        await waitUntil("all received") { harness.pipeline.receivedReadingCount == 2 && harness.pipeline.receivedStateCount == 1 }

        XCTAssertEqual(harness.pipeline.heldReadingCount, 2)
        XCTAssertEqual(harness.pipeline.sensorState, .active(sessionStart: PipelineFixtures.session.start, expiresAt: PipelineFixtures.session.expiresAt),
                       "the UI sees the state even while held")
        XCTAssertEqual(
            StoreAvailability.derive(storeOpen: false, protectedDataAvailable: false, openError: nil, insertProblem: nil, heldReadings: harness.pipeline.heldReadingCount),
            .waitingForFirstUnlock(heldReadings: 2)
        )
        XCTAssertEqual(harness.trioStore.writesOfReadings, 0)
        XCTAssertTrue(harness.center.posted.isEmpty)

        // Protected data became available: the store opens and is attached.
        harness.pipeline.attach(store: harness.store)
        await settle(harness, readings: 2, states: 1)

        XCTAssertEqual(harness.pipeline.heldReadingCount, 0)
        let stored = try await harness.store.readings(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(stored.map(\.id), [first.id, second.id])
        XCTAssertEqual(harness.trioStore.payload.count, 2)
        let uploadStatus = await harness.uploader.status
        XCTAssertEqual(uploadStatus.queueDepth, 2)
        XCTAssertEqual(harness.pipeline.latestLiveReading?.id, second.id)
        XCTAssertEqual(
            StoreAvailability.derive(storeOpen: true, protectedDataAvailable: true, openError: nil, insertProblem: nil, heldReadings: 0),
            .open
        )
        XCTAssertEqual(
            StoreAvailability.derive(storeOpen: false, protectedDataAvailable: true, openError: "disk I/O error", insertProblem: nil, heldReadings: 3),
            .failed(message: "disk I/O error")
        )
    }

    // MARK: - S1

    /// After the phone clock is set back, the newest stored reading is dated in the future. It is not
    /// a current reading: the clock-mismatch latch holds it, the missed-readings alert counts from
    /// the rollback (not from the reading's future date), and a reading dated further ahead is
    /// refused before any consumer.
    func test_S1_futureDatedNewestReadingIsNotCurrent() async throws {
        let harness = try await makeHarness()
        let t = PipelineFixtures.start
        let latest = PipelineFixtures.reading(.mgdl(110), at: t)
        harness.source.deliver(latest)
        await settle(harness, readings: 1)

        // The clock is set back 30 minutes.
        let rolledBack = t.addingTimeInterval(-30 * 60)
        harness.clock.set(rolledBack)
        var latch = ClockMismatchMonitor.check(.initial, latest: harness.pipeline.latestLiveReading, previous: nil, now: rolledBack, uptime: nil)
        XCTAssertEqual(latch.latchedFor, latest.date, "a reading 30 min ahead of the clock is latched")
        // It stays latched after the clock passes the reading's date (review N1).
        latch = ClockMismatchMonitor.check(latch, latest: harness.pipeline.latestLiveReading, previous: nil, now: t.addingTimeInterval(120), uptime: nil)
        XCTAssertEqual(latch.latchedFor, latest.date)

        // Missed readings: 15 min after the rollback, although the newest reading's date is in the future.
        await harness.alerts.send(.tick)
        harness.clock.set(rolledBack.addingTimeInterval(14 * 60))
        await harness.alerts.send(.tick)
        XCTAssertFalse(isFiring(harness.alerts.phase(of: .missedReadings)))
        harness.clock.set(rolledBack.addingTimeInterval(15 * 60 + 30))
        await harness.alerts.send(.tick)
        XCTAssertTrue(isFiring(harness.alerts.phase(of: .missedReadings)), "missed readings must count from the rollback")

        // A reading dated beyond the tolerance of the (rolled-back) clock never reaches a consumer.
        let ahead = PipelineFixtures.reading(.mgdl(52), at: t.addingTimeInterval(300))
        harness.source.deliver(ahead)
        await settle(harness, readings: 2)
        XCTAssertEqual(harness.pipeline.storeRefusalCount, 1)
        XCTAssertEqual(harness.trioStore.payload.count, 1)
        XCTAssertTrue(harness.center.posted("urgentLow").isEmpty)
    }

    /// Memoryless check: the wall clock moved differently from real elapsed time between two wakes
    /// (set back 30 min, then 40 real minutes passed): the latest reading looks 10 min old but is
    /// not trusted.
    func test_S1_clockChangeBetweenWakesLatchesTheLatestReading() {
        let t = PipelineFixtures.start
        let reading = PipelineFixtures.reading(.mgdl(120), at: t)
        let boot = "boot-1"
        var state = ClockMismatchMonitor.check(.initial, latest: reading, previous: nil, now: t, uptime: Uptime(seconds: 1_000, boot: boot))
        XCTAssertNil(state.latchedFor)
        // Real time +40 min, wall clock only +10 min.
        state = ClockMismatchMonitor.check(state, latest: reading, previous: nil, now: t.addingTimeInterval(600), uptime: Uptime(seconds: 1_000 + 2_400, boot: boot))
        XCTAssertEqual(state.latchedFor, reading.date)
        // A newer reading clears it.
        let newer = PipelineFixtures.reading(.mgdl(118), at: t.addingTimeInterval(900))
        state = ClockMismatchMonitor.check(state, latest: newer, previous: reading, now: t.addingTimeInterval(930), uptime: Uptime(seconds: 1_000 + 2_730, boot: boot))
        XCTAssertNil(state.latchedFor)
        // Across a reboot the uptimes are not compared.
        state = ClockMismatchMonitor.check(state, latest: newer, previous: reading, now: t.addingTimeInterval(5_000), uptime: Uptime(seconds: 50, boot: "boot-2"))
        XCTAssertNil(state.latchedFor)
    }

    private func isFiring(_ phase: AlertPhase) -> Bool {
        if case .firing = phase { return true }
        return false
    }
}
