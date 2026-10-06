import XCTest
import GlucoseCore
@testable import AlertEngine

/// D43: sensor expiry reminders at 24 h (no sound by default), 12 h and 2 h before the end, at the
/// start of the grace period, and at its end (sensor expired). Pending notifications, one per point,
/// each switchable on its own.
@MainActor
final class ExpiryReminderTests: XCTestCase {
    /// 2026-09-24 21:40 UTC (t0 is 2026-09-23 12:00 UTC); the grace period ends 2026-09-25 09:40 UTC.
    private let expiresAt = Fixtures.t0.addingTimeInterval(33 * 3600 + 40 * 60)
    private var graceEndsAt: Date { expiresAt.addingTimeInterval(12 * 3600) }
    private var session: SensorSession {
        let start = expiresAt.addingTimeInterval(-10 * 86_400)
        return SensorSession(serial: Fixtures.serial, start: start, warmUpEndsAt: start.addingTimeInterval(1800),
                             expiresAt: expiresAt, gracePeriodEndsAt: graceEndsAt)
    }
    private var active: SensorState { .active(sessionStart: session.start, expiresAt: expiresAt) }
    private let reminders = AlertKind.sensorExpiryReminders

    private func harness(settings: AlertSettings = .defaults) -> EngineHarness {
        let h = EngineHarness(settings: settings)
        h.session = session
        return h
    }

    /// A reading (it carries the session, so the grace end is known), then the active state.
    @discardableResult
    private func startSession(_ h: EngineHarness) -> [AlertAction] {
        h.mgdl(120) + h.send(.sensorState(active))
    }

    private func hours(_ h: Double) -> TimeInterval { h * 3600 }

    private func moveClock(_ h: EngineHarness, to date: Date) {
        h.clock.advance(seconds: date.timeIntervalSince(h.now))
    }

    // MARK: Schedule points and texts

    func test_everyReminderIsPendingAsSoonAsTheSessionIsKnown() throws {
        let h = harness()
        h.mgdl(120)
        let actions = h.send(.sensorState(active)).reminderActions
        XCTAssertEqual(actions.count, 5, "one pending notification per reminder, nothing posted now")
        let expected: [(AlertKind, Date, String, String)] = [
            (.sensorExpiringIn24Hours, expiresAt.addingTimeInterval(-hours(24)), "Sensor expires in 24 hours",
             "The session ends tomorrow at 9:40 PM. A 12-hour grace period follows."),
            (.sensorExpiringIn12Hours, expiresAt.addingTimeInterval(-hours(12)), "Sensor expires in 12 hours",
             "The session ends today at 9:40 PM. A 12-hour grace period follows."),
            (.sensorExpiringIn2Hours, expiresAt.addingTimeInterval(-hours(2)), "Sensor expires in 2 hours (at 9:40 PM)",
             "Plan a sensor change. A 12-hour grace period follows."),
            (.sensorGracePeriod, expiresAt, "Sensor session ended — 12 h grace period",
             "Readings stop at 9:40 AM tomorrow. Replace the sensor before then."),
            (.sensorExpired, graceEndsAt, "Sensor expired", "The session has ended. No readings until a new sensor is paired."),
        ]
        for (kind, date, title, body) in expected {
            let notices = try XCTUnwrap(actions.scheduledNotices(kind), "\(kind)")
            XCTAssertEqual(notices.count, 1, "\(kind)")
            XCTAssertEqual(notices.first?.fireDate, date, "\(kind)")
            XCTAssertEqual(notices.first?.slot, AlertEngine.expiryReminderSlot, "\(kind)")
            XCTAssertEqual(notices.first?.title, title, "\(kind)")
            XCTAssertEqual(notices.first?.body, body, "\(kind)")
            XCTAssertEqual(notices.first?.playsSound, kind != .sensorExpiringIn24Hours, "\(kind): only the 24-hour one is silent")
        }
        XCTAssertEqual(actions.scheduledNotices(.sensorExpired)?.first?.snoozeMinutes, 120, "the sensor-expired alert's own Snooze")
        XCTAssertNil(actions.scheduledNotices(.sensorGracePeriod)?.first?.snoozeMinutes, "announcements have no Snooze")
        XCTAssertEqual(h.tick().reminderActions, [], "nothing more until a reminder is due")
    }

