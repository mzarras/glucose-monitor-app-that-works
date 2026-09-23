import XCTest
import GlucoseCore
@testable import AlertEngine

/// Safety review WS4 delta: a wake-up near a repeat must never cancel, stop or replace the repeat
/// that is due or ringing. The fakes here are strict: removing a notification or alarm due within
/// 60 s (or already due) fails the test on the spot.
@MainActor
final class DueRepeatProtectionTests: XCTestCase {
    private func strictHarness(clock: TestClock = TestClock()) -> (ServiceHarness, FakeSystemAlarms, FakeNotificationCenter) {
        let alarms = FakeSystemAlarms()
        alarms.strictClock = clock
        let center = FakeNotificationCenter()
        center.strictClock = clock
        return (ServiceHarness(alarms: alarms, center: center, clock: clock), alarms, center)
    }

    private func slot(_ k: Int) -> Date { Fixtures.t0.addingTimeInterval(Double(k) * minutes(5)) }

    func test_S7_wakeNearARepeatNeverCancelsTheDueAlarm() async throws {
        for offset in [-30.0, -1, 3] {
            let clock = TestClock()
            let (h, alarms, center) = strictHarness(clock: clock)
            await h.service.start()
            await h.reading(.mgdl(50))
            for k in 1...3 {
                clock.set(slot(k).addingTimeInterval(offset))
                await h.reading(.mgdl(49))
                XCTAssertNotNil(alarms.alarm(firingAt: slot(k)), "wake \(offset) s from repeat \(k): its alarm is still there")
                XCTAssertTrue(center.pending(for: .urgentLow).contains { $0.fireDate == slot(k) }, "…and its notification")
                XCTAssertNotNil(alarms.alarm(firingAt: slot(k + 12)), "the tail still reaches 60 minutes ahead")
            }
            XCTAssertTrue(h.audio.plays.isEmpty, "every repeat has its alarm, so no in-app sound is needed")

            // The process is killed and relaunched 20 s before repeat 4 (the system keeps its alarms
            // and notifications); the launch reconcile must not touch that repeat either.
            let snapshot = try XCTUnwrap(h.snapshots.last)
            clock.set(slot(4).addingTimeInterval(-20))
            let relaunched = ServiceHarness(snapshot: snapshot, alarms: alarms, center: center, clock: clock)
            await relaunched.service.start()
            XCTAssertNotNil(alarms.alarm(firingAt: slot(4)), "launch while firing keeps the due alarm (offset \(offset))")
            XCTAssertTrue(center.pending(for: .urgentLow).contains { $0.fireDate == slot(4) })
            XCTAssertNotNil(alarms.alarm(firingAt: slot(15)), "and rebuilds the rest")
        }
    }

    func test_S7_ringingRepeatIsNeverStoppedByReschedule() async {
        let clock = TestClock()
        let (h, alarms, _) = strictHarness(clock: clock)
        await h.service.start()
        await h.reading(.mgdl(50))

        // Repeat 1 is ringing (3 s in) while each kind of reschedule happens.
        clock.set(slot(1).addingTimeInterval(3))
        await h.reading(.mgdl(49))                                    // roll-forward
        var settings = h.service.settings
        settings.urgentLow.sound = .tide                               // content change: future repeats rebuilt
        await h.service.send(.settings(settings))
        settings.urgentLow.repeatMinutes = 3                           // grid change: future repeats replaced
        await h.service.send(.settings(settings))
        h.center.permissions.criticalAlerts = .enabled                 // delivery level change: rebuild
        _ = await h.service.refreshDeliveryStatus()
        h.center.permissions.criticalAlerts = .notSupported
        _ = await h.service.refreshDeliveryStatus()
        XCTAssertNotNil(alarms.alarm(firingAt: slot(1)), "the ringing alarm was never stopped")
        XCTAssertEqual(alarms.repeatAlarms.last.map { $0.soundFileName }, "alert-tide.caf", "the future ones carry the new sound")
    }

