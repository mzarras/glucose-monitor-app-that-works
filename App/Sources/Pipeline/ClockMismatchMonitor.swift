// The app's clock-mismatch latch (review N1; PROGRESS Phase 2 must-do "Clock-mismatch latch in the
// app"). The latest live reading must not be presented as current when the phone clock cannot be
// trusted for it:
//
// 1. Latch (WidgetCore `ClockMismatchLatch.update`): a latest reading dated more than 60 s ahead of
//    the phone clock (the clock was set back) is latched, and stays latched even after the clock
//    passes its date, until a newer reading replaces it.
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
    /// The latest reading's date while latched, nil otherwise.
    var latchedFor: Date?
    /// Wall clock and monotonic clock at the last check.
    var lastCheckWallClock: Date?
    var lastCheckUptime: Uptime?

    static let initial = ClockMismatchState(latchedFor: nil, lastCheckWallClock: nil, lastCheckUptime: nil)
}

enum ClockMismatchMonitor {
    /// A wall-clock change larger than this between two checks latches (the same tolerance as the
    /// gate's future tolerance: every staleness threshold in the app is ≥ 10 minutes).
    static let tolerance: TimeInterval = LiveReadingGate.futureTolerance

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
        var next = state
        let latestReading = latest.map { LatestReading(reading: $0, previous: previous) }
        next.latchedFor = ClockMismatchLatch.update(latchedFor: state.latchedFor, latest: latestReading, now: now)
        if let uptime, let lastUptime = state.lastCheckUptime, let lastWall = state.lastCheckWallClock,
           let realElapsed = uptime.seconds(since: lastUptime) {
            let wallElapsed = now.timeIntervalSince(lastWall)
            if abs(wallElapsed - realElapsed) > tolerance, let latest {
                next.latchedFor = latest.date
            }
        }
        if uptime != nil {
            next.lastCheckWallClock = now
            next.lastCheckUptime = uptime
        }
        return next
    }
}
