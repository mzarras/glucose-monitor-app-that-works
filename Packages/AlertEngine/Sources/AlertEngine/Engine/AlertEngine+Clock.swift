// Clock faults (safety review WS4 B1). The engine only ever compares dates with the `now` it is
// given. If the phone clock moves backwards (manual change, NTP correcting a wrong clock), dates
// the engine stored earlier lie in the future, and without repair:
//   • a future-dated "latest live reading" hides every real reading after it (they are not newer),
//     so a real urgent low never fires;
//   • the missed-readings reference sits in the future, so missed readings never fires;
//   • a snooze made "at 12:00 until 12:30" lasts until the clock reaches 12:30 again — hours;
//   • repeat and re-alert timers wait for the clock to catch up.
// A future date is never meaningful here: every date the engine keeps is "something that already
// happened". So before every input, and when restoring a snapshot, anything later than
// `now + LiveReadingGate.futureTolerance` is repaired. A clock moving forward needs no repair:
// readings go stale (not evaluated, S1), missed readings fires, snoozes end early — all loud.

import Foundation
import GlucoseCore

extension AlertEngine {
    static func repairingClockFaults(_ stored: AlertEngineSnapshot, now: Date) -> AlertEngineSnapshot {
        var s = stored
        let latestPlausible = now.addingTimeInterval(LiveReadingGate.futureTolerance)

        // S1: a reading "from the future" is not current and must not hide the real ones.
        if let reading = s.latestLiveReading, reading.date > latestPlausible {
            s.latestLiveReading = nil
        }
        if let date = s.lastValidReadingDate, date > latestPlausible {
            s.lastValidReadingDate = nil
        }
        // S5: restart the missed-readings window from now; evaluation reschedules its notifications.
        if s.missedReadingsReference > latestPlausible {
            s.missedReadingsReference = now
        }

        for (key, episode) in s.episodes {
            s.episodes[key] = repaired(episode, isUrgentLow: key == AlertKind.urgentLow.rawValue, now: now, latestPlausible: latestPlausible)
        }
        return s
    }

    private static func repaired(_ episode: AlertEpisode, isUrgentLow: Bool, now: Date, latestPlausible: Date) -> AlertEpisode {
        func notInFuture(_ date: Date) -> Date { date > latestPlausible ? now : date }
        switch episode {
        case .armed:
            return .armed
        case .delaying(let since):
            return .delaying(since: notInFuture(since))
        case .firing(let firing):
            return .firing(AlertFiring(since: notInFuture(firing.since), lastSoundedAt: notInFuture(firing.lastSoundedAt)))
        case .snoozed(let snooze):
            var snoozedAt = snooze.snoozedAt
            var until = snooze.until
            if snoozedAt > latestPlausible {
                if isUrgentLow {
                    // S7: how much real time has passed since the snooze began is unknowable once
                    // the clock has jumped back (it is only noticed at the next input, which can be
                    // minutes later). Restarting the 30 minutes could make it 30 + that gap, so the
                    // snooze ends now; urgent low sounds again on the next current low reading.
                    return .snoozed(AlertSnooze(snoozedAt: now, until: now))
                }
                // Other alerts keep the length that was granted, measured from now.
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
}