    func test_aGraceEndLearnedFromTheFirstReadingRewritesThePendingTextsOnce() {
        let h = harness()
        let first = h.send(.sensorState(active)).reminderActions
        XCTAssertEqual(first.count, 4, "the grace end is not known yet: nothing for 'sensor expired'")
        XCTAssertEqual(first.scheduledNotices(.sensorExpiringIn24Hours)?.first?.body, "The session ends tomorrow at 9:40 PM.")
        XCTAssertEqual(first.scheduledNotices(.sensorGracePeriod)?.first?.title, "Sensor session ended — grace period")
        XCTAssertEqual(first.scheduledNotices(.sensorGracePeriod)?.first?.body, "Replace the sensor soon.")

        let second = h.mgdl(120).reminderActions
        XCTAssertEqual(second.count, 5, "the four written again (same identifiers), sensor expired added")
        XCTAssertEqual(second.scheduledNotices(.sensorExpiringIn24Hours)?.first?.body,
                       "The session ends tomorrow at 9:40 PM. A 12-hour grace period follows.")
        XCTAssertEqual(second.scheduledNotices(.sensorGracePeriod)?.first?.title, "Sensor session ended — 12 h grace period")
        XCTAssertEqual(second.scheduled(.sensorExpired), [graceEndsAt])
        h.clock.advance(minutes: 5)
        XCTAssertEqual(h.mgdl(121).reminderActions, [], "only once")
    }

    // MARK: Suspended app

    func test_S5_expiryRemindersFireWhileTheAppIsSuspended() async {
        var settings = AlertSettings.defaults
        settings.missedReadings.isEnabled = false   // keep this test about the reminders
        let s = ServiceHarness(settings: settings)
        await s.service.start()
        await s.service.send(.reading(Fixtures.reading(.mgdl(120), at: s.clock.now), session: session))
        await s.service.send(.sensorState(active))

        let dates: [AlertKind: Date] = [
            .sensorExpiringIn24Hours: expiresAt.addingTimeInterval(-hours(24)), .sensorExpiringIn12Hours: expiresAt.addingTimeInterval(-hours(12)),
            .sensorExpiringIn2Hours: expiresAt.addingTimeInterval(-hours(2)), .sensorGracePeriod: expiresAt, .sensorExpired: graceEndsAt,
        ]
        for kind in reminders {
            let pending = s.center.pending(for: kind)
            XCTAssertEqual(pending.map(\.identifier), ["sensor.alert.\(kind.rawValue).slot0"], "\(kind)")
            XCTAssertEqual(pending.first?.fireDate, dates[kind], "\(kind)")
        }
        let silent = s.center.pending(for: .sensorExpiringIn24Hours).first
        XCTAssertEqual(silent?.interruption, .active, "24 h: a visible notification…")
        XCTAssertEqual(silent?.sound, NotificationSoundChoice.none, "…with no sound")
        let twelve = s.center.pending(for: .sensorExpiringIn12Hours).first
        XCTAssertEqual(twelve?.interruption, .timeSensitive)
        XCTAssertEqual(twelve?.sound, .named(fileName: "alert-doorbell.wav"))
        XCTAssertEqual(s.center.pending(for: .sensorExpired).first?.categoryIdentifier, AlertNotificationIDs.snoozableCategory)
        XCTAssertTrue(s.center.posted.isEmpty)

        // The app stays suspended through the rest of the session: iOS posts the five pending
        // notifications on time. It next runs when the sensor reports the end, 3 minutes after the
        // grace period ends.
        s.clock.advance(seconds: graceEndsAt.addingTimeInterval(180).timeIntervalSince(s.clock.now))
        await s.service.send(.tick)
        XCTAssertTrue(s.center.posted.isEmpty, "nothing posted a second time")
        await s.service.send(.sensorState(.expired))
        XCTAssertTrue(s.center.posted.isEmpty, "the 'sensor expired' notification went out at the grace end")
        XCTAssertEqual(s.audio.plays.map(\.fileName), ["alert-warble.wav"], "its sound plays now: sound on silent is on")
        XCTAssertEqual(s.service.phase(of: .sensorExpired), .firing(since: s.clock.now))
    }

