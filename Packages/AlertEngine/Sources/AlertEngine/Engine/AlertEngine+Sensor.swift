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
        guard StatusConditions.isSettled(state) else { return [] }
        let previous = snapshot.settledSensorState
        snapshot.settledSensorState = state

        var actions: [AlertAction] = []
        if case .warmingUp(let warmUpEnd) = previous, Self.isRunning(state) {
            actions += announce(.sensorWarmUpComplete, sessionDate: warmUpEnd, now: now)
        }
        // Leaving a state in which no readings were expected starts the missed-readings window
        // afresh, so a new sensor does not inherit the previous sensor's last reading time.
        if StatusConditions.suppressesMissedReadings(previous), !StatusConditions.suppressesMissedReadings(state) {
            snapshot.missedReadingsReference = max(snapshot.missedReadingsReference, now)
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
                remember(Self.eventID(.sensorExpiringIn24Hours, sessionDate: expiresAt))
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

    /// Fires a one-off announcement once per session date. A disabled announcement is not
    /// remembered, so turning it on later in the same window still delivers it.
    private mutating func announce(_ kind: AlertKind, sessionDate: Date, now: Date) -> [AlertAction] {
        let id = Self.eventID(kind, sessionDate: sessionDate)
        guard settings.isEnabled(kind), !snapshot.announcedEvents.contains(id) else { return [] }
        remember(id)
        return [.fire(makeNotice(kind, fireDate: nil, now: now))]
    }

    private mutating func remember(_ id: String) {
        guard !snapshot.announcedEvents.contains(id) else { return }
        snapshot.announcedEvents.append(id)
        if snapshot.announcedEvents.count > AlertEngineSnapshot.announcedEventsLimit {
            snapshot.announcedEvents.removeFirst(snapshot.announcedEvents.count - AlertEngineSnapshot.announcedEventsLimit)
        }
    }

    static func eventID(_ kind: AlertKind, sessionDate: Date) -> String {
        "\(kind.rawValue)@\(Int(sessionDate.timeIntervalSince1970))"
    }

    static func isRunning(_ state: SensorState) -> Bool {
        switch state {
        case .active, .gracePeriod: return true
        default: return false
        }
    }
}
