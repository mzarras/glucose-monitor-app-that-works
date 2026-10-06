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

    /// The next tick after `date`: the next one on the `interval` grid that starts at `start`, or an
    /// extra date, whichever comes first.
    func nextDate(after date: Date, start: Date) -> Date {
        let steps = (date.timeIntervalSince(start) / interval).rounded(.down) + 1
        let periodic = start.addingTimeInterval(steps * interval)
        let extra = extraDates.filter { $0 > date }.min()
        return extra.map { min($0, periodic) } ?? periodic
    }
}
