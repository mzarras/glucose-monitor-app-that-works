// Light smoothing of the AGP percentile lines, for drawing the "A typical day" chart only
// (HANDOFF §6 "lightly smoothed for display only").
//
// S1: the output of this file is chart geometry, not glucose data. It is a separate type
// (`AGPDisplayValue`) that no metric, `PeriodStatistics` or `PeriodComparison` contains
// (test_S1_statisticsNeverContainDisplaySmoothedValues), and it never replaces or modifies the
// profile it reads (test_S1_displaySmoothingLeavesTheProfileUntouched).

import GlucoseCore

/// A point on a smoothed AGP line. Mirrors `GlucoseValue` but with a fractional mg/dL, because a
/// weighted average of readings is not a reading.
public enum AGPDisplayValue: Sendable, Equatable {
    case mgdl(Double)
    /// The bucket's percentile is the sensor LOW flag: draw at the chart floor; never a number.
    case belowRange
    /// The bucket's percentile is the sensor HIGH flag: draw at the chart ceiling; never a number.
    case aboveRange
}

/// One bucket's smoothed percentile lines. `nil` = empty bucket: leave a gap in the chart.
public struct AGPDisplayBucket: Sendable, Equatable {
    public let startMinuteOfDay: Int
    public let p5: AGPDisplayValue?
    public let p25: AGPDisplayValue?
    public let p50: AGPDisplayValue?
    public let p75: AGPDisplayValue?
    public let p95: AGPDisplayValue?
}

public enum AGPDisplaySmoothing {
    /// Each percentile line smoothed independently with 1-2-1 weights over the bucket and its two
    /// neighbours (the day wraps: 23:45 neighbours 00:00):
    ///
    ///     smoothed[i] = (v[i−1] + 2·v[i] + v[i+1]) / 4
    ///
    /// - An empty bucket stays empty (`nil`): smoothing never fills a gap (S1).
    /// - A LOW or HIGH bucket stays the flag (S4).
    /// - A neighbour that is empty or a flag is left out and the weights renormalised, e.g.
    ///   (2·v[i] + v[i+1]) / 3. A flag is never averaged as 40 or 400.
    public static func smoothedForDisplay(_ profile: AGPProfile) -> [AGPDisplayBucket] {
        let buckets = profile.buckets
        let count = buckets.count
        return buckets.indices.map { index in
            let previous = buckets[(index + count - 1) % count]
            let current = buckets[index]
            let next = buckets[(index + 1) % count]
            return AGPDisplayBucket(
                startMinuteOfDay: current.startMinuteOfDay,
                p5: smooth(previous.p5, current.p5, next.p5),
                p25: smooth(previous.p25, current.p25, next.p25),
                p50: smooth(previous.p50, current.p50, next.p50),
                p75: smooth(previous.p75, current.p75, next.p75),
                p95: smooth(previous.p95, current.p95, next.p95)
            )
        }
    }

    static func smooth(_ previous: GlucoseValue?, _ current: GlucoseValue?, _ next: GlucoseValue?) -> AGPDisplayValue? {
        switch current {
        case nil: return nil
        case .belowRange?: return .belowRange
        case .aboveRange?: return .aboveRange
        case .mgdl(let value)?:
            var weightedSum = 2 * Double(value)
            var totalWeight = 2.0
            if case .mgdl(let neighbour)? = previous {
                weightedSum += Double(neighbour)
                totalWeight += 1
            }
            if case .mgdl(let neighbour)? = next {
                weightedSum += Double(neighbour)
                totalWeight += 1
            }
            return .mgdl(weightedSum / totalWeight)
        }
    }
}
