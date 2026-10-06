// The app's clock-mismatch latch (review N1; PROGRESS Phase 2 must-do "Clock-mismatch latch in the
// app"). The latest live reading must not be presented as current when the phone clock cannot be
// trusted for it:
//
// 1. Latch (WidgetCore `ClockMismatchLatch.update`): a latest reading dated more than 60 s ahead of
//    the phone clock (the clock was set back) is latched, and stays latched even after the clock
//    passes its date, until a newer reading replaces it. An older reading never clears it.
// 2. Memoryless check: at every ingest/wake the wall clock and the monotonic clock
//    (`CLOCK_MONOTONIC_RAW`, counts through sleep, tagged with the boot) are recorded. If, since the
//    previous record in the same boot, the wall clock moved more than 60 s differently from real
//    elapsed time, the clock was changed: the latest reading's age can no longer be judged, so it is
//    latched. (Example: set back 30 min, then 40 real minutes pass with no wake; the reading then
//    looks 10 min old but is 40.)
//
// Both persist across relaunches (`ClockMismatchState`). Pure logic; `LiveAppServices` stores it.

import AlertEngine
import Foundation
import GlucoseCore
import WidgetCore

struct ClockMismatchState: Sendable, Equatable, Codable {
    /// The newest latched reading's date, nil when nothing is latched.
    var latchedFor: Date?
    /// Wall clock and monotonic clock at the last check.
    var lastCheckWallClock: Date?
    var lastCheckUptime: Uptime?
    /// Older readings that are latched too (Phase 3 carry-over): a clock change while an older
    /// reading was the latest (a failed open showing a re-delivered reading) latches that reading
    /// without losing the latch of the newer one, which comes back as the latest once the store
    /// opens. At most `ClockMismatchMonitor.maximumOlderLatches`; nil in states saved before it existed.
    var olderLatched: [Date]?

    static let initial = ClockMismatchState(latchedFor: nil, lastCheckWallClock: nil, lastCheckUptime: nil)

    func isLatched(_ date: Date) -> Bool {
        date == latchedFor || (olderLatched ?? []).contains(date)
    }

    /// What the facade reports for `latest`: its date while it is latched, otherwise the newest latch.
    func latch(for latest: GlucoseReading?) -> Date? {
        if let latest, isLatched(latest.date) { return latest.date }
        return latchedFor
    }
}

enum ClockMismatchMonitor {
    /// A wall-clock change larger than this between two checks latches (the same tolerance as the
    /// gate's future tolerance: every staleness threshold in the app is ≥ 10 minutes).
    static let tolerance: TimeInterval = LiveReadingGate.futureTolerance
    /// How many older latched readings are remembered (`ClockMismatchState.olderLatched`).
    static let maximumOlderLatches = 8

    /// The state after a check at `now`.
    ///
    /// - Parameters:
    ///   - latest: the store's latest live reading; `previous` the live reading before it.
    ///   - uptime: the monotonic clock now, or nil when it does not apply (DEBUG replay): then only
    ///     the latch rule runs.
    static func check(
        _ state: ClockMismatchState,
        latest: GlucoseReading?,
        previous: GlucoseReading?,
        now: Date,
        uptime: Uptime?
    ) -> ClockMismatchState {
        // Nil means "not known yet" (e.g. the store is still opening at launch), not "no reading":
        // keep the latch and the last clock record as they are, so a relaunch can neither clear a
        // latch nor hide a clock change made while the latest reading was unknown (review B1).
        guard let latest else { return state }
        var next = state
        if let newestLatched = state.latchedFor, latest.date < newestLatched {
            // An older reading is the latest for a while — a re-delivered reading waiting for a
            // store that cannot open. Only a newer reading clears a latch (review m4): every latch is
            // kept, and the latched reading is still latched when it is the latest again.
        } else {
            let latestReading = LatestReading(reading: latest, previous: previous)
            next.latchedFor = ClockMismatchLatch.update(latchedFor: state.latchedFor, latest: latestReading, now: now)
            if let newestLatched = state.latchedFor, latest.date > newestLatched {
                next.olderLatched = nil // a newer reading: the older latched ones are history
            }
        }
        if let uptime, let lastUptime = state.lastCheckUptime, let lastWall = state.lastCheckWallClock,
           let realElapsed = uptime.seconds(since: lastUptime) {
            let wallElapsed = now.timeIntervalSince(lastWall)
            if abs(wallElapsed - realElapsed) > tolerance {
                if let newestLatched = next.latchedFor, latest.date < newestLatched {
                    // Latch the reading shown now as well, keeping the newer reading's latch.
                    var older = (next.olderLatched ?? []).filter { $0 != latest.date }
                    older.append(latest.date)
                    next.olderLatched = Array(older.suffix(maximumOlderLatches))
                } else {
                    next.latchedFor = latest.date
                }
            }
        }
        if uptime != nil {
            next.lastCheckWallClock = now
            next.lastCheckUptime = uptime
        }
        return next
    }
}