    func test_S7_dueRepeatWhoseAlarmVanishedPlaysTheInAppSound() async throws {
        let clock = TestClock()
        let (h, alarms, _) = strictHarness(clock: clock)
        await h.reading(.mgdl(50))
        let due = try XCTUnwrap(alarms.alarm(firingAt: slot(1)))
        alarms.lose(due.id)
        clock.set(slot(1).addingTimeInterval(-10))
        await h.reading(.mgdl(49))
        XCTAssertEqual(h.audio.plays.map(\.fileName), ["alert-cascade.wav"], "belt and braces: no alarm to ring, so the app plays it")
        XCTAssertTrue(h.log.messages.contains { $0.contains("its alarm is missing") })
    }

    func test_dueRepeatAlarmUnknownToTheSystemPlaysTheInAppSound() async {
        let clock = TestClock()
        let (h, alarms, _) = strictHarness(clock: clock)
        await h.reading(.mgdl(50))
        alarms.listingFails = true   // the system cannot say which alarms exist
        clock.set(slot(1))
        await h.reading(.mgdl(49))
        XCTAssertEqual(h.audio.plays.count, 1)
    }

    func test_wakeJustBeforeAMissedReadingsRepeatKeepsItsNotification() async {
        let clock = TestClock()
        let (h, _, center) = strictHarness(clock: clock)
        await h.service.start()
        await h.reading(.mgdl(120))
        let due = Fixtures.t0.addingTimeInterval(minutes(30))   // second missed-readings notification
        clock.set(Fixtures.t0.addingTimeInterval(minutes(15)))
        await h.service.send(.tick)                              // missed readings starts firing
        clock.set(due.addingTimeInterval(-30))
        await h.service.send(.tick)                              // its next repeat is 30 s away
        XCTAssertTrue(center.pending(for: .missedReadings).contains { $0.fireDate == due })
        XCTAssertTrue(center.pending(for: .missedReadings).contains { $0.fireDate == Fixtures.t0.addingTimeInterval(minutes(195)) },
                      "the tail was extended")
    }

    // MARK: Cancelling every alarm when the system cannot list them (S5)

    func test_S5_cancelAllStillCancelsKnownAlarmsWhenTheListCannotBeRead() async {
        let alarms = FakeSystemAlarms()
        let h = ServiceHarness(alarms: alarms)
        let legacy = SystemAlarmRequest(id: UUID(), fireDate: Fixtures.t0.addingTimeInterval(3600), title: "old", soundFileName: "x.caf")
        alarms.plant(legacy)
        await h.reading(.mgdl(50))
        XCTAssertFalse(alarms.repeatAlarms.isEmpty)

        alarms.listingFails = true    // e.g. the user revoked alarms in Settings
        await h.service.send(.user(.acknowledge(.urgentLow)))
        XCTAssertEqual(Array(alarms.scheduled.keys), [legacy.id], "every alarm with a known ID is cancelled regardless")
        XCTAssertTrue(h.service.deliveryStatus.problems.contains { if case .urgentLowAlarmFailed = $0 { true } else { false } },
                      "the unreadable list is surfaced")
    }

    // MARK: Stop taps

    func test_aStaleStopTapIsDroppedSoItCannotAcknowledgeANewEpisode() async {
        let tapClock = TestClock()
        let bridge = UrgentLowAlarmIntentBridge(clock: tapClock)
        await bridge.stopTapped()                      // queued: nothing connected yet
        tapClock.advance(seconds: UrgentLowAlarmIntentBridge.maximumQueuedAge + 1)
        let h = ServiceHarness(alarms: FakeSystemAlarms())
        await h.reading(.mgdl(50))                     // a new urgent low, never seen by the user
        await bridge.connect { [service = h.service!] action in await service.send(.user(action)) }
        XCTAssertEqual(h.service.phase(of: .urgentLow), .firing(since: Fixtures.t0), "the old tap did not acknowledge it")
    }
}

/// Safety review WS4 delta, major: a rollback smaller than the time already elapsed leaves every
/// stored date in the past; it is caught by comparing `now` with the last input's `now` plus the
/// real time elapsed on the monotonic clock (or, without it, with the latest `now` seen).
@MainActor
final class PartialRollbackTests: XCTestCase {
    private func freshSession(_ h: EngineHarness) {
        h.session = SensorSession(serial: Fixtures.serial, start: h.now.addingTimeInterval(-86_400), warmUpEndsAt: h.now.addingTimeInterval(-80_000),
                                  expiresAt: h.now.addingTimeInterval(5 * 86_400), gracePeriodEndsAt: h.now.addingTimeInterval(6 * 86_400))
    }

