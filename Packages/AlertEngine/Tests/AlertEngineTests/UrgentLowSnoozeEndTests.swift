import XCTest
import GlucoseCore
@testable import AlertEngine

/// D44 (Michael): an acknowledged or snoozed urgent low re-alarms at snooze end even without a new
/// reading — one alarm, on the loudest available path, never silenced by quiet hours, its text
/// never presenting the last value as current (S1); then it repeats as when firing.
@MainActor
final class UrgentLowSnoozeEndTests: XCTestCase {
    private func utc(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// 02:00 UTC on 2026-09-24: inside the fixture session, inside quiet hours 22:00–07:00.
    private var twoAM: Date { utc("2026-09-24T02:00:00Z") }
    private var snoozeEnd: Date { twoAM.addingTimeInterval(minutes(30)) }

    private func nightSettings(_ change: (inout AlertSettings) -> Void = { _ in }) -> AlertSettings {
        var s = AlertSettings.defaults
        s.quietHours = QuietHours(isEnabled: true, startMinuteOfDay: 22 * 60, endMinuteOfDay: 7 * 60)
        change(&s)
        return s
    }

    /// Urgent low at 02:00, acknowledged at once; nothing after that (out of range from 02:05).
    private func acknowledgedAt2AM(_ s: ServiceHarness) async {
        s.clock.set(twoAM)
        await s.service.start()
        await s.reading(.mgdl(50))
        await s.service.send(.user(.acknowledge(.urgentLow)))
    }

    private func urgentLowPending(_ s: ServiceHarness) -> [NotificationRequestSpec] {
        s.center.pending(for: .urgentLow).filter { ($0.fireDate ?? .distantPast) > s.clock.now }
    }

    // MARK: The audit scenario

    func test_S7_acknowledgedUrgentLowReAlarmsAtSnoozeEndWithoutANewReading_systemAlarm() async throws {
        let alarms = FakeSystemAlarms()
        let s = ServiceHarness(settings: nightSettings(), alarms: alarms)
        await acknowledgedAt2AM(s)
        XCTAssertEqual(s.service.phase(of: .urgentLow), .snoozed(until: snoozeEnd))

        let alarm = try XCTUnwrap(alarms.alarm(firingAt: snoozeEnd), "an AlarmKit alarm at the snooze end: it rings while the app is suspended")
        XCTAssertEqual(alarm.soundFileName, "alert-cascade.caf")
        XCTAssertEqual(alarm.title, "Urgent low", "no value in an alarm title (D34)")
        let notice = try XCTUnwrap(urgentLowPending(s).first)
        XCTAssertEqual(notice.fireDate, snoozeEnd)
        XCTAssertEqual(notice.body, "Snooze ended. Last reading 50 mg/dL at 2:00 AM. Check your glucose.", "never presented as current (S1)")
        XCTAssertEqual(notice.interruption, .timeSensitive, "quiet hours never silence it")
        XCTAssertEqual(notice.sound, .named(fileName: "alert-cascade.wav"))
        XCTAssertTrue(s.center.pending(for: .missedReadings).allSatisfy { $0.interruption == .passive },
                      "the audit's point: quiet hours silence missed readings, so this alarm is the only sound")
        XCTAssertEqual(urgentLowPending(s).compactMap(\.fireDate), (0..<12).map { snoozeEnd.addingTimeInterval(Double($0) * minutes(5)) },
                       "then the repeat grid, as when firing, also while the app stays suspended")
        XCTAssertEqual(alarms.repeatAlarms.count, 12)
    }

    func test_S7_acknowledgedUrgentLowReAlarmsAtSnoozeEndWithoutANewReading_appAwake() async {
        let s = ServiceHarness(settings: nightSettings())
        await acknowledgedAt2AM(s)
        s.audio.finish()
        let posted = s.center.posted.count
        s.clock.set(snoozeEnd.addingTimeInterval(30))   // a wake (a tick) 30 s after the snooze end
        await s.service.send(.tick)
        XCTAssertEqual(s.audio.plays.map(\.fileName), ["alert-cascade.wav", "alert-cascade.wav"], "in-app sound at the snooze end: ringer off too")
        XCTAssertEqual(s.center.posted.count, posted, "the pending notification is this sounding: nothing posted twice")
        XCTAssertEqual(s.service.phase(of: .urgentLow), .firing(since: snoozeEnd))

        s.audio.finish()
        await s.advance(minutes: 5)
        XCTAssertEqual(s.audio.plays.count, 3, "repeats on its grid while unacknowledged")
        await s.reading(.mgdl(120))
        XCTAssertEqual(s.service.phase(of: .urgentLow), .armed, "a clearing reading ends it")
        XCTAssertEqual(urgentLowPending(s), [])
    }

    // MARK: Readings during the snooze

    func test_S7_aClearingReadingDuringTheSnoozeCancelsTheSnoozeEndAlarm() {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.acknowledge(.urgentLow))
        h.clock.advance(minutes: 10)
        XCTAssertEqual(h.mgdl(90).cancelled, [.urgentLow], "recovered past the margin: the episode ends")
        XCTAssertEqual(h.pendingDates(.urgentLow), [])
        XCTAssertEqual(h.phase(.urgentLow), .armed)
        h.clock.set(Fixtures.t0.addingTimeInterval(minutes(31)))
        let atTheEnd = h.tick()
        XCTAssertFalse((atTheEnd.due + atTheEnd.fired).contains(.urgentLow), "nothing at the old snooze end")
    }

