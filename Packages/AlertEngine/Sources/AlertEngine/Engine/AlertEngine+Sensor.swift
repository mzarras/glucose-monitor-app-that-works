// Sensor state (HANDOFF §5 "Sensor", S5) and the one-off sensor announcements.
//
// The G7 connects for a few seconds every 5 minutes, so the source reports searching →
// connecting → authenticating → active (or error, …) on every cycle. Those transient states must
// neither fire nor clear anything; only "settled" states (see StatusConditions.isSettled) change
// the sensor alerts. Bluetooth availability is judged on the last reported state of any kind.

import Foundation
import GlucoseCore

extension AlertEngine {
    mutating func receive(_ state: SensorState, now: Date) -> [AlertAction] {
        snapshot.lastReportedSensorState = state
        guard StatusConditions.isSettled(state) else {
            // A transient failure means a pairing exists, so "not paired" no longer holds: stop
            // suppressing missed readings and start its window now (safety review D36 B1). With
            // no settled state at all there is no suppression to end.
            if case .failed = state, snapshot.settledSensorState == .notPaired {
                snapshot.settledSensorState = nil
                snapshot.missedReadingsReference = max(snapshot.missedReadingsReference, now)
            }
            return []
        }
        let previous = snapshot.settledSensorState
        snapshot.settledSensorState = state

        var actions: [AlertAction] = []
        if case .warmingUp(let warmUpEnd) = previous, Self.isRunning(state) {
            actions += announce(.sensorWarmUpComplete, sessionDate: warmUpEnd, now: now)
        }
        // Starting the missed-readings window afresh, so a new sensor does not inherit the previous
        // sensor's last reading time: from now on leaving "not paired"; from the end of warm-up (or
        // now, if the sensor finished early) on leaving warm-up. Leaving an expired or failed state
        // does NOT restart it (D41): after a brief or false end report, missed readings stays due at
        // the last reading + window; a new sensor goes through warm-up, which restarts it.
        switch (previous, state) {
        case (.notPaired, .notPaired), (.warmingUp, .warmingUp), (.warmingUp, .notPaired):
            break
        case (.notPaired, _):
            snapshot.missedReadingsReference = max(snapshot.missedReadingsReference, now)
        case (.warmingUp(let endsAt), _):
            snapshot.missedReadingsReference = max(snapshot.missedReadingsReference, min(now, endsAt))
        default:
            break
        }
        return actions
    }

    /// Expiring in 24 h / 2 h and grace period, checked on every input because they depend on time.
    mutating func announceExpiryAndGracePeriod(now: Date) -> [AlertAction] {
        switch snapshot.settledSensorState {
        case .active(_, let expiresAt):
            let remaining = expiresAt.timeIntervalSince(now)
            guard remaining > 0 else { return [] }
            if remaining <= 2 * 3600 {
                // The 2-hour notice makes the 24-hour one redundant; never send both at once.
                remember(.sensorExpiringIn24Hours, sessionDate: expiresAt)
                return announce(.sensorExpiringIn2Hours, sessionDate: expiresAt, now: now)
            }
            if remaining <= 24 * 3600 {
                return announce(.sensorExpiringIn24Hours, sessionDate: expiresAt, now: now)
            }
            return []
        case .gracePeriod(let endsAt):
            return announce(.sensorGracePeriod, sessionDate: endsAt, now: now)
        default:
            return []
        }
    }

    /// Fires a one-off announcement once per sensor session. Session dates are derived from the
    /// phone clock at each connection (S3), so the same session's expiry or grace end can shift by
    /// a second or so between connections (safety review WS4 M1). A date within an hour of the one
    /// already announced for this kind is the same session; a new sensor's dates are days apart.
    /// A disabled announcement is not remembered, so turning it on later in the window delivers it.
    private mutating func announce(_ kind: AlertKind, sessionDate: Date, now: Date) -> [AlertAction] {
        guard settings.isEnabled(kind), !alreadyAnnounced(kind, sessionDate: sessionDate) else { return [] }
        remember(kind, sessionDate: sessionDate)
        return [.fire(makeNotice(kind, fireDate: nil, now: now))]
    }

    /// Two dates this close belong to the same sensor session.
    static let sameSessionTolerance: TimeInterval = 3600

    private func alreadyAnnounced(_ kind: AlertKind, sessionDate: Date) -> Bool {
        guard let last = snapshot.announcedSessionDates[kind.rawValue] else { return false }
        return abs(last.timeIntervalSince(sessionDate)) < Self.sameSessionTolerance
    }

    private mutating func remember(_ kind: AlertKind, sessionDate: Date) {
        snapshot.announcedSessionDates[kind.rawValue] = sessionDate
    }

    static func isRunning(_ state: SensorState) -> Bool {
        switch state {
        case .active, .gracePeriod: return true
        default: return false
        }
    }
}