    // MARK: No duplicates

    func test_anAwakeAppNeverPostsAReminderASecondTime() {
        let h = harness()
        var actions = startSession(h)
        var reportedGrace = false
        var reportedEnd = false
        let stop = graceEndsAt.addingTimeInterval(hours(1))
        while h.now < stop {
            h.clock.advance(minutes: 5)
            if h.now >= expiresAt, !reportedGrace {
                reportedGrace = true
                actions += h.send(.sensorState(.gracePeriod(endsAt: graceEndsAt.addingTimeInterval(1))))   // derived: jitters
            }
            if h.now >= graceEndsAt.addingTimeInterval(180), !reportedEnd {
                reportedEnd = true
                actions += h.send(.sensorState(.expired))
            }
            actions += h.tick()
        }
        let reminderActions = actions.reminderActions
        XCTAssertEqual(reminderActions.fired, [], "every reminder went out as its pending notification")
        XCTAssertEqual(reminderActions.ensured, reminders + [.sensorExpired],
                       "each checked once at its moment (posted only if missing); the end reported: checked again, with its sound")
        XCTAssertEqual(actions.ensuredNotice(.sensorExpiringIn12Hours)?.soundIfPresent, false)
        XCTAssertEqual(reminderActions.last.flatMap { if case .ensurePosted(_, let sound) = $0 { return sound } else { return nil } }, true)
        XCTAssertEqual(reminderActions.due, [])
        for kind in reminders {
            XCTAssertEqual(reminderActions.filter { if case .schedule(kind, _) = $0 { return true } else { return false } }.count, 1, "\(kind)")
        }
        XCTAssertFalse(reminderActions.contains { if case .cancelSlots = $0 { return true } else { return false } })
    }

    func test_M1_jitteringSessionDatesScheduleEachReminderOnce() {
        let h = harness()
        startSession(h)
        for i in 0..<12 {
            let jitter = TimeInterval(i % 3) - 1   // −1, 0, +1 s
            let state = SensorState.active(sessionStart: session.start.addingTimeInterval(jitter), expiresAt: expiresAt.addingTimeInterval(jitter))
            XCTAssertEqual(h.send(.sensorState(state)).reminderActions, [], "jitter \(jitter)")
            h.clock.advance(minutes: 5)
        }
        XCTAssertEqual(h.send(.sensorState(.active(sessionStart: session.start, expiresAt: expiresAt.addingTimeInterval(90))))
            .reminderActions, [], "90 s: still jitter")
    }

    /// Review m4: a move of more than 2 minutes within the hour is the same session at new dates.
    func test_aSessionDateThatMovesWithinTheHourRewritesThePendingReminders() {
        let h = harness()
        startSession(h)
        let moved = expiresAt.addingTimeInterval(1800)
        let actions = h.send(.sensorState(.active(sessionStart: session.start.addingTimeInterval(1800), expiresAt: moved))).reminderActions
        XCTAssertEqual(actions.scheduled(.sensorExpiringIn24Hours), [moved.addingTimeInterval(-hours(24))])
        XCTAssertEqual(actions.scheduled(.sensorExpiringIn2Hours), [moved.addingTimeInterval(-hours(2))])
        XCTAssertEqual(actions.scheduledNotices(.sensorExpiringIn2Hours)?.first?.title, "Sensor expires in 2 hours (at 10:10 PM)")
        XCTAssertEqual(actions.scheduledNotices(.sensorExpiringIn12Hours)?.first?.body,
                       "The session ends today at 10:10 PM. A 12-hour grace period follows.", "the grace end moves with it")
        XCTAssertEqual(actions.scheduled(.sensorGracePeriod), [moved])
        XCTAssertEqual(actions.scheduled(.sensorExpired), [graceEndsAt.addingTimeInterval(1800)])
        XCTAssertEqual(actions.fired, [])
        XCTAssertFalse(actions.contains { if case .cancelSlots = $0 { return true } else { return false } }, "replaced, same identifiers")
        XCTAssertEqual(h.send(.sensorState(.active(sessionStart: session.start.addingTimeInterval(1801), expiresAt: moved.addingTimeInterval(1))))
            .reminderActions, [], "then jitter around the new date")
    }

