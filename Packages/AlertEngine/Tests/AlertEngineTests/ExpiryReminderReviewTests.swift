import XCTest
import GlucoseCore
@testable import AlertEngine

/// D43 safety review follow-up: a reminder is never counted as out unless it is (B1), a sensor that
/// must be replaced drops its reminders (M1), and the minors m1–m5, m11, m12.
@MainActor
final class ExpiryReminderReviewTests: XCTestCase {
    /// As in ExpiryReminderTests: expiry 2026-09-24 21:40 UTC, grace end 2026-09-25 09:40 UTC.
    private let expiresAt = Fixtures.t0.addingTimeInterval(33 * 3600 + 40 * 60)
    private var graceEndsAt: Date { expiresAt.addingTimeInterval(12 * 3600) }
    private var session: SensorSession {
        let start = expiresAt.addingTimeInterval(-10 * 86_400)
        return SensorSession(serial: Fixtures.serial, start: start, warmUpEndsAt: start.addingTimeInterval(1800),
                             expiresAt: expiresAt, gracePeriodEndsAt: graceEndsAt)
    }
    private var active: SensorState { .active(sessionStart: session.start, expiresAt: expiresAt) }
    private let reminders = AlertKind.sensorExpiryReminders
    private let denied = NotificationPermissionState(authorization: .denied, alerts: .disabled, sounds: .disabled,
                                                     criticalAlerts: .notSupported, timeSensitive: .disabled)
    private let allowed = NotificationPermissionState(authorization: .authorized, alerts: .enabled, sounds: .enabled,
                                                      criticalAlerts: .notSupported, timeSensitive: .enabled)

    private func hours(_ h: Double) -> TimeInterval { h * 3600 }

    private func settings(_ change: (inout AlertSettings) -> Void = { _ in }) -> AlertSettings {
        var s = AlertSettings.defaults
        s.missedReadings.isEnabled = false   // keep these tests about the reminders
        change(&s)
        return s
    }

    private func startSession(_ s: ServiceHarness) async {
        await s.service.start()
        await s.service.send(.reading(Fixtures.reading(.mgdl(120), at: s.clock.now), session: session))
        await s.service.send(.sensorState(active))
    }

    private func move(_ s: ServiceHarness, to date: Date) {
        s.clock.advance(seconds: date.timeIntervalSince(s.clock.now))
    }

    private func reminderPending(_ s: ServiceHarness) -> [AlertKind] {
        reminders.filter { !s.center.pending(for: $0).isEmpty }
    }

    private func posted(_ s: ServiceHarness, _ kind: AlertKind) -> [NotificationRequestSpec] {
        s.center.posted.filter { $0.userInfo[AlertNotificationIDs.userInfoKind] == kind.rawValue }
    }

    private func harness(_ settings: AlertSettings = .defaults) -> EngineHarness {
        let h = EngineHarness(settings: settings)
        h.session = session
        return h
    }

    private func moveClock(_ h: EngineHarness, to date: Date) {
        h.clock.advance(seconds: date.timeIntervalSince(h.now))
    }

    // MARK: B1 — a refused or missing reminder is never counted as out

    func test_S5_remindersRefusedByTheSystemAreAddedAgainWhenNotificationsAreAllowed() async {
        let s = ServiceHarness(settings: settings())
        s.center.failAdds = true
        s.center.permissions = denied
        await startSession(s)
        XCTAssertEqual(reminderPending(s), [], "every add refused")
        for kind in reminders {
            guard case .notScheduled? = s.service.engine.snapshot.expiryPlan?[kind] else {
                return XCTFail("\(kind): the refusal was reported back, it does not count as pending")
            }
        }

        // The user allows notifications in iOS Settings; the app is still running (BLE restoration).
        s.center.failAdds = false
        s.center.permissions = allowed
        _ = await s.service.refreshDeliveryStatus()
        XCTAssertEqual(reminderPending(s), reminders, "added again on the authorization change")
        XCTAssertEqual(s.center.pending(for: .sensorExpired).first?.fireDate, graceEndsAt)
    }

    func test_S5_aForegroundAddsRemindersTheSystemRefusedOrDropped() async {
        let s = ServiceHarness(settings: settings())
        s.center.failAdds = true
        await startSession(s)
        s.center.failAdds = false   // nothing pending, and no authorization change to tell the app
        await s.service.send(.foreground)
        XCTAssertEqual(reminderPending(s), reminders)
        // A reminder the system dropped is back after the next foreground.
        s.center.removePending(identifiers: [AlertNotificationIDs.scheduled(.sensorExpiringIn12Hours, slot: 0)])
        await s.service.send(.foreground)
        XCTAssertEqual(reminderPending(s), reminders)
    }

