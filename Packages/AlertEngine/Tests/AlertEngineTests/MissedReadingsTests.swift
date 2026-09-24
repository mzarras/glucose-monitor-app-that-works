import XCTest
import GlucoseCore
@testable import AlertEngine

/// Missed readings (S5): pre-scheduled from every valid reading, due at reading + window.
@MainActor
final class MissedReadingsTests: XCTestCase {
    private func slots(from start: Date, every m: Double) -> [Date] {
        (0..<12).map { start.addingTimeInterval(Double($0) * minutes(m)) }
    }

    func test_everyValidReadingReschedulesFromTheReadingsOwnTime() {
        let h = EngineHarness()
        XCTAssertEqual(h.mgdl(120).scheduled(.missedReadings), slots(from: h.now.addingTimeInterval(minutes(15)), every: 15))
        h.clock.advance(minutes: 5)
        XCTAssertEqual(h.mgdl(118).scheduled(.missedReadings), slots(from: h.now.addingTimeInterval(minutes(15)), every: 15))
        h.clock.advance(minutes: 5)
        let late = h.reading(.mgdl(117), secondsAgo: 120)
        XCTAssertEqual(late.scheduled(.missedReadings)?.first, h.now.addingTimeInterval(minutes(13)), "measured 2 minutes ago: due in 13")
    }

    func test_S5_missedReadingsAfter15MinutesWithoutAValidReading() {
        let h = EngineHarness()
        h.mgdl(120)
        XCTAssertEqual(h.advance(minutes: 14).due, [])
        XCTAssertEqual(h.phase(.missedReadings), .armed)
        let due = h.advance(minutes: 1)
        XCTAssertEqual(due.due, [.missedReadings], "the notification was pending; the awake app adds the sound")
        XCTAssertEqual(due.dueNotice(.missedReadings)?.body, "No valid reading since 12:00 PM.")
        XCTAssertEqual(h.phase(.missedReadings), .firing(since: Fixtures.t0.addingTimeInterval(minutes(15))))
    }

    func test_S5_missedReadingsFiresEvenIfNoReadingEverArrived() {
        let h = EngineHarness()
        XCTAssertEqual(h.tick().scheduled(.missedReadings), slots(from: Fixtures.t0.addingTimeInterval(minutes(15)), every: 15))
        let due = h.advance(minutes: 15)
        XCTAssertEqual(due.due, [.missedReadings])
        XCTAssertEqual(due.dueNotice(.missedReadings)?.body, "No valid reading in the last 15 min.")
    }

    func test_postsImmediatelyIfItsNotificationWasNeverScheduled() {
        // e.g. restored from a snapshot that predates scheduling.
        let snapshot = AlertEngineSnapshot(start: Fixtures.t0)   // no pending series recorded
        var engine = AlertEngine(settings: .defaults, configuration: Fixtures.configuration, restoring: snapshot, now: Fixtures.t0)
        let actions = engine.handle(.tick, at: Fixtures.t0.addingTimeInterval(minutes(20)))
        XCTAssertEqual(actions.fired, [.missedReadings])
    }

    func test_repeatsEveryWindowWhileNoReadingArrives() {
        let h = EngineHarness()
        h.mgdl(120)
        h.advance(minutes: 15)
        XCTAssertEqual(h.advance(minutes: 10).due, [])
        let second = h.advance(minutes: 5)
        XCTAssertEqual(second.due, [.missedReadings])
        XCTAssertEqual(h.pendingDates(.missedReadings).first, Fixtures.t0.addingTimeInterval(minutes(45)))
        XCTAssertEqual(h.pendingDates(.missedReadings).count, 12)
        XCTAssertEqual(h.advance(minutes: 1).ignoringMissedReadings.due, [])
    }

    func test_aReadingClearsMissedReadingsAndReschedules() {
        let h = EngineHarness()
        h.mgdl(120)
        h.advance(minutes: 20)
        let back = h.mgdl(118)
        XCTAssertEqual(back.cancelled, [.missedReadings], "removes the delivered and pending notifications")
        XCTAssertEqual(back.scheduled(.missedReadings)?.first, h.now.addingTimeInterval(minutes(15)))
        XCTAssertEqual(h.phase(.missedReadings), .armed)
    }

    func test_aBackfilledReadingAlsoClearsMissedReadings() {
        let h = EngineHarness()
        h.mgdl(120)
        h.advance(minutes: 20)
        let backfill = h.reading(.mgdl(50), secondsAgo: 120, backfill: true)
        XCTAssertEqual(backfill.cancelled, [.missedReadings])
        XCTAssertEqual(backfill.fired, [], "…but never fires a glucose alert (S1)")
    }

    func test_S6_importedReadingDoesNotResetMissedReadings() {
        let h = EngineHarness()
        h.mgdl(120)
        h.advance(minutes: 20)
        XCTAssertEqual(h.reading(.mgdl(120), source: .imported(.nightscout)).rejected, [.notLiveSensor(.imported(.nightscout))])
        XCTAssertEqual(h.phase(.missedReadings), .firing(since: Fixtures.t0.addingTimeInterval(minutes(15))))
    }

