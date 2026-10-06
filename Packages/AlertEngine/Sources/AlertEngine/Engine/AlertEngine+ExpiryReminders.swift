// Sensor expiry reminders (D43): 24 h, 12 h and 2 h before the session ends, when it ends (the grace
// period starts), and when the grace period ends (sensor expired).
//
// Nothing wakes the app at those moments (the G7 wakes it every 5 minutes, on its own schedule), so
// each reminder is a pending notification, scheduled as soon as the session's dates are known:
// the expiry from `.active(_, expiresAt:)`, the grace period's end from the session readings arrive
// with or from `.gracePeriod(endsAt:)`. The engine never posts a reminder a second time:
//
//   • One pending notification per reminder and session (slot 0 of its kind; slot 1 for a DEBUG
//     replay engine, so it never touches the real ones). Once its time has passed it counts as
//     delivered: iOS posted it, whether or not the app was running.
//   • Never trusted blindly (D43 review B1). An add the system refuses (notifications not allowed
//     yet) is reported back by the service (`.notificationsNotScheduled`) and marked so; it is added
//     again at the next notification-authorization change, `.foreground`, launch or settings change,
//     and posted at once if its moment comes first. When the current reminder's moment is reached
//     while the app runs, the delivery layer checks the notification is there (delivered or
//     pending) and posts it if not (`.ensurePosted`).
//   • A reminder whose time passed with nothing pending (the session became known late, or the
//     reminder was just turned on) is posted at once, written for the time actually left — only the
//     latest one that has passed; earlier ones are out of date and are skipped. The last reminder
//     (sensor expired) is never posted late from here: the sensor-expired alert fires on the state.
//   • The plan belongs to one session. Dates within an hour of the plan's are the same session
//     (they are derived from the phone clock at each connection and jitter, review M1); a move of
//     more than 2 minutes within that hour is adopted and the pending reminders are rewritten.
//     Another session, a new sensor warming up, no sensor, or a sensor that must be replaced (D36)
//     removes the pending reminders. A plan that replaces another one (in practice the same sensor
//     seen through a phone clock moved by more than an hour; a new sensor goes through warm-up) skips
//     reminders already past instead of posting them late.
//   • Turning a reminder off removes its pending notification and nothing else; turning it on
//     schedules it, or posts it if it is the current one. A settings change rebuilds only the pending
//     reminders it changes (all of them when the settings are re-sent unchanged, which the service
//     does when the delivery level or the notification authorization changed).
//   • Sensor expired: when the sensor reports the end, the alert's first notification is the
//     reminder pending (or already posted) for the end of the grace period: the delivery layer
//     checks it is there (posts it if not) and plays its sound. An end reported before that reminder
//     is due cancels it and posts now; if that end report was brief and the grace period resumes,
//     the reminder is scheduled again for the real end. Re-alerts and D41 are unchanged.
//   • A pending reminder due within `protectedLeadTime` is never removed or replaced.

import Foundation
import GlucoseCore

/// Where one expiry reminder stands for the current session.
enum ExpiryReminderStatus: Sendable, Equatable, Codable {
    /// A notification is pending for this date.
    case pending(Date)
    /// The system refused the pending notification for this date (D43 review B1). Not retried by
    /// itself: added again at the next authorization change, foreground, launch or settings change,
    /// or posted when its moment is reached.
    case notScheduled(Date)
    /// Went out at this date: the pending notification came due, or the engine posted it then.
    case delivered(Date)
    /// Nothing more this session: skipped as out of date, or taken over by the sensor-expired alert.
    case finished
}

/// The current session's expiry reminders.
struct ExpiryReminderPlan: Sendable, Equatable, Codable {
    /// End of the rated life; `nil` if only the grace period's end is known.
    var expiresAt: Date?
    /// End of the grace period; `nil` until a reading's session or the grace state reports it.
    var graceEndsAt: Date?
    /// `AlertKind.rawValue` → status. No entry: nothing pending (turned off, or its date unknown).
    var reminders: [String: ExpiryReminderStatus] = [:]

    /// A grace period ending this long after an expiry still belongs to that session (G7: 12 h).
    static let maximumGracePeriod: TimeInterval = 24 * 3600
    /// Same-session dates that moved by more than this are adopted (D43 review m4); less is jitter.
    static let dateMoveThreshold: TimeInterval = 120

    subscript(kind: AlertKind) -> ExpiryReminderStatus? {
        get { reminders[kind.rawValue] }
        set { reminders[kind.rawValue] = newValue }
    }