    func test_S5_sensorExpiredRefusedByTheSystemIsPostedWhenTheEndIsDetected() async {
        for soundOnSilent in [true, false] {
            let s = ServiceHarness(settings: settings { $0.setSoundsOnSilent(soundOnSilent, for: .sensorExpired) })
            s.center.failAdds = true
            await startSession(s)
            s.center.failAdds = false   // a transient refusal: nothing tells the app to add them again
            move(s, to: graceEndsAt.addingTimeInterval(180))
            await s.service.send(.sensorState(.expired))
            XCTAssertEqual(posted(s, .sensorExpired).count, 1, "sound on silent \(soundOnSilent): posted at detection, not 2 h later")
            XCTAssertEqual(s.audio.plays.map(\.fileName), soundOnSilent ? ["alert-warble.wav"] : [], "sound on silent \(soundOnSilent)")
            XCTAssertEqual(s.service.phase(of: .sensorExpired), .firing(since: s.clock.now))
        }
    }

    func test_S5_aMissingSensorExpiredIsPostedWhenTheEndIsDetected() async {
        for soundOnSilent in [true, false] {
            let s = ServiceHarness(settings: settings { $0.setSoundsOnSilent(soundOnSilent, for: .sensorExpired) })
            await startSession(s)
            // The add went through, but the notification is not there (the system dropped it).
            s.center.removePending(identifiers: [AlertNotificationIDs.scheduled(.sensorExpired, slot: 0)])
            move(s, to: graceEndsAt.addingTimeInterval(180))
            await s.service.send(.sensorState(.expired))
            XCTAssertEqual(posted(s, .sensorExpired).map(\.identifier), ["sensor.alert.sensorExpired.slot0"], "sound on silent \(soundOnSilent)")
            XCTAssertEqual(s.audio.plays.map(\.fileName), soundOnSilent ? ["alert-warble.wav"] : [])
        }
    }

    func test_S5_aMissingReminderIsPostedWhenItsMomentIsReachedWhileTheAppRuns() async {
        let s = ServiceHarness(settings: settings())
        await startSession(s)
        s.center.removePending(identifiers: [AlertNotificationIDs.scheduled(.sensorExpiringIn2Hours, slot: 0)])
        move(s, to: expiresAt.addingTimeInterval(-hours(2) + 180))
        await s.service.send(.tick)
        XCTAssertEqual(posted(s, .sensorExpiringIn2Hours).map(\.title), ["Sensor expires in 1 h 57 min (at 9:40 PM)"], "written for now")
        // One that is there is not posted again.
        move(s, to: expiresAt.addingTimeInterval(120))
        await s.service.send(.tick)
        XCTAssertEqual(posted(s, .sensorGracePeriod), [])
    }

    func test_S5_aRefusedReminderIsPostedWhenItsMomentComesWhileTheAppRuns() async {
        let s = ServiceHarness(settings: settings())
        s.center.failAdds = true
        await startSession(s)
        s.center.failAdds = false
        move(s, to: expiresAt.addingTimeInterval(-hours(24) + 60))
        await s.service.send(.tick)
        let posted = posted(s, .sensorExpiringIn24Hours)
        XCTAssertEqual(posted.map(\.title), ["Sensor expires in 23 h 59 min"])
        XCTAssertEqual(posted.first?.interruption, .active, "still without sound")
        await s.service.send(.tick)
        XCTAssertEqual(self.posted(s, .sensorExpiringIn24Hours).count, 1, "once")
    }

    func test_S5_aRefusedSensorExpiredIsPostedByTheEngineAtDetection() throws {
        let h = harness()
        h.mgdl(120)
        let notice = try XCTUnwrap(h.send(.sensorState(active)).scheduledNotices(.sensorExpired)?.first)
        h.send(.notificationsNotScheduled([notice]))
        XCTAssertEqual(h.engine.snapshot.expiryPlan?[.sensorExpired], .notScheduled(graceEndsAt))
        XCTAssertEqual(h.tick().reminderActions, [], "not retried by itself")
        moveClock(h, to: graceEndsAt.addingTimeInterval(-600))
        let end = h.send(.sensorState(.expired)).reminderActions
        XCTAssertEqual(end.fired, [.sensorExpired], "known to be missing: posted, not merely checked")
        XCTAssertEqual(end.ensured, [.sensorGracePeriod], "only the grace start's moment check")
    }

