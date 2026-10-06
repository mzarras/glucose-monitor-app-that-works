import XCTest
import GlucoseCore
@testable import AlertEngine

/// Safety review WS4 B1: the phone clock moving backwards (or forwards) must not hide an urgent
/// low, stretch a snooze, or silence missed readings. Reproduces the reviewer's probes.
@MainActor
final class ClockFaultTests: XCTestCase {
    /// The fixture session shifted by `offset`, as G7Kit would derive it after a clock change (S3).
    private func session(shiftedBy offset: TimeInterval) -> SensorSession {
        let s = Fixtures.session
        return SensorSession(serial: s.serial, start: s.start.addingTimeInterval(offset), warmUpEndsAt: s.warmUpEndsAt.addingTimeInterval(offset),
                             expiresAt: s.expiresAt.addingTimeInterval(offset), gracePeriodEndsAt: s.gracePeriodEndsAt.addingTimeInterval(offset))
    }

    private let twoHours: TimeInterval = 2 * 3600

    func test_S1_futureDatedReadingIsNotCurrentAfterClockRollback() {
        let h = EngineHarness()
        h.mgdl(120)
        h.clock.set(Fixtures.t0.addingTimeInterval(-twoHours))
        XCTAssertNil(h.engine.currentReading(at: h.now), "a reading dated 2 h ahead of the clock is not current")
        h.tick()
        XCTAssertNil(h.engine.snapshot.latestLiveReading, "and it is dropped, so it cannot hide real readings")
        XCTAssertNil(h.engine.snapshot.lastValidReadingDate)
    }

    func test_currentReadingAllowsOnlyTheGatesFutureTolerance() {
        let h = EngineHarness()
        h.mgdl(120)
        XCTAssertNotNil(h.engine.currentReading(at: h.now.addingTimeInterval(-LiveReadingGate.futureTolerance)))
        XCTAssertNil(h.engine.currentReading(at: h.now.addingTimeInterval(-LiveReadingGate.futureTolerance - 1)))
        XCTAssertNotNil(h.engine.currentReading(at: h.now.addingTimeInterval(AlertLimits.currentReadingMaximumAge)))
        XCTAssertNil(h.engine.currentReading(at: h.now.addingTimeInterval(AlertLimits.currentReadingMaximumAge + 1)))
    }

    /// The reviewer's first probe: live 120 at 12:00, clock set back to 10:05, readings of 45.
    func test_S1_urgentLowFiresAfterClockRollback() {
        let h = EngineHarness()
        h.mgdl(120)
        h.clock.set(Fixtures.t0.addingTimeInterval(-twoHours + minutes(5)))
        h.session = session(shiftedBy: -twoHours)
        let low = h.reading(.mgdl(45))
        XCTAssertEqual(low.rejected, [])
        XCTAssertEqual(low.fired, [.urgentLow], "the first real low after the rollback fires")
        XCTAssertEqual(h.engine.currentReading(at: h.now)?.value, .mgdl(45))
    }

