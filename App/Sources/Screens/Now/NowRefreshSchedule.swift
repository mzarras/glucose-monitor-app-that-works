// The Now screen's clock (S5, PROGRESS D43): a tick every `interval` seconds, so ages and staleness
// stay current, plus a tick exactly at each of `extraDates` — e.g. the end of the grace period — so
// a state that changes at a known instant changes on screen at that instant, not up to `interval`
// later.

import Foundation
import SwiftUI

struct NowRefreshSchedule: TimelineSchedule {
    var interval: TimeInterval
    var extraDates: [Date]

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> UnfoldFirstSequence<Date> {
        let schedule = self
        return sequence(first: startDate) { schedule.nextDate(after: $0, start: startDate) }
    }

    /// A tick may render at its scheduled date only when that is less than this far ahead of the
    /// clock (an early tick); further ahead the scheduled date is stale (the clock was set back).
    static let earlyTickTolerance: TimeInterval = 1

    /// The moment to render a tick for. A tick that fires a few milliseconds early (review m9)
    /// renders at its scheduled date, so the switch at the grace end isn't left for the next 15 s
    /// tick. A scheduled date a second or more ahead of the clock is not an early tick: after the
    /// phone's clock was set back, TimelineView can keep entries from before the change (review n1),
    /// and rendering at them would put the screen in the future (a current reading would read as
    /// stale). Then, and whenever the clock is ahead, the clock is used.
    static func renderDate(scheduled: Date, clock: Date) -> Date {
        let ahead = scheduled.timeIntervalSince(clock)
        return ahead > 0 && ahead < earlyTickTolerance ? scheduled : clock
    }

    /// The next tick after `date`: the next one on the `interval` grid that starts at `start`, or an
    /// extra date, whichever comes first.
    func nextDate(after date: Date, start: Date) -> Date {
        let steps = (date.timeIntervalSince(start) / interval).rounded(.down) + 1
        let periodic = start.addingTimeInterval(steps * interval)
        let extra = extraDates.filter { $0 > date }.min()
        return extra.map { min($0, periodic) } ?? periodic
    }
}