    /// Review n2: the phone clock set back 5 minutes a minute before the 2-hour reminder. iOS fires it
    /// on real time; the next wake brings the session's dates shifted with the clock (the reading
    /// first, then the state). The reminder's new date is in the past: it is checked, not posted again.
    func test_aClockSetBackJustBeforeAReminderDoesNotPostItTwice() {
        let h = harness()
        h.mgdl(120)
        h.send(.sensorState(active))
        let twoHours = expiresAt.addingTimeInterval(-hours(2))
        moveClock(h, to: twoHours.addingTimeInterval(-60))   // real 19:39
        h.tick()
        h.clock.advance(seconds: -300)                       // wall 19:34
        h.clock.advance(seconds: 120)                        // wall 19:36, real 19:41: iOS fired it at real 19:40
        let start = session.start.addingTimeInterval(-300)
        h.session = SensorSession(serial: Fixtures.serial, start: start, warmUpEndsAt: start.addingTimeInterval(1800),
                                  expiresAt: expiresAt.addingTimeInterval(-300), gracePeriodEndsAt: graceEndsAt.addingTimeInterval(-300))
        let reading = h.mgdl(120).reminderActions
        XCTAssertEqual(reading, [], "the reading's dates alone do not move the plan by halves")
        let state = h.send(.sensorState(.active(sessionStart: start, expiresAt: expiresAt.addingTimeInterval(-300)))).reminderActions
        XCTAssertEqual(state.fired, [], "not posted blindly")
        XCTAssertNil(state.scheduled(.sensorExpiringIn2Hours), "nor added again")
        XCTAssertFalse(state.contains(.cancelSlots(.sensorExpiringIn2Hours, [0])))
        XCTAssertEqual(state.ensured, [.sensorExpiringIn2Hours], "checked: posted only if it is not there")
        XCTAssertEqual(state.scheduled(.sensorGracePeriod), [expiresAt.addingTimeInterval(-300)], "later ones follow the clock")
        XCTAssertEqual(state.scheduled(.sensorExpired), [graceEndsAt.addingTimeInterval(-300)])
        XCTAssertEqual(h.tick().reminderActions, [])
    }

    func test_aClockSetBackPastARefusedReminderPostsIt() throws {
        let h = harness()
        h.mgdl(120)
        let notice = try XCTUnwrap(h.send(.sensorState(active)).scheduledNotices(.sensorExpiringIn2Hours)?.first)
        h.send(.notificationsNotScheduled([notice]))
        moveClock(h, to: expiresAt.addingTimeInterval(-hours(2) - 60))
        h.clock.advance(seconds: -180)
        let state = h.send(.sensorState(.active(sessionStart: session.start, expiresAt: expiresAt.addingTimeInterval(-300)))).reminderActions
        XCTAssertEqual(state.fired, [.sensorExpiringIn2Hours], "known to be missing: posted")
    }

    func test_dismissingAReminderThatJustCameDueNeedsNoCheck() {
        let h = harness()
        h.mgdl(120)
        h.send(.sensorState(active))
        moveClock(h, to: expiresAt.addingTimeInterval(-hours(24) + 30))
        XCTAssertEqual(h.user(.silence(.sensorExpiringIn24Hours)).reminderActions, [.stopSound(.sensorExpiringIn24Hours)])
        XCTAssertEqual(h.tick().reminderActions, [], "already known to be out")
    }

    // MARK: M1 — a sensor that must be replaced drops its reminders

    func test_aSensorThatMustBeReplacedRemovesItsReminders() {
        for kind in [SensorFailure.Kind.sensorFailed, .sessionStopped, .unsupportedSensor] {
            let h = harness()
            h.mgdl(120)
            h.send(.sensorState(active))
            let failed = h.send(.sensorState(.failed(SensorFailure(kind: kind, message: "x")))).reminderActions
            XCTAssertEqual(failed, reminders.map { .cancelSlots($0, [0]) }, "\(kind)")
            XCTAssertNil(h.engine.snapshot.expiryPlan)
        }
    }

