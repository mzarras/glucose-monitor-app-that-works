// D44 (Michael): an acknowledged or snoozed urgent low re-alarms at snooze end, even without a new
// reading. The safety audit's case: urgent low at 02:00, acknowledged; the phone out of range from
// 02:05; quiet hours silence missed readings — at 02:30 nothing sounded.
//
// While urgent low is snoozed, the urgent-low series is planned from the snooze end: the snooze-end
// alarm at `until` and, after it, the repeat grid every `repeatMinutes` for the usual 60-minute
// horizon — pending notifications, and AlarmKit alarms where allowed, so it rings while the app is
// suspended. It stays pending exactly while the latest live reading is at or below the threshold
// (or LOW, or there is none): a reading above the threshold removes it, a later low reading puts it
// back. At or after the snooze end:
//   • if the snooze-end alarm was pending, it was the alert: the episode is firing from `until` on
//     its grid, and the engine only plays the due sound (`playDueAlert`) — one alarm, never two, also
//     when a low reading arrives then;
//   • otherwise (it was removed, or a clock rollback ended the snooze early) urgent low fires now if
//     the latest reading is still low, as before;
//   • the latest reading above the threshold, inside the 5 mg/dL recovery band (56–60 by default):
//     urgent low stops holding the snooze and re-arms, so Low (≤ 70) is evaluated normally and fires
//     (D51). Before, a band reading kept urgent low "snoozed" — and Low superseded — indefinitely.
// Then it repeats as when firing, until a clearing reading or the next acknowledge. S7 is unchanged:
// the snooze is ≤ 30 minutes and a clock rollback ends it at once; quiet hours never silence it.
//
// One alarm at the edges (review m2): a low reading in the snooze's last minute puts the snooze-end
// alarm back even inside the protected minute, and at the end any pending entry due now (on the
// snooze-end grid) or within the protected minute (one a clock rollback re-dated) is the sounding.

import Foundation
import GlucoseCore

extension AlertEngine {
    /// The latest live reading is at or below the urgent-low threshold, LOW, or there is none.
    var urgentLowSnoozeEndWanted: Bool {
        guard let reading = snapshot.latestLiveReading else { return true }
        switch reading.value {
        case .belowRange: return true
        case .aboveRange: return false
        case .mgdl(let value): return value <= settings.urgentLow.thresholdMgdl
        }
    }

    /// Keeps the snooze-end alarm and the grid after it pending while urgent low is snoozed (or
    /// removes them after a reading above the threshold), touching nothing due within a minute.
    mutating func planUrgentLowSnoozeEnd(now: Date) -> [AlertAction] {
        guard case .snoozed(let snooze) = episode(.urgentLow) else { return [] }
        guard urgentLowSnoozeEndWanted else { return cancelFutureSeries(.urgentLow, now: now) }
        var actions = planSeries(.urgentLow, anchor: snooze.until, interval: urgentLowRepeatInterval, firstIndex: 0,
                                 count: urgentLowPendingCount, now: now, isRepeat: true)
        if snooze.until > now {
            // Inside the last minute the plan leaves the snooze-end date out (protected); put it back
            // if a reading above the threshold had removed it.
            actions += addSeriesEntry(.urgentLow, at: snooze.until, now: now, isRepeat: true)
        }
        return actions
    }

    /// D51: the snooze is over and the latest reading is above the threshold (in the recovery band):
    /// urgent low re-arms — it fires again on the next reading at or below the threshold — and Low,
    /// no longer superseded, is evaluated normally. A pending entry due within the minute is left
    /// to ring (never disturbed); none is planned.
    mutating func handOverUrgentLowSnooze(now: Date) -> [AlertAction] {
        setEpisode(.urgentLow, .armed)
        return cancelFutureSeries(.urgentLow, now: now)
    }

    /// The snooze is over and urgent low still applies: a current low reading (`current`), or no
    /// current reading with the latest one low.
    mutating func endUrgentLowSnooze(_ snooze: AlertSnooze, current: Bool, now: Date) -> [AlertAction] {
        let interval = urgentLowRepeatInterval
        let slot = Self.latestSlot(anchor: snooze.until, interval: interval, now: now.addingTimeInterval(AlertLimits.repeatSlotEarlyTolerance))
        let dueWithinTheMinute = series(.urgentLow).entries.first { $0.date > now && $0.date <= Self.protectedUntil(now) }
        let anchor: Date
        let sounding: Date
        if scheduledEntry(.urgentLow, at: snooze.until) != nil {
            // The snooze-end alarm went out (or is about to); the grid slot due now is this sounding.
            (anchor, sounding) = (snooze.until, slot)
        } else if let entry = dueWithinTheMinute {
            // One due within the minute off that grid (a rollback re-dated it): it is the sounding.
            (anchor, sounding) = (entry.date, entry.date)
        } else {
            // Nothing pending for the snooze end (a clock rollback ended the snooze early, or it was
            // removed): sound now. Without a current reading the text says the snooze ended and
            // gives the last value with its time, never "Treat now" (S1).
            if current { return fire(.urgentLow, now: now) }
            setEpisode(.urgentLow, .firing(AlertFiring(since: now, lastSoundedAt: now)))
            return [.fire(makeNotice(.urgentLow, fireDate: nil, now: now, snoozeEnd: true))] + planUrgentLowRepeats(anchor: now, now: now)
        }
        let notice = dueNotice(.urgentLow, at: sounding, now: now)
        setEpisode(.urgentLow, .firing(AlertFiring(since: anchor, lastSoundedAt: sounding)))
        return [.playDueAlert(notice)] + planUrgentLowRepeats(anchor: anchor, now: now)
    }

    /// Notices planned while urgent low is snoozed say the snooze ended, never a current value (S1).
    var urgentLowIsSnoozed: Bool {
        if case .snoozed = episode(.urgentLow) { return true }
        return false
    }
}