    func test_aDateMovedJustBeforeAReminderIsDueLeavesThatOneAlone() {
        let h = harness()
        startSession(h)
        moveClock(h, to: expiresAt.addingTimeInterval(-hours(2) - 30))   // the 2-hour one is due in 30 s
        let actions = h.send(.sensorState(.active(sessionStart: session.start, expiresAt: expiresAt.addingTimeInterval(600)))).reminderActions
        XCTAssertNil(actions.scheduled(.sensorExpiringIn2Hours), "due within a minute: not replaced")
        XCTAssertEqual(actions.scheduled(.sensorGracePeriod), [expiresAt.addingTimeInterval(600)])
    }

    // MARK: Session changes

    func test_aNewSensorRemovesThePreviousSessionsReminders() {
        let h = harness()
        startSession(h)
        let warmUp = h.send(.sensorState(.warmingUp(endsAt: h.now.addingTimeInterval(1800)))).reminderActions
        XCTAssertEqual(warmUp, reminders.map { .cancelSlots($0, [0]) })
        XCTAssertEqual(h.send(.sensorState(.notPaired)).reminderActions, [], "nothing left to remove")

        h.clock.advance(minutes: 30)
        let next = h.now.addingTimeInterval(10 * 86_400)
        let actions = h.send(.sensorState(.active(sessionStart: h.now.addingTimeInterval(-1800), expiresAt: next))).reminderActions
        XCTAssertEqual(actions.scheduled(.sensorExpiringIn24Hours), [next.addingTimeInterval(-hours(24))])
        XCTAssertEqual(actions.scheduled(.sensorGracePeriod), [next])
        XCTAssertNil(actions.scheduled(.sensorExpired), "its grace end comes with its first reading")
    }

    func test_otherSessionDatesReplaceThePendingReminders() {
        let h = harness()
        startSession(h)
        let other = expiresAt.addingTimeInterval(3 * 86_400)
        let actions = h.send(.sensorState(.active(sessionStart: other.addingTimeInterval(-10 * 86_400), expiresAt: other))).reminderActions
        XCTAssertEqual(Array(actions.prefix(5)), reminders.map { .cancelSlots($0, [0]) }, "the old session's, first")
        XCTAssertEqual(actions.scheduled(.sensorExpiringIn12Hours), [other.addingTimeInterval(-hours(12))])
        XCTAssertEqual(actions.fired, [])
    }

    func test_notPairedRemovesThePendingReminders() {
        let h = harness()
        startSession(h)
        XCTAssertEqual(h.send(.sensorState(.notPaired)).reminderActions, reminders.map { .cancelSlots($0, [0]) })
        XCTAssertNil(h.engine.snapshot.expiryPlan)
    }