    func test_pairingProblemsUnclassifiedFailuresAndErrorsKeepTheReminders() {
        let states: [SensorState] = [
            .failed(SensorFailure(kind: .pairingRejected, message: "x")), .failed(SensorFailure(kind: .bondRemoved, message: "x")),
            .failed(SensorFailure(kind: .other, message: "x")), .error(code: 7, description: "x"), .calibrationNeeded(code: 1),
        ]
        for state in states {
            let h = harness()
            h.mgdl(120)
            h.send(.sensorState(active))
            XCTAssertEqual(h.send(.sensorState(state)).reminderActions, [], "\(state)")
            XCTAssertNotNil(h.engine.snapshot.expiryPlan, "\(state)")
        }
    }

    func test_aSensorReportedFailedThenRunningAgainGetsItsRemindersBack() {
        let h = harness()
        h.mgdl(120)
        h.send(.sensorState(active))
        moveClock(h, to: expiresAt.addingTimeInterval(-hours(10)))
        h.send(.sensorState(.failed(SensorFailure(kind: .sensorFailed, message: "x"))))
        let back = h.send(.sensorState(active)).reminderActions
        XCTAssertEqual(back.fired, [.sensorExpiringIn12Hours], "the current one, posted late")
        XCTAssertEqual(back.firedNotice(.sensorExpiringIn12Hours)?.title, "Sensor expires in 10 hours")
        XCTAssertEqual(back.scheduled(.sensorExpiringIn2Hours), [expiresAt.addingTimeInterval(-hours(2))])
        XCTAssertEqual(back.scheduled(.sensorExpired), [graceEndsAt])
    }

    // MARK: m1 — quiet hours decided at detection

    func test_quietHoursAreDecidedWhenTheEndIsDetected() async {
        // Quiet hours 09:00–09:42 cover the grace end (09:40), not the end report (09:43).
        let s = ServiceHarness(settings: settings { $0.quietHours = QuietHours(isEnabled: true, startMinuteOfDay: 9 * 60, endMinuteOfDay: 9 * 60 + 42) })
        await startSession(s)
        XCTAssertEqual(s.center.pending(for: .sensorExpired).first?.interruption, .passive, "the grace end is in quiet hours")
        move(s, to: graceEndsAt.addingTimeInterval(180))
        await s.service.send(.sensorState(.expired))
        XCTAssertEqual(s.audio.plays.map(\.fileName), ["alert-warble.wav"], "quiet hours are over: it sounds")
    }

    // MARK: m2 — launch removes what the plan no longer holds

    func test_aRelaunchRemovesAStrayReminderTheSessionNoLongerHolds() async throws {
        let first = ServiceHarness(settings: settings())
        await startSession(first)
        move(first, to: expiresAt.addingTimeInterval(hours(1)))
        await first.service.send(.sensorState(.gracePeriod(endsAt: graceEndsAt)))
        await first.service.send(.sensorState(.expired))   // early end: the pending one is cancelled
        let snapshot = try XCTUnwrap(first.snapshots.last)
        // The process died before the cancel ran: the stray is still in the system.
        let stray = NotificationRequestSpec(
            identifier: "sensor.alert.sensorExpired.slot0", title: "Sensor expired", body: "", threadIdentifier: "", categoryIdentifier: "",
            interruption: .timeSensitive, sound: .named(fileName: "alert-warble.wav"), fireDate: graceEndsAt,
            userInfo: [AlertNotificationIDs.userInfoKind: "sensorExpired"])
        try await first.center.add(stray)
        let second = ServiceHarness(settings: settings(), snapshot: snapshot, center: first.center, clock: first.clock)
        await second.service.start()
        XCTAssertEqual(second.center.pending(for: .sensorExpired), [], "removed: it would have been a second 'Sensor expired'")
    }

    func test_launchCancelsEveryReminderSlotExceptThePendingOnes() {
        let h = harness()
        h.mgdl(120)
        h.send(.sensorState(active))
        moveClock(h, to: expiresAt.addingTimeInterval(-hours(2) - 30))   // 24 h and 12 h out; 2 h due in 30 s
        h.tick()
        var engine = AlertEngine(settings: h.engine.settings, configuration: Fixtures.configuration, restoring: h.engine.snapshot, now: h.now)
        let actions = engine.handle(.launched, at: h.now).reminderActions
        XCTAssertTrue(actions.contains(.cancelSlots(.sensorExpiringIn24Hours, [0])), "delivered")
        XCTAssertTrue(actions.contains(.cancelSlots(.sensorExpiringIn12Hours, [0])), "delivered")
        XCTAssertFalse(actions.contains(.cancelSlots(.sensorExpiringIn2Hours, [0])), "due within a minute: never touched")
        XCTAssertNil(actions.scheduled(.sensorExpiringIn2Hours))
        XCTAssertNotNil(actions.scheduled(.sensorGracePeriod), "pending later: written again")
    }

