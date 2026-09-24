// Missed readings (HANDOFF §5, S5): no valid reading for the window (default 15 minutes).
//
// This alert fires precisely when nothing wakes the app (no BLE event), so it cannot rely on the
// engine running at the right moment. Its notifications are therefore always pending ahead of
// time: every valid reading reschedules them to `reading + window`, `+ 2 × window`, … (xDrip4iOS
// does the same with a repeating trigger: xDrip/Managers/Alerts/AlertManager.swift:1049-1051,
// rescheduled on every reading). When the app happens to be awake at or after that time, the
// engine marks the alert firing and asks for the ringer-off sound (`playDueAlert`).
//
// The pending notifications are a repeat series (AlertEngine+Series.swift): a notification due
// within a minute is never removed by a reschedule.
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
        let firstDueFromReference = reference.addingTimeInterval(window)
        let condition = StatusConditions.missedReadings(now: now, reference: reference, windowMinutes: settings.missedReadings.windowMinutes)

        switch episode(kind) {
        case .armed, .delaying:
            guard condition == .met else {
                return planMissedReadings(from: firstDueFromReference, now: now)
            }
            return startMissedReadingsFiring(from: firstDueFromReference, now: now)

        case .firing(let firing):
            if condition == .clear {
                return clearMissedReadings() + planMissedReadings(from: firstDueFromReference, now: now)
            }
            let slot = Self.latestSlot(anchor: firing.since, interval: window, now: now.addingTimeInterval(AlertLimits.repeatSlotEarlyTolerance))
            guard slot > firing.lastSoundedAt else {
                return planMissedReadings(from: firing.since, now: now)
            }
            setEpisode(kind, .firing(AlertFiring(since: firing.since, lastSoundedAt: slot)))
            return [.playDueAlert(dueNotice(kind, at: slot, now: now))] + planMissedReadings(from: firing.since, now: now)

        case .snoozed(let snooze):
            if condition == .clear {
                return clearMissedReadings() + planMissedReadings(from: firstDueFromReference, now: now)
            }
            guard now >= snooze.until else {
                return planMissedReadings(from: snooze.until, now: now)
            }
            return startMissedReadingsFiring(from: snooze.until, now: now)
        }
    }

    var missedReadingsWindow: TimeInterval {
        TimeInterval(settings.missedReadings.windowMinutes * 60)
    }

    /// The alert became due at `firstDue` (≤ now). If its notification was pending, iOS has posted
    /// it and only the sound is needed; if not (e.g. restored from an older state), post it now.
    private mutating func startMissedReadingsFiring(from firstDue: Date, now: Date) -> [AlertAction] {
        let kind = AlertKind.missedReadings
        let slot = Self.latestSlot(anchor: firstDue, interval: missedReadingsWindow, now: now)
        let wasPending = series(kind).entries.contains { $0.date >= firstDue && $0.date <= Self.protectedUntil(now) }
        setEpisode(kind, .firing(AlertFiring(since: firstDue, lastSoundedAt: slot)))
        let first: AlertAction = wasPending ? .playDueAlert(dueNotice(kind, at: slot, now: now)) : .fire(makeNotice(kind, fireDate: nil, now: now))
        return [first] + planMissedReadings(from: firstDue, now: now)
    }

    /// Keeps `scheduledNotificationCount` notifications pending on the grid `start + k × window`.
    private mutating func planMissedReadings(from start: Date, now: Date) -> [AlertAction] {
        planSeries(.missedReadings, anchor: start, interval: missedReadingsWindow, firstIndex: 0,
                   count: AlertLimits.scheduledNotificationCount, now: now, isRepeat: false)
    }

    private mutating func clearMissedReadings() -> [AlertAction] {
        setEpisode(.missedReadings, .armed)
        forgetSeries(.missedReadings)
        return [.cancel(.missedReadings)]
    }

    /// Disabled, or no readings expected (not paired / warming up): nothing pending, nothing firing.
    private mutating func resetMissedReadings() -> [AlertAction] {
        guard episode(.missedReadings) != .armed || !series(.missedReadings).entries.isEmpty else { return [] }
        return clearMissedReadings()
    }
}
