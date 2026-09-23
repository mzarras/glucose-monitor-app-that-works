// Missed readings (HANDOFF §5, S5): no valid reading for the window (default 15 minutes).
//
// This alert fires precisely when nothing wakes the app (no BLE event), so it cannot rely on the
// engine running at the right moment. Its notifications are therefore always pending ahead of
// time: every valid reading reschedules them to `reading + window`, `+ 2 × window`, … (xDrip4iOS
// does the same with a repeating trigger: xDrip/Managers/Alerts/AlertManager.swift:1049-1051,
// rescheduled on every reading). When the app happens to be awake at or after that time, the
// engine marks the alert firing and asks for the ringer-off sound (`playDueAlert`).
//
// While the app is suspended the pending Time Sensitive notification is the only channel, so on a
// phone set to silent it vibrates but makes no sound (PROGRESS.md D17, accepted by Michael).

import Foundation
import GlucoseCore

extension AlertEngine {
    mutating func stepMissedReadings(now: Date) -> [AlertAction] {
        let kind = AlertKind.missedReadings
        guard settings.isEnabled(kind), !StatusConditions.suppressesMissedReadings(snapshot.settledSensorState) else {
            return resetMissedReadings()
        }
        let window = missedReadingsWindow
        let reference = snapshot.missedReadingsReference
        let condition = StatusConditions.missedReadings(now: now, reference: reference, windowMinutes: settings.missedReadings.windowMinutes)

        switch episode(kind) {
        case .armed, .delaying:
            guard condition == .met else {
                return ensureMissedReadingsScheduled(from: reference.addingTimeInterval(window), now: now)
            }
            return startMissedReadingsFiring(from: reference.addingTimeInterval(window), now: now)

        case .firing(let firing):
            if condition == .clear {
                return clearMissedReadings() + ensureMissedReadingsScheduled(from: reference.addingTimeInterval(window), now: now)
            }
            let slot = Self.latestSlot(anchor: firing.since, interval: window, now: now.addingTimeInterval(AlertLimits.repeatSlotEarlyTolerance))
            guard slot > firing.lastSoundedAt else {
                return ensureMissedReadingsScheduled(from: firing.lastSoundedAt.addingTimeInterval(window), now: now)
            }
            setEpisode(kind, .firing(AlertFiring(since: firing.since, lastSoundedAt: slot)))
            return [.playDueAlert(makeNotice(kind, fireDate: nil, now: now))]
                + scheduleMissedReadings(from: slot.addingTimeInterval(window), now: now)

        case .snoozed(let snooze):
            if condition == .clear {
                return clearMissedReadings() + ensureMissedReadingsScheduled(from: reference.addingTimeInterval(window), now: now)
            }
            guard now >= snooze.until else {
                return ensureMissedReadingsScheduled(from: snooze.until, now: now)
            }
            return startMissedReadingsFiring(from: snooze.until, now: now)
        }
    }

    var missedReadingsWindow: TimeInterval {
        TimeInterval(settings.missedReadings.windowMinutes * 60)
    }

    /// The alert became due at `firstDue` (≤ now). Its notification was scheduled for that time, so
    /// iOS has posted it; only the sound is needed. If it was not scheduled (e.g. the engine was
    /// restored from an older state), post it now instead.
    private mutating func startMissedReadingsFiring(from firstDue: Date, now: Date) -> [AlertAction] {
        let kind = AlertKind.missedReadings
        let slot = Self.latestSlot(anchor: firstDue, interval: missedReadingsWindow, now: now)
        let wasScheduled = snapshot.missedReadingsScheduledFrom == firstDue
        setEpisode(kind, .firing(AlertFiring(since: firstDue, lastSoundedAt: slot)))
        let notice = makeNotice(kind, fireDate: nil, now: now)
        return [wasScheduled ? .playDueAlert(notice) : .fire(notice)]
            + scheduleMissedReadings(from: slot.addingTimeInterval(missedReadingsWindow), now: now)
    }

    /// Schedules the pending notifications only if they are not already pending from `start`.
    mutating func ensureMissedReadingsScheduled(from start: Date, now: Date) -> [AlertAction] {
        guard snapshot.missedReadingsScheduledFrom != start else { return [] }
        return scheduleMissedReadings(from: start, now: now)
    }

    /// `start`, `start + window`, … — the next `scheduledNotificationCount` of those after `now`.
    mutating func scheduleMissedReadings(from start: Date, now: Date) -> [AlertAction] {
        let dates = Self.futureSlots(anchor: start, interval: missedReadingsWindow, firstIndex: 0, after: now, count: AlertLimits.scheduledNotificationCount)
        let notices = dates.map { makeNotice(.missedReadings, fireDate: $0, now: now) }
        snapshot.missedReadingsScheduledFrom = start
        return [.schedule(.missedReadings, notices)]
    }

    private mutating func clearMissedReadings() -> [AlertAction] {
        setEpisode(.missedReadings, .armed)
        snapshot.missedReadingsScheduledFrom = nil
        return [.cancel(.missedReadings)]
    }

    /// Disabled, or no readings expected (not paired / warming up): nothing pending, nothing firing.
    private mutating func resetMissedReadings() -> [AlertAction] {
        guard episode(.missedReadings) != .armed || snapshot.missedReadingsScheduledFrom != nil else { return [] }
        return clearMissedReadings()
    }
}
