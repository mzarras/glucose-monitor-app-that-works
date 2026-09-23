// Clock faults (safety review WS4 B1 and the delta review's partial-rollback major). The engine
// only ever compares dates with the `now` it is given. If the phone clock moves backwards (manual
// change, NTP correcting a wrong clock), dates the engine stored earlier lie in the future, and
// without repair:
//   • a future-dated "latest live reading" hides every real reading after it (they are not newer),
//     so a real urgent low never fires;
//   • the missed-readings reference sits in the future, so missed readings never fires;
//   • a snooze made "at 12:00 until 12:30" lasts until the clock reaches 12:30 again — hours;
//   • repeat and re-alert timers wait for the clock to catch up; system alarms are set for
//     wall-clock times that are now far away.
// A backwards move is detected by comparing `now` with where the wall clock should be: the last
// input's `now` plus the real time elapsed since, measured on the monotonic `uptime` clock (which
// keeps counting in sleep and across relaunches within one boot). More than 60 s behind = rollback.
// That catches a rollback smaller than the time already elapsed (24 minutes back, 25 minutes into
// a snooze) even with no input in between. Without `uptime` (tests, or after a reboot) the check
// falls back to "earlier than the latest `now` seen". Any remembered date later than `now + 60 s`
// is repaired as well. On a detected rollback: the urgent-low
// snooze ends (real elapsed time is unknowable, S7), other snoozes keep what was left of them,
// firing/delay timers and the missed-readings window restart from now, and the urgent-low repeats
// are planned again from now — except those due by real time (+60 s), i.e. ringing or about to:
// they are kept and re-dated into the new wall-clock frame, so an NTP correction does not stop an
// alarm that is ringing with nobody there to see why. A clock moving forward needs no repair: readings go stale (not
// evaluated, S1), missed readings fires, snoozes end early — all loud.

import Foundation
import GlucoseCore

extension AlertEngine {
    /// Repairs `stored` for `now`. `rolledBack` is true when the clock moved backwards since the
    /// last input (by more than `protectedLeadTime`).
    static func repairingClockFaults(
        _ stored: AlertEngineSnapshot, now: Date, uptime: Uptime?
    ) -> (snapshot: AlertEngineSnapshot, rolledBack: Bool) {
        var s = stored
        let tolerance = LiveReadingGate.futureTolerance
        let latestPlausible = now.addingTimeInterval(tolerance)
        let lastSeen = s.latestNow
        let expectedNow = expectedWallClock(lastNow: lastSeen, lastUptime: s.latestUptime, uptime: uptime)
        let rolledBack = expectedNow.map { now < $0.addingTimeInterval(-tolerance) } ?? false

        if rolledBack, let expectedNow {
            // Pending repeats due by real time (+60 s) are ringing or about to: keep them, re-dated
            // into the new wall-clock frame so every later plan sees them as protected. The others
            // are left with their old dates; the next plan cancels and replaces them.
            let shift = expectedNow.timeIntervalSince(now)
            let realDueBy = expectedNow.addingTimeInterval(AlertLimits.protectedLeadTime)
            for (key, var series) in s.repeatSeries {
                series.entries = series.entries
                    .map { $0.date <= realDueBy ? ScheduledRepeat(sequence: $0.sequence, date: $0.date.addingTimeInterval(-shift)) : $0 }
                    .sorted { $0.date < $1.date }
                s.repeatSeries[key] = series
            }
        }

        // S1: a reading "from the future" is not current and must not hide the real ones.
        if let reading = s.latestLiveReading, reading.date > latestPlausible {
            s.latestLiveReading = nil
        }
        if let date = s.lastValidReadingDate, date > latestPlausible {
            s.lastValidReadingDate = nil
        }
        // S5: restart the missed-readings window from now; evaluation reschedules its notifications.
        if rolledBack || s.missedReadingsReference > latestPlausible {
            s.missedReadingsReference = now
        }

        for (key, episode) in s.episodes {
            s.episodes[key] = repaired(
                episode, isUrgentLow: key == AlertKind.urgentLow.rawValue, now: now,
                latestPlausible: latestPlausible, rolledBackFrom: rolledBack ? lastSeen : nil
            )
        }
        if uptime != nil {
            // With a monotonic reference, the wall clock is simply re-anchored at every input.
            s.latestNow = now
        } else {
            s.latestNow = rolledBack ? now : max(lastSeen ?? now, now)
        }
        s.latestUptime = uptime
        return (s, rolledBack)
    }

    /// Where the wall clock should be now: the last input's `now` plus the real time since, if the
    /// monotonic clock is comparable (same boot); else the last `now` itself.
    static func expectedWallClock(lastNow: Date?, lastUptime: Uptime?, uptime: Uptime?) -> Date? {
        guard let lastNow else { return nil }
        guard let lastUptime, let uptime, let elapsed = uptime.seconds(since: lastUptime) else { return lastNow }
        return lastNow.addingTimeInterval(elapsed)
    }

    private static func repaired(
        _ episode: AlertEpisode, isUrgentLow: Bool, now: Date, latestPlausible: Date, rolledBackFrom lastSeen: Date?
    ) -> AlertEpisode {
        let rolledBack = lastSeen != nil
        func restarted(_ date: Date) -> Date { rolledBack || date > latestPlausible ? now : date }
        switch episode {
        case .armed:
            return .armed
        case .delaying(let since):
            return .delaying(since: restarted(since))
        case .firing(let firing):
            return .firing(AlertFiring(since: restarted(firing.since), lastSoundedAt: restarted(firing.lastSoundedAt)))
        case .snoozed(let snooze):
            let futureStamped = snooze.snoozedAt > latestPlausible
            if isUrgentLow && (rolledBack || futureStamped) {
                // S7: how much real time has passed since the snooze began is unknowable once the
                // clock has jumped back (it is only noticed at the next input). Restarting the 30
                // minutes could make it 30 + that gap, so the snooze ends now; urgent low sounds
                // again on the next current low reading.
                return .snoozed(AlertSnooze(snoozedAt: now, until: now))
            }
            var snoozedAt = snooze.snoozedAt
            var until = snooze.until
            if let lastSeen {
                // Other alerts keep what was left of the snooze at the last input, from now (real
                // time since that input is not subtracted: it cannot be measured after a reboot).
                until = now.addingTimeInterval(max(0, until.timeIntervalSince(lastSeen)))
                snoozedAt = now
            } else if futureStamped {
                until = now.addingTimeInterval(until.timeIntervalSince(snoozedAt))
                snoozedAt = now
            }
            if isUrgentLow {
                // S7: at most 30 minutes from when it was made, and from now.
                let maximum = TimeInterval(AlertLimits.urgentLowMaximumSnoozeMinutes * 60)
                until = min(until, snoozedAt.addingTimeInterval(maximum), now.addingTimeInterval(maximum))
            }
            return .snoozed(AlertSnooze(snoozedAt: snoozedAt, until: until))
        }
    }

    /// After a rollback the pending urgent-low repeats (and their alarms, set for wall-clock times)
    /// are for the wrong times: cancel the ones not due and plan again from now.
    mutating func replanAfterRollback(now: Date) -> [AlertAction] {
        guard case .firing(let firing) = episode(.urgentLow) else { return [] }
        return cancelFutureSeries(.urgentLow, now: now) + planUrgentLowRepeats(anchor: firing.since, now: now)
    }
}