    /// The reviewer's third probe: a 30-minute urgent-low snooze must not last 150 minutes.
    func test_S7_clockMovedBackCannotExtendUrgentLowSnooze() {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.snooze(.urgentLow, minutes: 30))
        h.clock.set(Fixtures.t0.addingTimeInterval(-twoHours))
        h.session = session(shiftedBy: -twoHours)
        var elapsed = 0.0
        var fired = false
        while elapsed < 60 && !fired {
            h.clock.advance(minutes: 5)
            elapsed += 5
            fired = h.reading(.mgdl(50)).fired.contains(.urgentLow)
        }
        XCTAssertTrue(fired)
        XCTAssertEqual(elapsed, 5, "the clock fault ends the snooze: the next current low reading fires")
    }

    func test_S7_restoredSnapshotCarriesNoStretchedSnoozeAcrossRelaunch() throws {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.snooze(.urgentLow, minutes: 30))
        let stored = try XCTUnwrap(AlertEngineSnapshot.decode(h.engine.snapshot.encoded()))
        let rolledBack = Fixtures.t0.addingTimeInterval(-twoHours)
        var engine = AlertEngine(settings: .defaults, configuration: Fixtures.configuration, restoring: stored, now: rolledBack)
        XCTAssertEqual(engine.phase(of: .urgentLow), .snoozed(until: rolledBack), "snooze over")
        let reading = Fixtures.reading(.mgdl(50), at: rolledBack, serial: Fixtures.serial)
        let shifted = SensorSession(serial: Fixtures.serial, start: rolledBack.addingTimeInterval(-86_400), warmUpEndsAt: rolledBack.addingTimeInterval(-80_000),
                                    expiresAt: rolledBack.addingTimeInterval(5 * 86_400), gracePeriodEndsAt: rolledBack.addingTimeInterval(6 * 86_400))
        XCTAssertEqual(engine.handle(.reading(reading, session: shifted), at: rolledBack).fired, [.urgentLow])
    }

    func test_nonUrgentSnoozeKeepsItsGrantedLengthAfterRollback() {
        let h = EngineHarness()
        h.mgdl(65)
        h.user(.snooze(.low, minutes: 60))
        let back = Fixtures.t0.addingTimeInterval(-twoHours)
        h.clock.set(back)
        h.tick()
        XCTAssertEqual(h.phase(.low), .snoozed(until: back.addingTimeInterval(minutes(60))))
    }

    func test_S5_missedReadingsSurvivesClockRollback() {
        let h = EngineHarness()
        h.mgdl(120)
        let back = Fixtures.t0.addingTimeInterval(-twoHours)
        h.clock.set(back)
        let repaired = h.tick()
        XCTAssertEqual(h.engine.snapshot.missedReadingsReference, back, "the window restarts from now, not 2 h ahead")
        XCTAssertEqual(repaired.scheduled(.missedReadings)?.first, back.addingTimeInterval(minutes(15)))
        XCTAssertEqual(h.advance(minutes: 15).due, [.missedReadings], "fires 15 minutes later, not 2 h 15 min")
    }

    func test_firingTimersRestartFromNowAfterRollback() {
        let h = EngineHarness()
        h.mgdl(50)
        let back = Fixtures.t0.addingTimeInterval(-twoHours)
        h.clock.set(back)
        h.tick()
        XCTAssertEqual(h.phase(.urgentLow), .firing(since: back))
        XCTAssertEqual(h.advance(minutes: 5).due, [.urgentLow], "repeats 5 minutes after the rollback, not 2 h 5 min")
    }

    func test_highDelayRestartsFromNowAfterRollback() {
        let h = EngineHarness()
        h.settings { $0.high.delayMinutes = 30 }
        h.mgdl(260)
        let back = Fixtures.t0.addingTimeInterval(-twoHours)
        h.clock.set(back)
        h.tick()
        XCTAssertEqual(h.phase(.high), .pending(firesAt: back.addingTimeInterval(minutes(30))))
    }

    // MARK: Clock moved forward

    func test_clockJumpForward_snoozeEndsEarlyAndUrgentLowFiresOnTheNextLow() {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.snooze(.urgentLow, minutes: 30))
        h.clock.advance(minutes: 120)
        h.session = session(shiftedBy: 0)
        XCTAssertEqual(h.mgdl(50).due, [.urgentLow], "the snooze ended (its alarm rang at +30, D44): it sounds on its grid")
    }

    func test_clockJumpForward_staleValueIsNotEvaluatedAndMissedReadingsFires() {
        let h = EngineHarness()
        h.mgdl(65)
        h.user(.acknowledge(.low))
        let jumped = h.advance(minutes: 180)
        XCTAssertNil(h.engine.currentReading(at: h.now))
        XCTAssertEqual(jumped.fired.filter(\.isGlucoseAlert), [], "the 3-hour-old 65 is not re-evaluated")
        XCTAssertEqual(jumped.due, [.missedReadings])
    }

    func test_clockJumpForward_firingUrgentLowRepeatsOnceNotOncePerMissedSlot() {
        let h = EngineHarness()
        h.mgdl(50)
        let jumped = h.advance(minutes: 180)
        XCTAssertEqual(jumped.due.filter { $0 == .urgentLow }.count, 1)
        XCTAssertEqual(jumped.scheduled(.urgentLow)?.first, Fixtures.t0.addingTimeInterval(minutes(185)))
    }
}