    func test_aPhoneClockMovedBackADayDoesNotRepostPastReminders() {
        let h = harness()
        startSession(h)
        moveClock(h, to: expiresAt.addingTimeInterval(-hours(20)))
        h.tick()   // the 24-hour reminder went out
        h.clock.advance(seconds: -86_400)
        let shifted = expiresAt.addingTimeInterval(-86_400)
        let actions = h.send(.sensorState(.active(sessionStart: session.start.addingTimeInterval(-86_400), expiresAt: shifted))).reminderActions
        XCTAssertEqual(actions.fired, [], "the dates moved with the clock: still the same sensor, the 24-hour reminder is not repeated")
        XCTAssertEqual(actions.scheduled(.sensorExpiringIn12Hours), [shifted.addingTimeInterval(-hours(12))])
    }

    // MARK: Switching reminders

    func test_turningOneReminderOffRemovesOnlyItsNotification() {
        let h = harness()
        startSession(h)
        for kind in reminders {
            XCTAssertEqual(h.settings { $0.setEnabled(false, for: kind) }.reminderActions, [.cancelSlots(kind, [0])], "\(kind)")
            XCTAssertEqual(h.phase(kind), .off)
            let on = h.settings { $0.setEnabled(true, for: kind) }.reminderActions
            XCTAssertEqual(on.count, 1, "\(kind)")
            XCTAssertNotNil(on.scheduled(kind), "\(kind) pending again")
        }
    }

    func test_aReminderTurnedOnWhileItIsCurrentIsPostedThen() {
        var settings = AlertSettings.defaults
        settings.setEnabled(false, for: .sensorExpiringIn24Hours)
        let h = harness(settings: settings)
        XCTAssertNil(startSession(h).scheduled(.sensorExpiringIn24Hours))
        moveClock(h, to: expiresAt.addingTimeInterval(-hours(20)))
        XCTAssertEqual(h.tick().reminderActions, [])
        let on = h.settings { $0.setEnabled(true, for: .sensorExpiringIn24Hours) }.reminderActions
        XCTAssertEqual(on.fired, [.sensorExpiringIn24Hours])
        XCTAssertEqual(on.firedNotice(.sensorExpiringIn24Hours)?.title, "Sensor expires in 20 hours", "the time actually left")
        XCTAssertEqual(on.firedNotice(.sensorExpiringIn24Hours)?.body, "The session ends today at 9:40 PM. A 12-hour grace period follows.")

        // Once the 12-hour reminder has gone out, the 24-hour one is out of date.
        let late = harness(settings: settings)
        startSession(late)
        moveClock(late, to: expiresAt.addingTimeInterval(-hours(11)))
        XCTAssertEqual(late.tick().reminderActions.ensured, [.sensorExpiringIn12Hours], "the 12-hour one came due: checked")
        XCTAssertEqual(late.settings { $0.setEnabled(true, for: .sensorExpiringIn24Hours) }.reminderActions, [])
    }

    func test_aSettingsChangeRewritesOnlyTheRemindersItChanges() {
        let h = harness()
        startSession(h)
        let sound = h.settings { $0.setSound(.tide, for: .sensorExpiringIn2Hours) }.reminderActions
        XCTAssertEqual(sound.count, 1)
        XCTAssertEqual(sound.scheduledNotices(.sensorExpiringIn2Hours)?.first?.sound, .tide)

        let audible = h.settings { $0.setPlaysSound(true, for: .sensorExpiringIn24Hours) }.reminderActions
        XCTAssertEqual(audible.count, 1)
        XCTAssertEqual(audible.scheduledNotices(.sensorExpiringIn24Hours)?.first?.playsSound, true)

        // Quiet hours 21:00–23:00 cover the 24-hour reminder (21:40) and the grace start (21:40).
        let quiet = h.settings { $0.quietHours = QuietHours(isEnabled: true, startMinuteOfDay: 21 * 60, endMinuteOfDay: 23 * 60) }.reminderActions
        let silenced: [AlertKind] = quiet.compactMap { action -> AlertKind? in
            guard case .schedule(let kind, let notices) = action, notices.first?.isSilenced == true else { return nil }
            return kind
        }
        XCTAssertEqual(silenced, [.sensorExpiringIn24Hours, .sensorGracePeriod])
        XCTAssertEqual(quiet.count, 2)

        // Unchanged settings (the service re-sends them when the delivery level changes): all.
        XCTAssertEqual(h.settings { _ in }.reminderActions.count, 5)
    }

