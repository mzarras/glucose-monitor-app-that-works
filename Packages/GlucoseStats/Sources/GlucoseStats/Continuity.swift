// Continuity rules shared by every duration-based metric: hypo events, the in-range streak.
// HANDOFF §6 ("gaps > 15 min break the run") and §7.5 ("Gaps > 15 min break the line").

import Foundation

/// How readings join into continuous stretches of time.
///
/// - A reading **covers** the time from its timestamp until the earliest of: 5 minutes later (the
///   G7's reading interval), the next counted reading, or the end of the period. Coverage never
///   reaches past the period's end, so no duration can exceed the period.
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

    /// The end of the time covered by `period.readings[index]` (see the type's documentation).
    static func coverageEnd(ofReadingAt index: Int, in period: PeriodReadings) -> Date {
        let readings = period.readings
        var end = readings[index].date.addingTimeInterval(readingInterval)
        if index + 1 < readings.count {
            end = min(end, readings[index + 1].date)
        }
        return min(end, period.interval.end)
    }
}
