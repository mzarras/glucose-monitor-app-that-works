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
        XCTAssertNotNil(alarms.scheduled[legacy.id])
        XCTAssertTrue(alarms.scheduled.values.filter { $0.id != legacy.id }.allSatisfy { $0.fireDate >= Fixtures.t0.addingTimeInterval(minutes(30)) },
                      "every alarm with a known ID is cancelled regardless; only the snooze-end ones are new (D44)")
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
        XCTAssertEqual(h.tick().fired, [.urgentLow], "still detected against the latest now seen: the snooze ends, it re-alarms (D44)")
        XCTAssertEqual(h.phase(.urgentLow), .firing(since: h.now))
        let noUptime = EngineHarness()
        noUptime.clock.reboot(uptime: nil)
        noUptime.mgdl(50)
        noUptime.user(.snooze(.urgentLow, minutes: 30))
        noUptime.clock.advance(minutes: -5)
        noUptime.tick()
        XCTAssertEqual(noUptime.phase(.urgentLow), .firing(since: noUptime.now))
    }

    func test_systemUptimeIsMonotonicAndNamesItsBoot() throws {
        let clock = SystemAlertClock()
        let a = try XCTUnwrap(clock.uptime)
        let b = try XCTUnwrap(clock.uptime)
        XCTAssertGreaterThan(a.seconds, 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(b.seconds(since: a)), 0)
        XCTAssertNotNil(a.boot, "kern.bootsessionuuid")
        XCTAssertEqual(a.boot, b.boot)
    }

    func test_uptimesFromDifferentBootsAreNotCompared() {
        let before = Uptime(seconds: 50_000, boot: "A")
        XCTAssertEqual(Uptime(seconds: 50_100, boot: "A").seconds(since: before), 100)
        XCTAssertNil(Uptime(seconds: 60_000, boot: "B").seconds(since: before), "another boot, even with a larger value")
        XCTAssertNil(Uptime(seconds: 40_000, boot: "A").seconds(since: before), "went backwards")
        XCTAssertNil(Uptime(seconds: 60_000, boot: nil).seconds(since: before))
        XCTAssertNil(Uptime(seconds: 60_000, boot: nil).seconds(since: Uptime(seconds: 50_000, boot: nil)),
                     "two unreadable boot sessions are not 'the same boot'")
    }

    /// If `kern.bootsessionuuid` cannot be read, the engine must not compare monotonic readings:
    /// it falls back to comparing with the latest wall clock seen.
    func test_unreadableBootSessionFallsBackToTheLatestWallClockSeen() {
        // Real time passes 25 min (monotonic +25 min) while the wall clock moves only +2 min.
        // Comparable readings would call that a rollback; with unknown boots it is not assumed.
        var engine = AlertEngine(settings: .defaults, configuration: Fixtures.configuration, now: Fixtures.t0)
        let start = Uptime(seconds: 1_000, boot: nil)
        _ = engine.handle(.reading(Fixtures.reading(.mgdl(50), at: Fixtures.t0), session: Fixtures.session), at: Fixtures.t0, uptime: start)
        _ = engine.handle(.user(.snooze(.urgentLow, minutes: 30)), at: Fixtures.t0, uptime: start)
        let later = Fixtures.t0.addingTimeInterval(minutes(2))
        _ = engine.handle(.tick, at: later, uptime: Uptime(seconds: 1_000 + minutes(25), boot: nil))
        XCTAssertEqual(engine.phase(of: .urgentLow), .snoozed(until: Fixtures.t0.addingTimeInterval(minutes(30))), "not treated as a rollback")
        // A wall clock earlier than the latest seen is still caught.
        let back = Fixtures.t0.addingTimeInterval(-minutes(5))
        _ = engine.handle(.tick, at: back, uptime: Uptime(seconds: 1_000 + minutes(26), boot: nil))
        XCTAssertEqual(engine.phase(of: .urgentLow), .firing(since: back), "fallback detects it; the snooze ends and urgent low re-alarms (D44)")
    }

    /// Second delta review, minor: an NTP correction (or a user) setting the clock back while a
    /// repeat rings must not stop that alarm; only later repeats are re-planned.
    func test_rollbackDoesNotStopTheRingingAlarm() async throws {
        let clock = TestClock()
        let alarms = FakeSystemAlarms()
        let center = FakeNotificationCenter()
        let h = ServiceHarness(alarms: alarms, center: center, clock: clock)
        await h.service.start()
        await h.reading(.mgdl(50))
        let ringing = Fixtures.t0.addingTimeInterval(minutes(5))
        clock.set(ringing.addingTimeInterval(3))
        await h.reading(.mgdl(49))                           // repeat 1 is ringing
        clock.advance(seconds: 2)
        clock.advance(minutes: -10)                          // the clock is set back 10 minutes
        await h.service.send(.tick)
        XCTAssertNotNil(alarms.alarm(firingAt: ringing), "the ringing alarm is left alone")
        XCTAssertTrue(center.pending(for: .urgentLow).contains { $0.fireDate == ringing }, "and its notification")
        XCTAssertNil(alarms.alarm(firingAt: Fixtures.t0.addingTimeInterval(minutes(10))), "later repeats (old wall-clock times) are replaced")
        XCTAssertNotNil(alarms.alarm(firingAt: clock.now.addingTimeInterval(minutes(5))), "by a grid from now")
        // Later plans keep treating the kept repeat as due, so it is never cancelled afterwards.
        clock.advance(minutes: 4)
        await h.reading(.mgdl(48))
        XCTAssertNotNil(alarms.alarm(firingAt: ringing))
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

/// Second delta review, major: the 128-slot ID cycle must never hand a new repeat the slot of one
/// the engine still remembers, however many repeats are replaced in a short time.
@MainActor
final class SlotAllocationTests: XCTestCase {
    func test_S7_idReuseNeverTouchesALivePendingRepeat() async throws {
        let clock = TestClock()
        let alarms = FakeSystemAlarms()
        alarms.strictClock = clock
        let center = FakeNotificationCenter()
        center.strictClock = clock
        var settings = AlertSettings.defaults
        settings.urgentLow.repeatMinutes = 2
        var h = ServiceHarness(settings: settings, alarms: alarms, center: center, clock: clock)
        await h.service.start()
        await h.reading(.mgdl(50))

        let due = Fixtures.t0.addingTimeInterval(minutes(2))
        clock.set(due.addingTimeInterval(-30))               // a repeat is 30 s away
        await h.reading(.mgdl(49))
        // The reviewer's probe: the repeat stepper moved 3, 2, 4, 2, 5, 2 within 30 s — each change
        // replaces up to 30 pending repeats (168 sequence numbers in all, past the 128-slot cycle) —
        // then the same again after two relaunches.
        for round in 0..<3 {
            for minutes in [3, 2, 4, 2, 5, 2] {
                clock.advance(seconds: 1)
                settings = h.service.settings
                settings.urgentLow.repeatMinutes = minutes
                await h.service.send(.settings(settings))
                let entries = h.service.engine.series(.urgentLow).entries
                XCTAssertEqual(Set(entries.map(\.slot)).count, entries.count, "no two remembered repeats share a slot")
            }
            XCTAssertNotNil(alarms.alarm(firingAt: due), "round \(round): the protected repeat's alarm is still there")
            XCTAssertTrue(center.pending(for: .urgentLow).contains { $0.fireDate == due }, "…and its notification")
            let snapshot = try XCTUnwrap(h.snapshots.last)
            h = ServiceHarness(settings: h.service.settings, snapshot: snapshot, alarms: alarms, center: center, clock: clock)
            await h.service.start()
        }
        XCTAssertGreaterThan(h.service.engine.series(.urgentLow).nextSequence, AlertLimits.scheduleIDCycle, "the cycle did wrap")
    }

    func test_theCycleHasRoomForEverythingRemembered() {
        // Remembered at most: an hour of past repeats + the protected minute + an hour ahead, at the
        // 2-minute floor, plus one protected entry per input in a burst of changes.
        let pastAndFuture = 2 * AlertLimits.maximumScheduledSlots + 1
        XCTAssertLessThan(pastAndFuture + 30, AlertLimits.scheduleIDCycle)
    }

    func test_anExtremeBurstForgetsOldPastEntriesRatherThanReuseALiveSlot() {
        var engine = AlertEngine(settings: .defaults, configuration: Fixtures.configuration, now: Fixtures.t0)
        var series = RepeatSeries()
        // 120 past entries (as if left by a long burst) and one protected.
        series.entries = (0..<120).map { ScheduledRepeat(sequence: $0, date: Fixtures.t0.addingTimeInterval(Double(-3000 + $0))) }
            + [ScheduledRepeat(sequence: 120, date: Fixtures.t0.addingTimeInterval(30))]
        series.nextSequence = 121
        engine.snapshot.repeatSeries[AlertKind.urgentLow.rawValue] = series
        let actions = engine.planSeries(.urgentLow, anchor: Fixtures.t0, interval: minutes(5), firstIndex: 1, count: 12, now: Fixtures.t0, isRepeat: true)
        let entries = engine.series(.urgentLow).entries
        XCTAssertEqual(Set(entries.map(\.slot)).count, entries.count)
        XCTAssertTrue(entries.contains { $0.sequence == 120 }, "the protected entry stays")
        XCTAssertEqual(actions.scheduled(.urgentLow)?.count, 12)
        XCTAssertFalse(actions.scheduledNotices(.urgentLow)?.contains { $0.slot == 120 % AlertLimits.scheduleIDCycle } ?? true)
    }
}

/// Reviewer follow-up: the "no free slot" path must be loud (logged, shown in Settings), never silent.
@MainActor
final class RepeatShortfallTests: XCTestCase {
    /// 128 repeats, all due within the protected minute: every slot is held and none may be touched.
    private func fullSeries(now: Date) -> RepeatSeries {
        var series = RepeatSeries()
        series.entries = (0..<AlertLimits.scheduleIDCycle).map { ScheduledRepeat(sequence: $0, date: now.addingTimeInterval(Double(1 + $0 % 59))) }
            .sorted { $0.date < $1.date }
        series.nextSequence = AlertLimits.scheduleIDCycle
        return series
    }

    func test_whenEverySlotIsHeldTheShortfallIsReported() {
        var engine = AlertEngine(settings: .defaults, configuration: Fixtures.configuration, now: Fixtures.t0)
        engine.snapshot.repeatSeries[AlertKind.urgentLow.rawValue] = fullSeries(now: Fixtures.t0)
        let actions = engine.planSeries(.urgentLow, anchor: Fixtures.t0, interval: minutes(5), firstIndex: 1, count: 12, now: Fixtures.t0, isRepeat: true)
        XCTAssertEqual(actions, [.repeatsNotAllScheduled(.urgentLow, missing: 12)], "nothing scheduled, nothing touched, and it says so")
        XCTAssertEqual(engine.series(.urgentLow).entries.count, AlertLimits.scheduleIDCycle)
    }

    func test_S5_shortfallIsLoggedAndSurfacedThenClears() async throws {
        let firing = EngineHarness()
        firing.mgdl(50)
        var snapshot = firing.engine.snapshot
        snapshot.repeatSeries[AlertKind.urgentLow.rawValue] = fullSeries(now: Fixtures.t0)
        let h = ServiceHarness(snapshot: snapshot)
        await h.service.start()
        XCTAssertEqual(h.service.deliveryStatus.problems, [.repeatsNotAllScheduled(.urgentLow, missing: 12)])
        XCTAssertTrue(h.log.messages.contains { $0.contains("12 repeat(s) NOT scheduled") })

        h.clock.advance(minutes: 1)
        await h.reading(.mgdl(90))   // recovers: everything cancelled, nothing missing any more
        XCTAssertEqual(h.service.deliveryStatus.problems, [])
    }
}