    /// When `kind`'s reminder is due, if the date it depends on is known.
    func date(of kind: AlertKind) -> Date? {
        switch kind {
        case .sensorExpiringIn24Hours: return expiresAt?.addingTimeInterval(-24 * 3600)
        case .sensorExpiringIn12Hours: return expiresAt?.addingTimeInterval(-12 * 3600)
        case .sensorExpiringIn2Hours: return expiresAt?.addingTimeInterval(-2 * 3600)
        case .sensorGracePeriod: return expiresAt
        case .sensorExpired: return graceEndsAt
        default: return nil
        }
    }

    /// Whether `kind`'s time has come. Only the grace state reports a grace end without the expiry,
    /// so then every reminder up to the start of the grace period has passed.
    func hasPassed(_ kind: AlertKind, now: Date) -> Bool {
        if let date = date(of: kind) { return date <= now }
        return kind != .sensorExpired && expiresAt == nil && graceEndsAt != nil
    }

    func isSameSession(expiresAt e: Date?, graceEndsAt g: Date?) -> Bool {
        let tolerance = AlertEngine.sameSessionTolerance
        func close(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < tolerance }
        func follows(_ graceEnd: Date, _ expiry: Date) -> Bool {
            let gap = graceEnd.timeIntervalSince(expiry)
            return gap > -tolerance && gap < Self.maximumGracePeriod
        }
        if let a = expiresAt, let b = e { return close(a, b) }
        if let a = graceEndsAt, let b = g { return close(a, b) }
        if let a = expiresAt, let b = g { return follows(b, a) }
        if let a = graceEndsAt, let b = e { return follows(a, b) }
        return false
    }

    /// Adopts the same session's dates: fills in what is missing and takes a date that moved by more
    /// than `dateMoveThreshold`. Returns whether the pending reminders must be written again: a date
    /// moved, or the grace end became known (the texts state its length). An expiry learned after
    /// the grace end changes nothing pending: every reminder before the grace end has passed.
    mutating func adopt(expiresAt e: Date?, graceEndsAt g: Date?) -> Bool {
        func moved(_ old: Date?, _ new: Date?) -> Bool {
            guard let old, let new else { return false }
            return abs(new.timeIntervalSince(old)) > Self.dateMoveThreshold
        }
        let rewrite = moved(expiresAt, e) || moved(graceEndsAt, g) || (graceEndsAt == nil && g != nil)
        if expiresAt == nil || moved(expiresAt, e) { expiresAt = e ?? expiresAt }
        if graceEndsAt == nil || moved(graceEndsAt, g) { graceEndsAt = g ?? graceEndsAt }
        return rewrite
    }
}

extension AlertEngine {
    /// The pending notification slot of every expiry reminder.
    static let expiryReminderSlot = 0
    /// A DEBUG replay engine's slot (D43 review m3), so it never replaces or removes the real ones.
    static let replayExpiryReminderSlot = 1

    var reminderSlot: Int {
        #if DEBUG
        if configuration.acceptsReplayReadings { return Self.replayExpiryReminderSlot }
        #endif
        return Self.expiryReminderSlot
    }

    /// Runs on every input, after the condition alerts.
    mutating func planExpiryReminders(now: Date) -> [AlertAction] {
        var actions: [AlertAction] = []
        switch snapshot.settledSensorState {
        case .notPaired, .warmingUp:
            // No sensor, or a new one: the previous session's reminders are void.
            return dropExpiryPlan(now: now)
        case .failed(let failure) where failure.requiresSensorReplacement:
            // The sensor is finished (D36; review M1). Should it report running again, the plan is
            // rebuilt and the current reminder posted.
            return dropExpiryPlan(now: now)
        case .active, .gracePeriod:
            if let dates = runningSessionDates() {
                actions += adoptSession(expiresAt: dates.expiresAt, graceEndsAt: dates.graceEndsAt, now: now)
            }
        default:
            // Expired, a pairing problem, an unclassified failure, error, calibration, or nothing
            // settled yet: keep the plan.
            break
        }
        guard var plan = snapshot.expiryPlan else { return actions }
        let kinds = AlertKind.sensorExpiryReminders
        let passed = kinds.filter { plan.hasPassed($0, now: now) }
        let latest = passed.last

        // Pending reminders whose time has come went out, app running or not. The current one is
        // checked by the delivery layer and posted if it is not there.
        for kind in kinds {
            guard case .pending(let date)? = plan[kind], date <= now else { continue }
            plan[kind] = .delivered(date)
            if kind == latest, settings.isEnabled(kind) {
                actions.append(.ensurePosted(makeNotice(kind, fireDate: nil, now: now, slot: reminderSlot), soundIfPresent: false))
            }
        }

        if let latest {
            for kind in passed.dropLast() {
                switch plan[kind] {
                case nil, .notScheduled?: plan[kind] = .finished
                default: break
                }
            }
            switch plan[latest] {
            case nil where latest == .sensorExpired:
                plan[latest] = .finished
            case nil, .notScheduled?:
                if settings.isEnabled(latest) {
                    // Never pending, or refused by the system: post it now.
                    plan[latest] = .delivered(now)
                    actions.append(.fire(makeNotice(latest, fireDate: nil, now: now, slot: reminderSlot)))
                } else {
                    // Turned off: left open, so turning it on while it is still current posts it.
                    plan[latest] = nil
                }
            default:
                break
            }
        }

        for kind in kinds where !plan.hasPassed(kind, now: now) {
            guard let date = plan.date(of: kind) else { continue }
            let enabled = settings.isEnabled(kind)
            switch plan[kind] {
            case nil where enabled:
                plan[kind] = .pending(date)
                actions.append(.schedule(kind, [expiryReminderNotice(kind, at: date, now: now)]))
            case .pending(let pendingDate)? where !enabled && pendingDate > Self.protectedUntil(now):
                plan[kind] = nil
                actions.append(.cancelSlots(kind, [reminderSlot]))
            case .notScheduled? where !enabled:
                plan[kind] = nil
            case .finished? where kind == .sensorExpired && enabled && episode(kind) == .armed
                && snapshot.settledSensorState.map(Self.isRunning) == true && date > Self.protectedUntil(now):
                // A brief early end report cleared (review m5): the real end needs its notification.
                plan[kind] = .pending(date)
                actions.append(.schedule(kind, [expiryReminderNotice(kind, at: date, now: now)]))
            default:
                break
            }
        }
        snapshot.expiryPlan = plan
        return actions
    }

