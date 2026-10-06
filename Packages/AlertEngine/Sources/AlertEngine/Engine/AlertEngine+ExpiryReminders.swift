// Sensor expiry reminders (D43): 24 h, 12 h and 2 h before the session ends, when it ends (the grace
// period starts), and when the grace period ends (sensor expired).
//
// Nothing wakes the app at those moments (the G7 wakes it every 5 minutes, on its own schedule), so
// each reminder is a pending notification, scheduled as soon as the session's dates are known:
// the expiry from `.active(_, expiresAt:)`, the grace period's end from the session readings arrive
// with or from `.gracePeriod(endsAt:)`. The engine never posts a reminder a second time:
//
//   • One pending notification per reminder and session (slot 0 of its kind). Once its time has
//     passed it counts as delivered: iOS posted it, whether or not the app was running.
//   • A reminder whose time passed with nothing pending (the session became known late, or the
//     reminder was just turned on) is posted at once, written for the time actually left — only the
//     latest one that has passed; earlier ones are out of date and are skipped. The last reminder
//     (sensor expired) is never posted late from here: the sensor-expired alert fires on the state.
//   • The plan belongs to one session. Dates within an hour of the plan's are the same session
//     (they are derived from the phone clock at each connection and jitter, review M1). Another
//     session, a new sensor warming up, or no sensor removes the pending reminders. A plan that
//     replaces another one (in practice the same sensor seen through a phone clock moved by more than
//     an hour; a new sensor goes through warm-up) skips reminders already past instead of posting
//     them late.
//   • Turning a reminder off removes its pending notification and nothing else; turning it on
//     schedules it, or posts it if it is the current one. A settings change rebuilds only the pending
//     reminders it changes (all of them when the settings are re-sent unchanged, which the service
//     does when the delivery level changed).
//   • Sensor expired: when the sensor reports the end, the alert's first notification is the
//     reminder pending (or already posted) for the end of the grace period, so the engine only plays
//     its sound (`playDueAlert`). An end reported before that reminder is due cancels it and posts
//     now. Re-alerts and D41 are unchanged.
//   • A pending reminder due within `protectedLeadTime` is never removed or replaced.

import Foundation
import GlucoseCore

/// Where one expiry reminder stands for the current session.
enum ExpiryReminderStatus: Sendable, Equatable, Codable {
    /// A notification is pending for this date.
    case pending(Date)
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
}

extension AlertEngine {
    /// Every expiry reminder is the pending notification in this slot of its kind.
    static let expiryReminderSlot = 0