    func test_openingAnAnnouncementKeepsItsReminderPendingForLater() {
        let h = harness()
        startSession(h)
        let actions = h.user(.acknowledge(.sensorExpiringIn12Hours)).reminderActions
        XCTAssertEqual(actions, [.dismiss(.sensorExpiringIn12Hours)], "the shown notification only: the pending one stays")
        XCTAssertEqual(h.user(.acknowledge(.sensorWarmUpComplete)).first, .dismiss(.sensorWarmUpComplete))
    }

    // MARK: Learned late

    func test_aSessionLearnedLatePostsOnlyTheCurrentReminderWithTheTimeLeft() {
        let h = harness()
        moveClock(h, to: expiresAt.addingTimeInterval(-(hours(1) + minutes(15))))
        let actions = startSession(h).reminderActions
        XCTAssertEqual(actions.fired, [.sensorExpiringIn2Hours], "not the 24- and 12-hour ones: out of date")
        XCTAssertEqual(actions.firedNotice(.sensorExpiringIn2Hours)?.title, "Sensor expires in 1 h 15 min (at 9:40 PM)")
        XCTAssertEqual(actions.firedNotice(.sensorExpiringIn2Hours)?.body, "Plan a sensor change. A 12-hour grace period follows.")
        XCTAssertNil(actions.scheduled(.sensorExpiringIn24Hours))
        XCTAssertNil(actions.scheduled(.sensorExpiringIn12Hours))
        XCTAssertEqual(actions.scheduled(.sensorGracePeriod), [expiresAt])
        XCTAssertEqual(actions.scheduled(.sensorExpired), [graceEndsAt])
        XCTAssertEqual(h.tick().reminderActions, [])
    }

    func test_aGracePeriodReportedWithoutASessionIsPostedOnceWithTheTimeLeft() {
        let h = harness()
        moveClock(h, to: graceEndsAt.addingTimeInterval(-(hours(9) + minutes(20))))
        let grace = h.send(.sensorState(.gracePeriod(endsAt: graceEndsAt))).reminderActions
        XCTAssertEqual(grace.fired, [.sensorGracePeriod])
        XCTAssertEqual(grace.firedNotice(.sensorGracePeriod)?.title, "Sensor session ended — 9 h 20 min of grace period left")
        XCTAssertEqual(grace.firedNotice(.sensorGracePeriod)?.body, "Readings stop at 9:40 AM today. Replace the sensor before then.")
        XCTAssertEqual(grace.scheduled(.sensorExpired), [graceEndsAt])
        XCTAssertEqual(h.send(.sensorState(.gracePeriod(endsAt: graceEndsAt.addingTimeInterval(1)))).reminderActions, [], "once")
        h.clock.advance(minutes: 5)
        XCTAssertEqual(h.mgdl(110).reminderActions, [], "the reading's session adds the expiry: nothing more to post")
    }

    func test_anUpdateInstalledMidSessionDoesNotRepeatAnAnnouncementMadeBeforeIt() {
        var snapshot = AlertEngineSnapshot(start: Fixtures.t0)
        snapshot.settledSensorState = active
        let now = expiresAt.addingTimeInterval(-hours(1))
        var fresh = AlertEngine(settings: .defaults, configuration: Fixtures.configuration, restoring: snapshot, now: now)
        XCTAssertEqual(fresh.handle(.launched, at: now).reminderActions.fired, [.sensorExpiringIn2Hours], "without a memory: posted late")

        snapshot.announcedSessionDates = [AlertKind.sensorExpiringIn24Hours.rawValue: expiresAt, AlertKind.sensorExpiringIn2Hours.rawValue: expiresAt]
        var upgraded = AlertEngine(settings: .defaults, configuration: Fixtures.configuration, restoring: snapshot, now: now)
        let actions = upgraded.handle(.launched, at: now).reminderActions
        XCTAssertEqual(actions.fired, [], "announced by the previous build")
        XCTAssertEqual(actions.scheduled(.sensorGracePeriod), [expiresAt])
    }

