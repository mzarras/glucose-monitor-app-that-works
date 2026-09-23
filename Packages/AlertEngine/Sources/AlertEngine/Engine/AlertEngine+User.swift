// User actions (acknowledge, snooze, silence), settings changes, and the launch reconcile.

import Foundation

extension AlertEngine {
    mutating func apply(_ action: AlertUserAction, now: Date) -> [AlertAction] {
        switch action {
        case .acknowledge(let kind):
            if kind.isEventAlert { return [.cancel(kind)] }
            guard episode(kind).isActive, let minutes = settings.snoozeMinutes(kind) else {
                return [.userActionIgnored(action)]
            }
            return snooze(kind, minutes: minutes, now: now)

        case .snooze(let kind, let minutes):
            if kind.isEventAlert { return [.cancel(kind)] }
            // No pre-emptive snooze: every new episode sounds. In particular urgent low cannot be
            // silenced before it fires (S7).
            guard episode(kind).isActive else { return [.userActionIgnored(action)] }
            return snooze(kind, minutes: minutes, now: now)

        case .silence(let kind):
            return [.stopSound(kind)]
        }
    }

    /// Snoozes an active alert. S7: urgent low is clamped to at most 30 minutes here, whatever
    /// the caller asked for; every other alert to `AlertLimits.snoozeMinutes`.
    private mutating func snooze(_ kind: AlertKind, minutes: Int, now: Date) -> [AlertAction] {
        let range = kind == .urgentLow ? AlertLimits.urgentLowSnoozeMinutes : AlertLimits.snoozeMinutes
        let clamped = AlertLimits.clamp(minutes, to: range)
        setEpisode(kind, .snoozed(AlertSnooze(snoozedAt: now, until: now.addingTimeInterval(TimeInterval(clamped * 60)))))
        if kind == .missedReadings {
            // The cancel below removes its pending notifications; evaluation reschedules them to
            // start when the snooze ends.
            snapshot.missedReadingsScheduledFrom = nil
        }
        return [.cancel(kind)]
    }

    mutating func apply(_ newSettings: AlertSettings, now: Date) -> [AlertAction] {
        settings = newSettings
        var actions: [AlertAction] = []
        // Pending notifications carry the sound, text and quiet-hours decision they were built
        // with, so rebuild them. Missed readings: remove them here; evaluation reschedules them
        // (or leaves them removed if the alert is now off).
        if snapshot.missedReadingsScheduledFrom != nil {
            actions.append(.cancelScheduled(.missedReadings))
            snapshot.missedReadingsScheduledFrom = nil
        }
        if case .firing(let firing) = episode(.urgentLow) {
            // Restart the repeat grid from the last sounding with the (possibly new) interval.
            setEpisode(.urgentLow, .firing(AlertFiring(since: firing.lastSoundedAt, lastSoundedAt: firing.lastSoundedAt)))
            actions.append(scheduleUrgentLowRepeats(after: firing.lastSoundedAt, now: now))
        }
        return actions
    }

    /// What a previous process may have left pending cannot be trusted: it may have been killed
    /// between deciding and removing. Rebuild or remove it from the restored state.
    mutating func reconcileAfterLaunch(now: Date) -> [AlertAction] {
        var actions: [AlertAction] = []
        if case .firing(let firing) = episode(.urgentLow) {
            actions.append(scheduleUrgentLowRepeats(after: firing.lastSoundedAt, now: now))
        } else {
            actions.append(.cancelScheduled(.urgentLow))
        }
        if snapshot.missedReadingsScheduledFrom != nil {
            // Evaluation schedules them again from the restored state.
            actions.append(.cancelScheduled(.missedReadings))
            snapshot.missedReadingsScheduledFrom = nil
        }
        return actions
    }
}