    func test_warmUpSuppressesMissedReadingsAndRestartsTheWindowAfterwards() {
        let h = EngineHarness()
        h.tick()
        let warm = h.send(.sensorState(.warmingUp(endsAt: h.now.addingTimeInterval(minutes(30)))))
        XCTAssertEqual(warm.cancelled, [.missedReadings], "pending notifications removed")
        XCTAssertEqual(h.advance(minutes: 30).due, [])
        XCTAssertEqual(h.phase(.missedReadings), .armed)
        let active = h.send(.sensorState(.active(sessionStart: Fixtures.t0, expiresAt: Fixtures.t0.addingTimeInterval(10 * 86_400))))
        XCTAssertEqual(active.scheduled(.missedReadings)?.first, h.now.addingTimeInterval(minutes(15)), "window starts at warm-up end")
        XCTAssertEqual(h.advance(minutes: 15).due, [.missedReadings])
    }

    func test_noSensorPairedMeansNothingToMiss() {
        let h = EngineHarness()
        h.send(.sensorState(.notPaired))
        XCTAssertEqual(h.advance(minutes: 60).due, [])
        XCTAssertNil(h.tick().scheduled(.missedReadings))
    }

    func test_transientStatesDoNotChangeSuppression() {
        let h = EngineHarness()
        h.send(.sensorState(.warmingUp(endsAt: h.now.addingTimeInterval(minutes(30)))))
        h.send(.sensorState(.searching))
        h.send(.sensorState(.bluetoothUnavailable(.poweredOff)))
        XCTAssertEqual(h.advance(minutes: 20).due, [], "still warming up as far as missed readings are concerned")
    }

    func test_acknowledgeSnoozesThenRefiresIfStillNoReading() {
        let h = EngineHarness()
        h.mgdl(120)
        h.advance(minutes: 15)
        let ack = h.user(.acknowledge(.missedReadings))
        XCTAssertEqual(ack.first, .cancel(.missedReadings))
        XCTAssertEqual(ack.scheduled(.missedReadings)?.first, h.now.addingTimeInterval(minutes(30)), "pending again for when the snooze ends")
        XCTAssertEqual(h.phase(.missedReadings), .snoozed(until: h.now.addingTimeInterval(minutes(30))))
        XCTAssertEqual(h.advance(minutes: 29).due, [])
        XCTAssertEqual(h.advance(minutes: 1).due, [.missedReadings])
    }

    func test_readingDuringSnoozeEndsTheEpisode() {
        let h = EngineHarness()
        h.mgdl(120)
        h.advance(minutes: 15)
        h.user(.snooze(.missedReadings, minutes: 60))
        h.clock.advance(minutes: 5)
        XCTAssertEqual(h.mgdl(120).cancelled, [.missedReadings])
        XCTAssertEqual(h.phase(.missedReadings), .armed)
    }

    func test_turningMissedReadingsOffRemovesItsNotifications() {
        let h = EngineHarness()
        h.mgdl(120)
        let off = h.settings { $0.missedReadings.isEnabled = false }
        XCTAssertEqual(off, [.cancelSlots(.missedReadings, Array(0..<12))])
        XCTAssertEqual(h.advance(minutes: 30).due, [])
        XCTAssertEqual(h.phase(.missedReadings), .off)
        h.mgdl(120)
        h.advance(minutes: 1)
        let firingOff = EngineHarness()
        firingOff.mgdl(120)
        firingOff.advance(minutes: 20)
        XCTAssertTrue(firingOff.settings { $0.missedReadings.isEnabled = false }.cancelled.contains(.missedReadings))
    }

    func test_changingTheWindowReschedules() {
        let h = EngineHarness()
        h.mgdl(120)
        let change = h.settings { $0.missedReadings.windowMinutes = 30 }
        XCTAssertEqual(change.first, .cancelSlots(.missedReadings, Array(0..<12)))
        XCTAssertEqual(change.scheduled(.missedReadings), slots(from: Fixtures.t0.addingTimeInterval(minutes(30)), every: 30))
    }

    func test_changingSettingsWhileFiringKeepsRepeatsPending() {
        let h = EngineHarness()
        h.mgdl(120)
        h.advance(minutes: 16)
        let change = h.settings { $0.missedReadings.sound = .warble }
        XCTAssertEqual(change.scheduled(.missedReadings)?.first, Fixtures.t0.addingTimeInterval(minutes(30)))
        XCTAssertEqual(change.scheduledNotices(.missedReadings)?.first?.sound, .warble)
    }

    func test_quietHoursAreDecidedForEachPendingNotificationsOwnTime() {
        let h = EngineHarness()
        // Quiet 12:30–13:00 UTC; a reading at 12:01 → pending at 12:16, 12:31, 12:46, 13:01, …
        h.settings { $0.quietHours = QuietHours(isEnabled: true, startMinuteOfDay: 12 * 60 + 30, endMinuteOfDay: 13 * 60) }
        h.clock.advance(minutes: 1)
        let silenced = h.mgdl(120).scheduledNotices(.missedReadings)?.prefix(4).map(\.isSilenced)
        XCTAssertEqual(silenced, [false, true, true, false])
    }
}
