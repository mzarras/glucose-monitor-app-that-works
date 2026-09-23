// Continuity rules shared by every duration-based metric: hypo events, the in-range streak.
// HANDOFF §6 ("gaps > 15 min break the run") and §7.5 ("Gaps > 15 min break the line").

import Foundation

/// How readings join into continuous stretches of time.
///
/// - A reading **covers** the time from its timestamp until the earliest of: 5 minutes later (the
///   G7's reading interval), the next counted reading, or a limit. For the in-range streak the
///   limit is the period end, so a streak never exceeds the period. Hypo events are detected over
///   the period plus 24 h of context each side (`PeriodReadings.contextDuration`), so their limit
///   is the end of that window: an event can run past the period end, and the last reading before
///   "now" covers its full 5 minutes.
/// - Consecutive readings more than 15 minutes apart are separated by a **gap**. A gap ends every
///   run (in-range streak, low run, recovery run) and every hypo event. Spacing of 15 minutes or
///   less is bridged, the same way the chart draws a line across it (§7.5).
/// - The **duration** of a run of consecutive readings is the coverage end of its last reading minus
///   the timestamp of its first. With regular 5-minute data, three readings last 15 minutes.
///
/// Durations are time, not values: no glucose value is ever created for the bridged minutes (S1).
public enum Continuity {
    /// Nominal G7 reading interval (HANDOFF §6 "expected 5-min readings", §4.6).
    public static let readingInterval: TimeInterval = 5 * 60
    /// Largest spacing between consecutive readings that still counts as continuous (HANDOFF §6, §7.5).
    public static let maximumBridgedGap: TimeInterval = 15 * 60

    /// True when `later` comes more than `maximumBridgedGap` after `earlier`.
    public static func isGap(between earlier: Date, and later: Date) -> Bool {
        later.timeIntervalSince(earlier) > maximumBridgedGap
    }

    /// The end of the time covered by `readings[index]`, never after `limit` (see the type's
    /// documentation). `readings` must be ascending.
    static func coverageEnd(ofReadingAt index: Int, in readings: [CountedReading], notAfter limit: Date) -> Date {
        var end = readings[index].date.addingTimeInterval(readingInterval)
        if index + 1 < readings.count {
            end = min(end, readings[index + 1].date)
        }
        return min(end, limit)
    }
}