    /// The reviewer's probe: snooze 30 min; 25 min in, the clock is set back 24 min.
    func test_S7_partialRollbackDuringSnoozeEndsIt() {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.snooze(.urgentLow, minutes: 30))
        h.clock.advance(minutes: 25)
        h.tick()
        h.clock.advance(minutes: -24)
        var real = 25.0
        var fired = false
        while real < 60 && !fired {
            h.clock.advance(minutes: 1)
            real += 1
            freshSession(h)
            fired = h.reading(.mgdl(50)).fired.contains(.urgentLow)
        }
        XCTAssertTrue(fired)
        XCTAssertLessThanOrEqual(real, 30, "re-fires within the 30 minutes (was 54)")
    }

    /// The same, with no input at all between the snooze and the rollback (the reviewer's exact
    /// probe): only the monotonic clock can tell that 26 minutes passed while the wall clock says 2.
    func test_S7_partialRollbackWithNoInputInBetweenEndsTheSnooze() {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.snooze(.urgentLow, minutes: 30))
        h.clock.advance(minutes: 25)
        h.clock.advance(minutes: -24)
        var real = 25.0
        var fired = false
        while real < 60 && !fired {
            h.clock.advance(minutes: 1)
            real += 1
            freshSession(h)
            fired = h.reading(.mgdl(50)).fired.contains(.urgentLow)
        }
        XCTAssertLessThanOrEqual(real, 30)
    }

    func test_afterARebootTheCheckFallsBackToTheLatestWallClockSeen() {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.snooze(.urgentLow, minutes: 30))
        h.clock.advance(minutes: 10)
        h.clock.reboot(uptime: 5)            // monotonic clock restarted: not comparable
        h.clock.advance(minutes: -20)        // and the wall clock went back 20 minutes
        h.tick()
        XCTAssertEqual(h.phase(.urgentLow), .snoozed(until: h.now), "still detected against the latest now seen")
        let noUptime = EngineHarness()
        noUptime.clock.reboot(uptime: nil)
        noUptime.mgdl(50)
        noUptime.user(.snooze(.urgentLow, minutes: 30))
        noUptime.clock.advance(minutes: -5)
        noUptime.tick()
        XCTAssertEqual(noUptime.phase(.urgentLow), .snoozed(until: noUptime.now))
    }

    func test_systemUptimeIsMonotonic() {
        let clock = SystemAlertClock()
        let a = clock.uptime ?? 0
        let b = clock.uptime ?? 0
        XCTAssertGreaterThan(a, 0)
        XCTAssertGreaterThanOrEqual(b, a)
    }

    func test_partialRollbackKeepsWhatWasLeftOfANonUrgentSnooze() {
        let h = EngineHarness()
        h.mgdl(65)
        h.user(.snooze(.low, minutes: 60))
        h.clock.advance(minutes: 25)
        h.tick()
        h.clock.advance(minutes: -24)
        h.tick()
        XCTAssertEqual(h.phase(.low), .snoozed(until: h.now.addingTimeInterval(minutes(35))), "35 minutes were left")
    }

    func test_partialRollbackReplansUrgentLowRepeatsFromNow() {
        let h = EngineHarness()
        h.mgdl(50)
        h.clock.advance(minutes: 12)
        h.tick()
        h.clock.advance(minutes: -10)
        let actions = h.tick()
        XCTAssertTrue(actions.contains { if case .cancelSlots(.urgentLow, _) = $0 { true } else { false } }, "old wall-clock repeats removed")
        XCTAssertEqual(h.phase(.urgentLow), .firing(since: h.now))
        XCTAssertEqual(h.pendingDates(.urgentLow).first, h.now.addingTimeInterval(minutes(5)))
        XCTAssertEqual(h.engine.snapshot.missedReadingsReference, h.now, "the missed-readings window restarts too")
    }

    func test_smallClockCorrectionsAreNotRollbacks() {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.snooze(.urgentLow, minutes: 30))
        h.clock.advance(minutes: 10)
        h.tick()
        h.clock.advance(seconds: -30)   // NTP nudging the clock by half a minute
        h.tick()
        XCTAssertEqual(h.phase(.urgentLow), .snoozed(until: Fixtures.t0.addingTimeInterval(minutes(30))))
    }
}