    /// The sensor reported the end (D43): the first notification of the sensor-expired alert is the
    /// reminder pending (or posted) for the end of the grace period, if there is one.
    mutating func fireSensorExpired(now: Date) -> [AlertAction] {
        let kind = AlertKind.sensorExpired
        setEpisode(kind, .firing(AlertFiring(since: now, lastSoundedAt: now)))
        guard var plan = snapshot.expiryPlan else {
            return [.fire(makeNotice(kind, fireDate: nil, now: now))]
        }
        let status = plan[kind]
        // Whatever it was, the reminder is this alert's from now on: never scheduled again this session.
        plan[kind] = .finished
        snapshot.expiryPlan = plan
        switch status {
        case .pending(let date)? where date > Self.protectedUntil(now):
            // The end came before the reminder: remove it and post now.
            return [.cancelSlots(kind, [reminderSlot]), .fire(makeNotice(kind, fireDate: nil, now: now))]
        case .pending?, .delivered?:
            // Posted (or about to be) by iOS if its add went through: the delivery layer checks, posts
            // it now if it is missing (review B1), and plays the sound. Written, and quiet hours
            // decided, for now (review m1).
            return [.ensurePosted(makeNotice(kind, fireDate: nil, now: now, slot: reminderSlot), soundIfPresent: true)]
        case .notScheduled?, .finished?, nil:
            return [.fire(makeNotice(kind, fireDate: nil, now: now))]
        }
    }

    /// Writes pending reminders due later than the protected window again (same identifier, so each
    /// replaces the old one), at the plan's current dates, and adds those the system refused. With
    /// `previous`, only those whose notification would change (and the refused ones).
    mutating func rebuildPendingExpiryReminders(
        now: Date, kinds: [AlertKind] = AlertKind.sensorExpiryReminders, unlessUnchangedFrom previous: [AlertKind: AlertNotice]? = nil
    ) -> [AlertAction] {
        guard var plan = snapshot.expiryPlan else { return [] }
        var actions: [AlertAction] = []
        for kind in kinds where settings.isEnabled(kind) {
            let scheduledDate: Date
            switch plan[kind] {
            case .pending(let date)?, .notScheduled(let date)?: scheduledDate = date
            default: continue
            }
            guard scheduledDate > Self.protectedUntil(now) else { continue }
            guard let date = plan.date(of: kind), date > now else {
                // Its date moved into the past: the planner posts it if it is the current one.
                plan[kind] = nil
                actions.append(.cancelSlots(kind, [reminderSlot]))
                continue
            }
            let notice = expiryReminderNotice(kind, at: date, now: now)
            if plan[kind] == .pending(date), let previous, previous[kind] == notice { continue }
            plan[kind] = .pending(date)
            actions.append(.schedule(kind, [notice]))
        }
        snapshot.expiryPlan = plan
        return actions
    }

    /// The pending reminders' notifications as the current settings build them.
    func pendingExpiryReminderNotices(now: Date) -> [AlertKind: AlertNotice] {
        guard let plan = snapshot.expiryPlan else { return [:] }
        var notices: [AlertKind: AlertNotice] = [:]
        for kind in AlertKind.sensorExpiryReminders {
            if case .pending(let date)? = plan[kind] { notices[kind] = expiryReminderNotice(kind, at: date, now: now) }
        }
        return notices
    }

