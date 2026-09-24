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
    /// the caller asked for; every other alert to `AlertLimits.snoozeMinutes`. The cancel removes
    /// all of the alert's notifications, pending repeats and alarms (the user has seen it).
    private mutating func snooze(_ kind: AlertKind, minutes: Int, now: Date) -> [AlertAction] {
        let range = kind == .urgentLow ? AlertLimits.urgentLowSnoozeMinutes : AlertLimits.snoozeMinutes
        let clamped = AlertLimits.clamp(minutes, to: range)
        setEpisode(kind, .snoozed(AlertSnooze(snoozedAt: now, until: now.addingTimeInterval(TimeInterval(clamped * 60)))))
        forgetSeries(kind)
        return [.cancel(kind)]
    }

    mutating func apply(_ newSettings: AlertSettings, now: Date) -> [AlertAction] {
        settings = newSettings
        // Pending repeats carry the sound, text and quiet-hours decision they were built with, so
        // the ones due later than a minute are removed and rebuilt; a due or ringing one stays.
        var actions = cancelFutureSeries(.urgentLow, now: now) + cancelFutureSeries(.missedReadings, now: now)
        if case .firing(let firing) = episode(.urgentLow) {
            // Restart the repeat grid from the last sounding with the (possibly new) interval.
            setEpisode(.urgentLow, .firing(AlertFiring(since: firing.lastSoundedAt, lastSoundedAt: firing.lastSoundedAt)))
            actions += planUrgentLowRepeats(anchor: firing.lastSoundedAt, now: now)
        }
        // Missed readings are planned again by evaluation (or stay removed if now off).
        return actions
    }

    /// What a previous process left pending cannot be trusted: it may have been killed between
    /// deciding and acting. Rebuild or remove it from the restored state, never touching a repeat
    /// that is due or ringing.
    mutating func reconcileAfterLaunch(now: Date) -> [AlertAction] {
        var actions: [AlertAction] = []
        if case .firing(let firing) = episode(.urgentLow) {
            actions += resetSeriesAfterLaunch(.urgentLow, now: now)
            actions += planUrgentLowRepeats(anchor: firing.since, now: now)
        } else {
            forgetSeries(.urgentLow)
            actions.append(.cancelScheduled(.urgentLow))
        }
        // Evaluation plans missed readings again from the restored state.
        actions += resetSeriesAfterLaunch(.missedReadings, now: now)
        return actions
    }
}