    func test_S7_aReadingAboveTheThresholdBeforeSnoozeEndRemovesTheAlarm() {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.acknowledge(.urgentLow))
        let end = Fixtures.t0.addingTimeInterval(minutes(30))
        XCTAssertEqual(h.pendingDates(.urgentLow).first, end)

        h.clock.advance(minutes: 10)
        let above = h.mgdl(58)   // above 55, inside the recovery band: the episode stays snoozed
        XCTAssertTrue(above.contains { if case .cancelSlots(.urgentLow, _) = $0 { return true } else { return false } })
        XCTAssertEqual(h.pendingDates(.urgentLow), [], "removed")
        XCTAssertEqual(h.phase(.urgentLow), .snoozed(until: end))

        h.clock.advance(minutes: 5)
        XCTAssertEqual(h.mgdl(54).scheduled(.urgentLow)?.first, end, "low again before the end: back")
        h.clock.advance(minutes: 1)
        h.mgdl(56)
        XCTAssertEqual(h.pendingDates(.urgentLow), [], "any reading above the threshold removes it")
        h.clock.set(end.addingTimeInterval(30))
        XCTAssertEqual(h.tick().due + h.engine.handle(.tick, at: h.now).fired, [], "nothing at the snooze end")
        XCTAssertEqual(h.phase(.urgentLow), .armed, "the snooze is over and the latest reading is in the band: re-armed (D51)")
        XCTAssertEqual(h.mgdl(52).fired, [.urgentLow], "a current low after the end fires at once")
    }

    // MARK: D51 — the recovery band at snooze end hands over to Low

    /// The review's probe P2: 50 acknowledged at 12:00, then 58 every 5 minutes for 90 minutes.
    func test_S5_aBandReadingAtSnoozeEndHandsOverToLow() {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.acknowledge(.urgentLow))
        var sounded: [(Double, AlertKind)] = []
        for step in 1...18 {
            h.clock.advance(minutes: 5)
            let actions = h.mgdl(58)
            sounded += (actions.fired + actions.due).map { (Double(step * 5), $0) }
        }
        XCTAssertEqual(sounded.first?.0, 30, "nothing before the snooze end")
        XCTAssertEqual(sounded.first?.1, .low, "at the end: Low, no longer superseded, fires on the 58")
        XCTAssertFalse(sounded.contains { $0.1 == .urgentLow }, "58 is above the urgent-low threshold")
        XCTAssertEqual(h.phase(.urgentLow), .armed)
        XCTAssertEqual(h.phase(.low), .firing(since: Fixtures.t0.addingTimeInterval(minutes(30))))
    }

    func test_S7_aLowReadingAtSnoozeEndIsTheUrgentLowAlarmWithoutLowOnTop() {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.acknowledge(.urgentLow))
        h.clock.advance(minutes: 30)
        let end = h.mgdl(54)
        XCTAssertEqual(end.due, [.urgentLow], "the snooze-end alarm")
        XCTAssertEqual(end.fired, [], "no Low on top: urgent low is firing, Low stays superseded")
        XCTAssertEqual(h.phase(.low), .armed)
    }

    func test_S7_withLowOffBandReadingsAreSilentAndUrgentLowIsReArmed() {
        var settings = AlertSettings.defaults
        settings.low.isEnabled = false
        let h = EngineHarness(settings: settings)
        h.mgdl(50)
        h.user(.acknowledge(.urgentLow))
        h.clock.advance(minutes: 30)
        let end = h.mgdl(58)
        XCTAssertEqual(end.fired + end.due, [], "Low off: silence, as configured")
        XCTAssertEqual(h.phase(.urgentLow), .armed, "re-armed, not snoozed")
        h.clock.advance(minutes: 5)
        XCTAssertEqual(h.mgdl(55).fired, [.urgentLow], "≤ 55 fires at once")
    }

    func test_S5_atTheHandOverQuietHoursSilenceLowButNeverUrgentLow() {
        var settings = AlertSettings.defaults
        settings.quietHours = QuietHours(isEnabled: true, startMinuteOfDay: 22 * 60, endMinuteOfDay: 7 * 60)
        let h = EngineHarness(settings: settings)
        h.clock.set(twoAM)
        h.mgdl(50)
        h.user(.acknowledge(.urgentLow))
        h.clock.advance(minutes: 30)
        let end = h.mgdl(58)
        XCTAssertEqual(end.firedNotice(.low)?.isSilenced, true, "Low is silenced in quiet hours, as configured")
        h.clock.advance(minutes: 5)
        XCTAssertEqual(h.mgdl(54).firedNotice(.urgentLow)?.isSilenced, false, "urgent low never is")
    }

    // MARK: Exactly one alarm at the edges (review m2)

    /// Probe P8: 58 at end − 5:30 removes the alarm; 54 at end − 0:30 must put it back even inside
    /// the protected minute; 53 at end + 4:00 must not fire afresh while the end + 5 entry rings.
    func test_S7_aLowReadingInTheLastMinutePutsTheSnoozeEndAlarmBack() {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.acknowledge(.urgentLow))
        let end = Fixtures.t0.addingTimeInterval(minutes(30))
        h.clock.advance(minutes: 24.5)
        h.mgdl(58)
        XCTAssertEqual(h.pendingDates(.urgentLow), [], "removed")
        h.clock.advance(seconds: minutes(5))   // end − 0:30
        XCTAssertEqual(h.mgdl(54).scheduled(.urgentLow), [end], "the snooze-end alarm is back (the grid after it was planned first)")
        XCTAssertEqual(h.pendingDates(.urgentLow).first, end)
        h.clock.advance(seconds: minutes(4) + 30)   // end + 4:00, still low
        let later = h.mgdl(53)
        XCTAssertEqual(later.fired, [], "not a fresh alarm")
        XCTAssertEqual(later.due, [.urgentLow], "the end + 5 entry, about to ring, is this sounding")
        XCTAssertEqual(h.phase(.urgentLow), .firing(since: end))
    }

    /// Probe P4: the clock set back in the snooze's last minute. The snooze-end alarm, due by real
    /// time, is kept and re-dated 30 s ahead; it is the sounding — not a fresh fire on top.
    func test_S7_aRollbackInTheLastMinuteTakesTheReDatedAlarmAsTheSounding() {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.acknowledge(.urgentLow))
        h.clock.advance(seconds: minutes(30) - 30)
        h.clock.advance(minutes: -20)
        let actions = h.tick()
        XCTAssertEqual(actions.fired, [], "no fresh alarm")
        XCTAssertEqual(actions.due, [.urgentLow])
        let reDated = h.now.addingTimeInterval(30)
        XCTAssertEqual(h.phase(.urgentLow), .firing(since: reDated))
        XCTAssertEqual(h.pendingDates(.urgentLow).prefix(2), [reDated, reDated.addingTimeInterval(minutes(5))], "its grid follows")
    }

    func test_S7_aLowReadingAtSnoozeEndGivesExactlyOneAlarm() async throws {
        let alarms = FakeSystemAlarms()
        let s = ServiceHarness(alarms: alarms)
        await s.service.start()
        await s.reading(.mgdl(50))
        await s.service.send(.user(.acknowledge(.urgentLow)))
        s.center.strictClock = s.clock   // from here, removing a due notification or alarm fails the test
        alarms.strictClock = s.clock
        let end = Fixtures.t0.addingTimeInterval(minutes(30))
        let posted = s.center.posted.count
        let scheduleCalls = alarms.scheduleCalls

        s.clock.advance(seconds: minutes(30) + 10)   // the G7 wakes 10 s after the snooze end, still low
        await s.reading(.mgdl(49))
        XCTAssertEqual(s.center.posted.count, posted, "no second notification")
        XCTAssertNil(alarms.scheduled[SystemAlarmIDs.immediate], "no second (immediate) alarm")
        XCTAssertNotNil(alarms.alarm(firingAt: end), "the snooze-end alarm is the one that rang, untouched")
        XCTAssertEqual(alarms.scheduleCalls, scheduleCalls + 1, "only the grid's tail was added")
        XCTAssertTrue(s.audio.plays.isEmpty, "its alarm rang: no in-app sound on top")
        XCTAssertEqual(s.service.phase(of: .urgentLow), .firing(since: end))
    }

    func test_aLowReadingAtSnoozeEndWithoutAlarmsPlaysOnceInTheApp() {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.acknowledge(.urgentLow))
        h.clock.advance(seconds: minutes(30) + 10)
        let end = h.mgdl(49)
        XCTAssertEqual(end.fired, [])
        XCTAssertEqual(end.due, [.urgentLow])
        XCTAssertNil(end.firstIndex { if case .cancelSlots(.urgentLow, _) = $0 { return true } else { return false } })
    }

    // MARK: S7 under faults

    func test_S7_aClockMovedBackDuringTheSnoozeEndsItAndReAlarmsAtOnce() {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.acknowledge(.urgentLow))
        h.clock.advance(minutes: 10)
        h.clock.advance(minutes: -20)   // set back 20 minutes
        let actions = h.tick()
        XCTAssertEqual(actions.fired, [.urgentLow], "the snooze ends at once (S7) and urgent low re-alarms (D44)")
        XCTAssertEqual(actions.firedNotice(.urgentLow)?.body, "Snooze ended. No recent reading. Check your glucose.",
                       "the 12:00 PM reading now lies in the future and is dropped; nothing is presented as current")
        XCTAssertTrue(actions.contains { if case .cancelSlots(.urgentLow, _) = $0 { return true } else { return false } },
                      "the snooze-end alarm planned on the old clock is removed")
        XCTAssertEqual(h.pendingDates(.urgentLow).first, h.now.addingTimeInterval(minutes(5)), "repeats from now")
    }

    func test_S7_aKillAndRelaunchDuringTheSnoozeStillReAlarms() async throws {
        let alarms = FakeSystemAlarms()
        let first = ServiceHarness(alarms: alarms)
        await first.service.start()
        await first.reading(.mgdl(50))
        await first.service.send(.user(.acknowledge(.urgentLow)))
        let snapshot = try XCTUnwrap(first.snapshots.last)
        let end = Fixtures.t0.addingTimeInterval(minutes(30))

        first.clock.advance(minutes: 10)   // killed; relaunched by iOS
        let relaunched = ServiceHarness(snapshot: snapshot, alarms: alarms, center: first.center, clock: first.clock)
        await relaunched.service.start()
        XCTAssertEqual(relaunched.service.phase(of: .urgentLow), .snoozed(until: end), "restored")
        XCTAssertNotNil(alarms.alarm(firingAt: end), "the snooze-end alarm is pending again after the launch reconcile")
        XCTAssertEqual(relaunched.center.pending(for: .urgentLow).compactMap(\.fireDate).filter { $0 > relaunched.clock.now }.min(), end)

        relaunched.clock.advance(seconds: minutes(20) + 30)
        await relaunched.service.send(.tick)
        XCTAssertEqual(relaunched.service.phase(of: .urgentLow), .firing(since: end), "and it fires at the snooze end")
    }

    func test_S7_aRelaunchJustBeforeTheSnoozeEndNeverTouchesItsAlarm() async throws {
        let alarms = FakeSystemAlarms()
        let first = ServiceHarness(alarms: alarms)
        await first.service.start()
        await first.reading(.mgdl(50))
        await first.service.send(.user(.acknowledge(.urgentLow)))
        let snapshot = try XCTUnwrap(first.snapshots.last)
        let end = Fixtures.t0.addingTimeInterval(minutes(30))

        first.clock.advance(seconds: minutes(30) - 30)   // killed; relaunched 30 s before the snooze end
        first.center.strictClock = first.clock           // removing the due alarm or notification fails the test
        alarms.strictClock = first.clock
        let relaunched = ServiceHarness(snapshot: snapshot, alarms: alarms, center: first.center, clock: first.clock)
        await relaunched.service.start()
        XCTAssertNotNil(alarms.alarm(firingAt: end), "due in 30 s: left alone")
    }

    func test_S7_alarmKitRevokedDuringTheSnoozeFallsBackAtSnoozeEnd() async {
        let alarms = FakeSystemAlarms()
        let s = ServiceHarness(alarms: alarms)
        await s.service.start()
        await s.reading(.mgdl(50))
        await s.service.send(.user(.acknowledge(.urgentLow)))
        let end = Fixtures.t0.addingTimeInterval(minutes(30))
        XCTAssertNotNil(alarms.alarm(firingAt: end))

        alarms.authorization = .denied
        await s.advance(minutes: 10)
        XCTAssertNil(alarms.alarm(firingAt: end), "the snooze-end alarm no longer relies on AlarmKit")
        let pending = urgentLowPending(s)
        XCTAssertEqual(pending.first?.fireDate, end)
        XCTAssertEqual(pending.first?.interruption, .timeSensitive)
        XCTAssertEqual(pending.first?.sound, .named(fileName: "alert-cascade.wav"))

        s.clock.advance(seconds: minutes(20) + 30)
        await s.service.send(.tick)
        XCTAssertEqual(s.audio.plays.map(\.fileName), ["alert-cascade.wav"], "awake at the snooze end: the in-app sound, the next loudest path")
        XCTAssertEqual(s.service.phase(of: .urgentLow), .firing(since: end))
    }

    func test_S7_theSnoozeIsStillAtMost30MinutesAndTheGridStaysWithinTheBudget() {
        var settings = AlertSettings.defaults
        settings.urgentLow.repeatMinutes = 2
        let h = EngineHarness(settings: settings)
        h.mgdl(50)
        h.user(.snooze(.urgentLow, minutes: 600))
        XCTAssertEqual(h.phase(.urgentLow), .snoozed(until: Fixtures.t0.addingTimeInterval(minutes(30))))
        XCTAssertEqual(h.pendingDates(.urgentLow).count, AlertLimits.maximumScheduledSlots, "30 at the 2-minute floor, as when firing")
        XCTAssertLessThanOrEqual(AlertLimits.worstCasePendingNotifications, 64)
    }

    func test_reAcknowledgingAfterTheSnoozeEndAlarmSnoozesAgain() {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.acknowledge(.urgentLow))
        h.clock.advance(seconds: minutes(30) + 30)
        h.tick()
        XCTAssertEqual(h.phase(.urgentLow), .firing(since: Fixtures.t0.addingTimeInterval(minutes(30))))
        let again = h.user(.acknowledge(.urgentLow))   // e.g. Stop on the alarm
        XCTAssertEqual(again.first, .cancel(.urgentLow))
        XCTAssertEqual(h.phase(.urgentLow), .snoozed(until: h.now.addingTimeInterval(minutes(30))))
        XCTAssertEqual(again.scheduled(.urgentLow)?.first, h.now.addingTimeInterval(minutes(30)), "the next snooze end has its alarm")
    }
}