    /// After a relaunch: the previous process may have died between deciding and acting. Writes every
    /// pending reminder again and removes whatever else may be left in the reminder slots — anything
    /// not pending beyond the protected window (review m2).
    mutating func reconcileExpiryRemindersAfterLaunch(now: Date) -> [AlertAction] {
        var actions = rebuildPendingExpiryReminders(now: now)
        for kind in AlertKind.sensorExpiryReminders {
            if case .pending? = snapshot.expiryPlan?[kind] { continue }
            actions.append(.cancelSlots(kind, [reminderSlot]))
        }
        return actions
    }

    /// The delivery layer could not add these pending notifications (review B1).
    mutating func noteNotScheduled(_ notices: [AlertNotice]) {
        guard var plan = snapshot.expiryPlan else { return }
        for notice in notices where AlertKind.sensorExpiryReminders.contains(notice.kind) && notice.slot == reminderSlot {
            if let date = notice.fireDate, plan[notice.kind] == .pending(date) {
                plan[notice.kind] = .notScheduled(date)
            }
        }
        snapshot.expiryPlan = plan
    }

    /// The user opened or dismissed a reminder: one whose notification just came due went out.
    mutating func noteReminderSeen(_ kind: AlertKind, now: Date) {
        guard var plan = snapshot.expiryPlan, case .pending(let date)? = plan[kind], date <= Self.protectedUntil(now) else { return }
        plan[kind] = .delivered(date)
        snapshot.expiryPlan = plan
    }

    private func expiryReminderNotice(_ kind: AlertKind, at date: Date, now: Date) -> AlertNotice {
        makeNotice(kind, fireDate: date, now: now, slot: reminderSlot)
    }

    /// The running session's dates: the expiry from the active state or the grace end from the grace
    /// state, and the other one from the session readings arrive with, if it is the same session.
    private func runningSessionDates() -> (expiresAt: Date?, graceEndsAt: Date?)? {
        let tolerance = Self.sameSessionTolerance
        let known = snapshot.knownSession
        switch snapshot.settledSensorState {
        case .active(_, let expiresAt):
            let graceEnd = known.flatMap { abs($0.expiresAt.timeIntervalSince(expiresAt)) < tolerance ? $0.gracePeriodEndsAt : nil }
            return (expiresAt, graceEnd)
        case .gracePeriod(let endsAt):
            let expiry = known.flatMap { abs($0.gracePeriodEndsAt.timeIntervalSince(endsAt)) < tolerance ? $0.expiresAt : nil }
            return (expiry, endsAt)
        default:
            return nil
        }
    }

    private mutating func adoptSession(expiresAt: Date?, graceEndsAt: Date?, now: Date) -> [AlertAction] {
        if var plan = snapshot.expiryPlan, plan.isSameSession(expiresAt: expiresAt, graceEndsAt: graceEndsAt) {
            // Fill in what was missing; take a date that moved by more than 2 minutes (jitter is
            // seconds). The pending texts and dates then change: write them again.
            let changed = plan.adopt(expiresAt: expiresAt, graceEndsAt: graceEndsAt)
            snapshot.expiryPlan = plan
            return changed ? rebuildPendingExpiryReminders(now: now) : []
        }
        let replacing = snapshot.expiryPlan != nil
        let actions = dropExpiryPlan(now: now)
        var plan = ExpiryReminderPlan(expiresAt: expiresAt, graceEndsAt: graceEndsAt)
        for kind in AlertKind.sensorExpiryReminders where plan.hasPassed(kind, now: now) {
            if replacing || announcedBeforeD43(kind, plan) { plan[kind] = .finished }
        }
        snapshot.expiryPlan = plan
        return actions
    }

    /// Removes the plan and its pending notifications (but not one due within the protected window).
    private mutating func dropExpiryPlan(now: Date) -> [AlertAction] {
        guard let plan = snapshot.expiryPlan else { return [] }
        snapshot.expiryPlan = nil
        return AlertKind.sensorExpiryReminders.compactMap { kind in
            guard case .pending(let date)? = plan[kind], date > Self.protectedUntil(now) else { return nil }
            return .cancelSlots(kind, [reminderSlot])
        }
    }

    /// An update installed mid-session: the engine before D43 announced 24 h, 2 h and the grace
    /// period itself and remembered the session date (expiry, or grace end). Not posted again.
    private func announcedBeforeD43(_ kind: AlertKind, _ plan: ExpiryReminderPlan) -> Bool {
        guard let announced = snapshot.announcedSessionDates[kind.rawValue],
              let sessionDate = kind == .sensorGracePeriod ? plan.graceEndsAt : plan.expiresAt else { return false }
        return abs(announced.timeIntervalSince(sessionDate)) < Self.sameSessionTolerance
    }
}