    // MARK: m3 — a DEBUG replay engine keeps away from the real reminders

    #if DEBUG
    func test_aReplayEngineUsesItsOwnReminderSlot() async {
        let production = ServiceHarness(settings: settings())
        await startSession(production)
        var configuration = Fixtures.configuration
        configuration.acceptsReplayReadings = true
        let replay = AlertService(settings: settings(), restoring: nil, configuration: configuration, clock: production.clock,
                                  notificationCenter: production.center, audio: FakeAudioPlayer())
        await replay.start()
        XCTAssertEqual(reminderPending(production), reminders, "the real reminders survive the replay engine's launch")
        await replay.send(.reading(Fixtures.reading(.mgdl(120), at: production.clock.now), session: session))
        await replay.send(.sensorState(active))
        for kind in reminders {
            XCTAssertEqual(Set(production.center.pending(for: kind).map(\.identifier)),
                           ["sensor.alert.\(kind.rawValue).slot0", "sensor.alert.\(kind.rawValue).slot1"], "\(kind)")
        }
    }
    #endif

    // MARK: m5 — a brief early end report

    func test_aBriefEarlyEndReportSchedulesTheRealEndAgain() {
        let h = harness()
        h.mgdl(120)
        h.send(.sensorState(active))
        moveClock(h, to: expiresAt.addingTimeInterval(hours(1)))
        h.send(.sensorState(.gracePeriod(endsAt: graceEndsAt)))
        XCTAssertEqual(h.send(.sensorState(.expired)).reminderActions.first, .cancelSlots(.sensorExpired, [0]))
        let resumed = h.send(.sensorState(.gracePeriod(endsAt: graceEndsAt))).reminderActions
        XCTAssertEqual(resumed.first, .cancel(.sensorExpired), "the early alert clears")
        XCTAssertEqual(resumed.scheduled(.sensorExpired), [graceEndsAt], "and the real end has its notification again")
        moveClock(h, to: graceEndsAt.addingTimeInterval(120))
        XCTAssertEqual(h.send(.sensorState(.expired)).reminderActions.ensured, [.sensorExpired], "the real end: checked, not posted twice")
    }

    // MARK: m11 — S7

    func test_S7_urgentLowCannotBeSilencedAndSoundsWhenEveryOtherAlertIsSilent() {
        var silent = AlertSettings.defaults
        for kind in AlertKind.allCases { silent.setPlaysSound(false, for: kind) }
        XCTAssertFalse(silent.setPlaysSound(false, for: .urgentLow), "the settings API refuses")
        XCTAssertTrue(silent.playsSound(.urgentLow))
        let h = EngineHarness(settings: silent)
        let notice = h.mgdl(50).firedNotice(.urgentLow)
        XCTAssertEqual(notice?.playsSound, true)
        for critical in [false, true] {
            for alarms in [false, true] {
                for timing in DeliveryTiming.allCases {
                    let decision = DeliveryPolicy.decide(for: notice!, criticalAlertsEnabled: critical, systemAlarmsAvailable: alarms, timing: timing)
                    XCTAssertNotEqual(decision.notificationSound, NotificationSoundChoice.none)
                    XCTAssertGreaterThanOrEqual(decision.loudness, 1)
                }
            }
        }
        XCTAssertTrue(AlertKind.sensorExpiryReminders.dropLast().allSatisfy { !silent.playsSound($0) }, "the announcements did go silent")
    }

    // MARK: m12 — acknowledging an announcement leaves the pending reminders alone

    func test_openingAnAnnouncementRemovesOnlyTheShownNotification() async {
        let s = ServiceHarness(settings: settings())
        await startSession(s)
        let removedBefore = s.center.removedPending.count
        await s.service.send(.user(.acknowledge(.sensorExpiringIn12Hours)))
        XCTAssertTrue(s.center.removedDelivered.contains("sensor.alert.sensorExpiringIn12Hours.slot0"))
        XCTAssertEqual(s.center.pending(for: .sensorExpiringIn12Hours).count, 1, "still pending")
        XCTAssertEqual(s.center.removedPending.count, removedBefore, "no pending notification removed")
    }
}