    // MARK: Sensor expired

    func test_anEndReportedBeforeTheReminderIsDueReplacesIt() {
        let h = harness()
        startSession(h)
        moveClock(h, to: expiresAt.addingTimeInterval(hours(1)))
        h.send(.sensorState(.gracePeriod(endsAt: graceEndsAt)))
        let end = h.send(.sensorState(.expired)).reminderActions
        XCTAssertEqual(end.first, .cancelSlots(.sensorExpired, [0]))
        XCTAssertEqual(end.fired, [.sensorExpired])
        XCTAssertEqual(h.tick().reminderActions, [])
    }

    func test_anEndReportedJustBeforeTheReminderIsDueOnlySounds() {
        let h = harness()
        startSession(h)
        moveClock(h, to: graceEndsAt.addingTimeInterval(-30))
        let end = h.send(.sensorState(.expired)).reminderActions
        XCTAssertEqual(end.ensuredNotice(.sensorExpired)?.soundIfPresent, true, "the pending one goes out in 30 s: not removed, not posted twice")
        XCTAssertEqual(end.fired, [])
        XCTAssertFalse(end.contains(.cancelSlots(.sensorExpired, [0])))
    }

    func test_theSensorExpiredAlertKeepsItsReAlertsAfterTheReminder() {
        let h = harness()
        startSession(h)
        moveClock(h, to: graceEndsAt.addingTimeInterval(120))
        XCTAssertEqual(h.send(.sensorState(.expired)).reminderActions.ensured, [.sensorExpired])
        XCTAssertEqual(h.advance(minutes: 119).fired, [])
        XCTAssertEqual(h.advance(minutes: 1).fired, [.sensorExpired], "re-alerts every 120 minutes, as before")
    }

    /// D41: a brief end report clears when the session is reported running again. The cancel removes
    /// the delivered notification, so the next end report posts again.
    func test_anEndReportedAgainAfterABriefOneIsPostedAgain() {
        let h = harness()
        startSession(h)
        moveClock(h, to: graceEndsAt.addingTimeInterval(120))
        XCTAssertEqual(h.send(.sensorState(.expired)).reminderActions.ensured, [.sensorExpired])
        XCTAssertEqual(h.send(.sensorState(.gracePeriod(endsAt: graceEndsAt))).reminderActions, [.cancel(.sensorExpired)])
        let again = h.send(.sensorState(.expired)).reminderActions
        XCTAssertEqual(again.fired, [.sensorExpired])
        XCTAssertEqual(again.ensured, [])
    }

    func test_turningTheSensorExpiredAlertOnAfterAnEarlyEndDoesNotScheduleItAgain() {
        var settings = AlertSettings.defaults
        settings.setEnabled(false, for: .sensorExpired)
        let h = harness(settings: settings)
        XCTAssertNil(startSession(h).scheduled(.sensorExpired))
        moveClock(h, to: expiresAt.addingTimeInterval(hours(1)))
        h.send(.sensorState(.expired))
        let on = h.settings { $0.setEnabled(true, for: .sensorExpired) }.reminderActions
        XCTAssertEqual(on.fired, [.sensorExpired], "posted now, by the alert")
        XCTAssertNil(on.scheduled(.sensorExpired), "and not pending again for the grace end")
    }

    // MARK: Session identity

    func test_aGraceEndReportedByTheGraceStateCompletesAPlanThatHadOnlyTheExpiry() {
        let h = harness()
        h.send(.sensorState(active))   // no reading: the grace end is unknown
        moveClock(h, to: expiresAt.addingTimeInterval(60))
        let grace = h.send(.sensorState(.gracePeriod(endsAt: graceEndsAt))).reminderActions
        XCTAssertEqual(grace.fired, [], "the grace start went out as its pending notification")
        XCTAssertEqual(grace.scheduled(.sensorExpired), [graceEndsAt])
    }

