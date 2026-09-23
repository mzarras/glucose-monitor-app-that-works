#if DEBUG
import GlucoseCore
import XCTest
@testable import ReplayKit

/// CGMSource stream rules (GlucoseCore CGMSource.swift): one unbounded stream each, never
/// finished by stop(); a backfill burst arrives complete; stop() then start() keeps delivering.
final class ReplaySourceTests: XCTestCase {
    private let minute: TimeInterval = 60

    /// A day of backfill (288 readings) delivered in one event, then one live reading.
    private func burstTimeline() -> ReplayTimeline {
        let session = G7ReplaySession.session(serial: "REPLAY-BURST", start: testOrigin.addingTimeInterval(-2 * 86_400))
        let factory = ReplayReadingFactory(origin: testOrigin, session: session)
        let backfill = (0..<288).map { index in
            factory.reading(minute: index * 5, .mgdl(100 + index % 50), trend: 0.1, isBackfill: true)
        }
        let live = factory.reading(minute: 1_440, .mgdl(120), trend: 0.0)
        return ReplayTimeline(
            name: "burst", origin: testOrigin, session: session, initialState: .searching,
            events: [
                ReplayEvent(offset: 0, kind: .state(.active(sessionStart: session.start, expiresAt: session.expiresAt))),
                ReplayEvent(offset: 1_440 * minute, kind: .reading(live)),
                ReplayEvent(offset: 1_440 * minute, kind: .backfill(backfill)),
            ]
        )
    }

    func test_backfillBurstOf288ReadingsArrivesComplete() async throws {
        let timeline = burstTimeline()
        let source = ReplaySource(timeline: timeline, clock: ImmediateReplayClock(start: testOrigin))
        try await source.start(pairingCode: nil)
        await source.waitForPlayback() // everything is buffered before anyone reads

        var readings = source.readings.makeAsyncIterator()
        let received = await readings.next(289)
        XCTAssertEqual(received.count, 289)
        XCTAssertEqual(received, timeline.readingsInDeliveryOrder)
        XCTAssertEqual(received.filter(\.isBackfill).count, 288)
    }

    func test_stopThenStartKeepsDeliveringOnTheSameStreams() async throws {
        let clock = ManualReplayClock(start: testOrigin)
        let source = ReplayScenario.steady.makeSource(origin: testOrigin, clock: clock)
        let script = source.timeline.readingsInDeliveryOrder
        var readings = source.readings.makeAsyncIterator()
        var states = source.state.makeAsyncIterator()

        try await source.start(pairingCode: nil)
        let firstStates = await states.next(2)
        XCTAssertEqual(firstStates, [.searching, .warmingUp(endsAt: testOrigin.addingTimeInterval(30 * minute))])

        await clock.advance(to: testOrigin.addingTimeInterval(40 * minute))
        let firstThree = await readings.next(3)
        XCTAssertEqual(firstThree, Array(script[0..<3]), "+30, +35, +40")

        await source.stop()
        await clock.advance(to: testOrigin.addingTimeInterval(60 * minute))
        let whileStopped = await source.emittedReadings
        XCTAssertEqual(whileStopped.count, 3, "nothing is delivered while stopped")

        try await source.start(pairingCode: nil)
        let overdue = await readings.next(4)
        XCTAssertEqual(overdue, Array(script[3..<7]), "+45…+60 delivered on resume, original dates")

        await clock.advance(to: testOrigin.addingTimeInterval(150 * minute))
        let rest = await readings.next(script.count - 7)
        XCTAssertEqual(firstThree + overdue + rest, script)
        let remainingStates = await states.next(1)
        XCTAssertEqual(remainingStates, [.active(sessionStart: testOrigin, expiresAt: source.timeline.session.expiresAt)])
        let log = await source.emittedReadings
        XCTAssertEqual(log, script)
    }

    func test_startWhilePlayingDoesNotDuplicate() async throws {
        let source = ReplayScenario.compressionLowSpike.makeSource(origin: testOrigin, clock: ImmediateReplayClock(start: testOrigin))
        try await source.start(pairingCode: nil)
        try await source.start(pairingCode: "1234")
        await source.waitForPlayback()
        let log = await source.emittedReadings
        XCTAssertEqual(log, source.timeline.readingsInDeliveryOrder)
    }

    func test_currentSessionIsNilUntilStarted() async throws {
        let source = ReplayScenario.steady.makeSource(origin: testOrigin, clock: ManualReplayClock(start: testOrigin))
        let before = await source.currentSession
        XCTAssertNil(before)
        try await source.start(pairingCode: nil)
        let after = await source.currentSession
        XCTAssertEqual(after, source.timeline.session)
        await source.stop()
        let stopped = await source.currentSession
        XCTAssertEqual(stopped, source.timeline.session, "the session stays known after stop")
    }

    func test_stateStreamStartsWithTheCurrentStateBeforeStart() async {
        let source = ReplayScenario.sensorExpiry.makeSource(origin: testOrigin, clock: ManualReplayClock(start: testOrigin))
        var states = source.state.makeAsyncIterator()
        let first = await states.next()
        XCTAssertEqual(first, .searching)
    }

    func test_manualClockWakesSleepersOnlyWhenAdvanced() async throws {
        let clock = ManualReplayClock(start: testOrigin)
        let task = Task { try await clock.sleep(until: testOrigin.addingTimeInterval(10)) }
        await clock.advance(by: 5)
        let now = await clock.now()
        XCTAssertEqual(now, testOrigin.addingTimeInterval(5))
        await clock.advance(by: 5)
        try await task.value
    }

    func test_manualClockSleepThrowsWhenCancelled() async {
        let clock = ManualReplayClock(start: testOrigin)
        let task = Task { try await clock.sleep(until: testOrigin.addingTimeInterval(3_600)) }
        task.cancel()
        do {
            try await task.value
            XCTFail("expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func test_scaledClockArithmetic() {
        XCTAssertEqual(
            ScaledReplayClock.scenarioDate(start: testOrigin, speed: 60, wallElapsed: .seconds(5)),
            testOrigin.addingTimeInterval(300), "5 real seconds at 60× = 5 scenario minutes"
        )
        XCTAssertEqual(ScaledReplayClock.wallDelay(until: testOrigin.addingTimeInterval(300), from: testOrigin, speed: 60), 5)
        XCTAssertEqual(ScaledReplayClock.wallDelay(until: testOrigin, from: testOrigin.addingTimeInterval(1), speed: 1), 0)
        let realTime = ScaledReplayClock(start: testOrigin, speed: 1)
        XCTAssertGreaterThanOrEqual(realTime.now(), testOrigin)
    }
}
#endif