    /// Runs on every input, after the condition alerts.
    mutating func planExpiryReminders(now: Date) -> [AlertAction] {
        var actions: [AlertAction] = []
        switch snapshot.settledSensorState {
        case .notPaired, .warmingUp:
            // No sensor, or a new one: the previous session's reminders are void.
            return dropExpiryPlan(now: now)
        case .active, .gracePeriod:
            if let dates = runningSessionDates() {
                actions += adoptSession(expiresAt: dates.expiresAt, graceEndsAt: dates.graceEndsAt, now: now)
            }
        default:
            // Expired, failed, error, calibration, or nothing settled yet: keep the plan.
            break
        }
        guard var plan = snapshot.expiryPlan else { return actions }
        let kinds = AlertKind.sensorExpiryReminders

        for kind in kinds {
            if case .pending(let date) = plan[kind], date <= now { plan[kind] = .delivered(date) }
        }

        let passed = kinds.filter { plan.hasPassed($0, now: now) }
        if let latest = passed.last {
            for kind in passed.dropLast() where plan[kind] == nil {
                plan[kind] = .finished
            }
            if plan[latest] == nil {
                if latest == .sensorExpired {
                    plan[latest] = .finished
                } else if settings.isEnabled(latest) {
                    plan[latest] = .delivered(now)
                    actions.append(.fire(makeNotice(latest, fireDate: nil, now: now)))
                }
                // Turned off: left open, so turning it on while it is still current posts it.
            }
        }

        for kind in kinds where !plan.hasPassed(kind, now: now) {
            guard let date = plan.date(of: kind) else { continue }
            switch plan[kind] {
            case nil where settings.isEnabled(kind):
                plan[kind] = .pending(date)
                actions.append(.schedule(kind, [expiryReminderNotice(kind, at: date, now: now)]))
            case .pending(let pendingDate) where !settings.isEnabled(kind) && pendingDate > Self.protectedUntil(now):
                plan[kind] = nil
                actions.append(.cancelSlots(kind, [Self.expiryReminderSlot]))
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
        case .pending(let date)? where date <= Self.protectedUntil(now), .delivered(let date)?:
            // Posted (or about to be) by iOS: one notification, so only its sound now.
            return [.playDueAlert(makeNotice(kind, fireDate: date, now: now, slot: Self.expiryReminderSlot))]
        case .pending?:
            // The end came before the reminder: remove it and post now.
            return [.cancelSlots(kind, [Self.expiryReminderSlot]), .fire(makeNotice(kind, fireDate: nil, now: now))]
        case .finished?, nil:
            return [.fire(makeNotice(kind, fireDate: nil, now: now))]
        }
    }

    /// Writes pending reminders due later than the protected window again (same identifier, so each
    /// replaces the old one). With `previous`, only those whose notification would change.
    mutating func rebuildPendingExpiryReminders(
        now: Date, kinds: [AlertKind] = AlertKind.sensorExpiryReminders, unlessUnchangedFrom previous: [AlertKind: AlertNotice]? = nil
    ) -> [AlertAction] {
        guard let plan = snapshot.expiryPlan else { return [] }
        var actions: [AlertAction] = []
        for kind in kinds {
            guard case .pending(let date) = plan[kind], date > Self.protectedUntil(now), settings.isEnabled(kind) else { continue }
            let notice = expiryReminderNotice(kind, at: date, now: now)
            if let previous, previous[kind] == notice { continue }
            actions.append(.schedule(kind, [notice]))
        }
        return actions
    }

    /// The pending reminders' notifications as the current settings build them.
    func pendingExpiryReminderNotices(now: Date) -> [AlertKind: AlertNotice] {
        guard let plan = snapshot.expiryPlan else { return [:] }
        var notices: [AlertKind: AlertNotice] = [:]
        for kind in AlertKind.sensorExpiryReminders {
            if case .pending(let date) = plan[kind] { notices[kind] = expiryReminderNotice(kind, at: date, now: now) }
        }
        return notices
    }

    /// After a relaunch: the previous process may have died between deciding and acting. Writes every
    /// pending reminder again and removes any the plan does not hold.
    mutating func reconcileExpiryRemindersAfterLaunch(now: Date) -> [AlertAction] {
        var actions = rebuildPendingExpiryReminders(now: now)
        for kind in AlertKind.sensorExpiryReminders where snapshot.expiryPlan?[kind] == nil {
            actions.append(.cancelSlots(kind, [Self.expiryReminderSlot]))
        }
        return actions
    }

    private func expiryReminderNotice(_ kind: AlertKind, at date: Date, now: Date) -> AlertNotice {
        makeNotice(kind, fireDate: date, now: now, slot: Self.expiryReminderSlot)
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
            // Keep the first dates seen (later reports only jitter); fill in what was missing.
            let learnedGraceEnd = plan.graceEndsAt == nil && graceEndsAt != nil
            plan.expiresAt = plan.expiresAt ?? expiresAt
            plan.graceEndsAt = plan.graceEndsAt ?? graceEndsAt
            snapshot.expiryPlan = plan
            // The pending texts state the grace period's length: write them again now it is known.
            return learnedGraceEnd ? rebuildPendingExpiryReminders(now: now) : []
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
            guard case .pending(let date) = plan[kind], date > Self.protectedUntil(now) else { return nil }
            return .cancelSlots(kind, [Self.expiryReminderSlot])
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