    func test_sessionIdentity() {
        let tolerance = AlertEngine.sameSessionTolerance
        let both = ExpiryReminderPlan(expiresAt: expiresAt, graceEndsAt: graceEndsAt)
        XCTAssertTrue(both.isSameSession(expiresAt: expiresAt.addingTimeInterval(tolerance - 1), graceEndsAt: nil))
        XCTAssertFalse(both.isSameSession(expiresAt: expiresAt.addingTimeInterval(tolerance), graceEndsAt: graceEndsAt))
        XCTAssertTrue(both.isSameSession(expiresAt: nil, graceEndsAt: graceEndsAt.addingTimeInterval(-1)))
        let expiryOnly = ExpiryReminderPlan(expiresAt: expiresAt, graceEndsAt: nil)
        XCTAssertTrue(expiryOnly.isSameSession(expiresAt: nil, graceEndsAt: graceEndsAt), "a grace end within a day after the expiry")
        XCTAssertFalse(expiryOnly.isSameSession(expiresAt: nil, graceEndsAt: expiresAt.addingTimeInterval(10 * 86_400)), "a new sensor")
        let graceOnly = ExpiryReminderPlan(expiresAt: nil, graceEndsAt: graceEndsAt)
        XCTAssertTrue(graceOnly.isSameSession(expiresAt: expiresAt, graceEndsAt: nil))
        XCTAssertFalse(graceOnly.isSameSession(expiresAt: expiresAt.addingTimeInterval(3 * 86_400), graceEndsAt: nil))
        XCTAssertFalse(ExpiryReminderPlan().isSameSession(expiresAt: nil, graceEndsAt: nil))
        XCTAssertNil(both.date(of: .low), "not a reminder")
    }

    // MARK: Relaunch

    func test_aRelaunchWritesThePendingRemindersAgain() throws {
        let h = harness()
        startSession(h)
        h.settings { $0.setEnabled(false, for: .sensorExpiringIn12Hours) }
        let stored = try XCTUnwrap(AlertEngineSnapshot.decode(h.engine.snapshot.encoded()))
        XCTAssertEqual(stored.expiryPlan, h.engine.snapshot.expiryPlan)
        var engine = AlertEngine(settings: h.engine.settings, configuration: Fixtures.configuration, restoring: stored, now: h.now)
        let actions = engine.handle(.launched, at: h.now).reminderActions
        for kind in reminders where kind != .sensorExpiringIn12Hours {
            XCTAssertNotNil(actions.scheduled(kind), "\(kind)")
        }
        XCTAssertNil(actions.scheduled(.sensorExpiringIn12Hours))
        XCTAssertTrue(actions.contains(.cancelSlots(.sensorExpiringIn12Hours, [0])), "whatever the previous process left")
    }
}

extension Array where Element == AlertAction {
    /// `.ensurePosted` kinds (D43 review B1), in order.
    var ensured: [AlertKind] {
        compactMap { if case .ensurePosted(let n, _) = $0 { return n.kind } else { return nil } }
    }

    func ensuredNotice(_ kind: AlertKind) -> (notice: AlertNotice, soundIfPresent: Bool)? {
        for case .ensurePosted(let n, let sound) in self where n.kind == kind { return (n, sound) }
        return nil
    }

    /// Only the actions about the expiry reminders (D43).
    var reminderActions: [AlertAction] {
        let kinds = AlertKind.sensorExpiryReminders
        return filter { action in
            switch action {
            case .fire(let n), .playDueAlert(let n), .ensurePosted(let n, _): return kinds.contains(n.kind)
            case .schedule(let k, _), .cancelSlots(let k, _), .cancelScheduled(let k), .cancel(let k), .stopSound(let k), .dismiss(let k):
                return kinds.contains(k)
            default: return false
            }
        }
    }
}
