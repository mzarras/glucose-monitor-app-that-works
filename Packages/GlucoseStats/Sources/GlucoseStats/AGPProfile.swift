// Ambulatory Glucose Profile: 5th/25th/50th/75th/95th percentiles by local time of day in 15-minute
// buckets (HANDOFF §6; the AGP report's median, 25–75 and 5–95 bands, Battelino et al., Diabetes Care
// 2019;42:1593, section "Use of the Ambulatory Glucose Profile", Figure 2).

import GlucoseCore

/// Percentiles of one 15-minute slot of the day, pooled over every day of the period.
public struct AGPBucket: Sendable, Equatable {
    /// Minutes after local midnight at which the bucket starts: 0, 15, …, 1 425.
    public let startMinuteOfDay: Int
    /// Readings pooled into the bucket.
    public let readingCount: Int
    /// Each percentile is one of the bucket's actual readings (nearest rank), so it can be the LOW
    /// or HIGH flag (S4). `nil` when the bucket is empty.
    public let p5: GlucoseValue?
    public let p25: GlucoseValue?
    public let p50: GlucoseValue?
    public let p75: GlucoseValue?
    public let p95: GlucoseValue?
}

/// The AGP percentile profile of a period.
///
/// - **Buckets** are by local wall-clock time (`CountedReading.secondOfDay`): on a fall-back day
///   both passes through 01:00–01:59 land in the 01:00 buckets; on a spring-forward day the
///   02:00 buckets get nothing from that day.
/// - **Percentile method: nearest rank.** For a bucket with n readings in ascending order and a
///   percentile p, the result is the r-th smallest reading with r = ⌈p × n / 100⌉. Every
///   percentile is therefore a value that was actually read: nothing is interpolated between
///   readings (S1), and a LOW or HIGH flag is returned as the flag, never as 40 or 400 (S4).
///   Ordering: every LOW sorts below every number, every HIGH above.
///   Consequence: with an even n the median is the lower middle value, not the average of the two
///   middle values (tested in AGPTests).
/// - Smoothing for the chart is a separate, display-only function (`AGPDisplaySmoothing`); this
///   profile is never smoothed.
public struct AGPProfile: Sendable, Equatable {
    public static let bucketMinutes = 15
    public static let bucketCount = 24 * 60 / bucketMinutes // 96
    public static let percentiles = [5, 25, 50, 75, 95]

    /// `bucketCount` buckets, midnight first.
    public let buckets: [AGPBucket]

    init(buckets: [AGPBucket]) {
        self.buckets = buckets
    }

    public init(_ period: PeriodReadings) {
        let bucketSeconds = Self.bucketMinutes * 60
        var belowRangeCounts = Array(repeating: 0, count: Self.bucketCount)
        var aboveRangeCounts = Array(repeating: 0, count: Self.bucketCount)
        var numericValues = Array(repeating: [Int](), count: Self.bucketCount)
        period.forEachReading { _, reading in
            let index = reading.secondOfDay / bucketSeconds
            switch reading.value {
            case .belowRange: belowRangeCounts[index] += 1
            case .aboveRange: aboveRangeCounts[index] += 1
            case .mgdl(let value): numericValues[index].append(value)
            }
        }
        buckets = (0..<Self.bucketCount).map { index in
            let ordered = OrderedValues(
                belowRangeCount: belowRangeCounts[index],
                sortedMgdl: OrderedValues.sortedAscending(numericValues[index]),
                aboveRangeCount: aboveRangeCounts[index]
            )
            return AGPBucket(
                startMinuteOfDay: index * Self.bucketMinutes,
                readingCount: ordered.count,
                p5: ordered.nearestRank(5),
                p25: ordered.nearestRank(25),
                p50: ordered.nearestRank(50),
                p75: ordered.nearestRank(75),
                p95: ordered.nearestRank(95)
            )
        }
    }

    /// Nearest-rank percentile of any values (see the type's documentation). `nil` for no values or
    /// a percentile outside 1…100.
    public static func nearestRankPercentile(_ percentile: Int, of values: [GlucoseValue]) -> GlucoseValue? {
        var belowRangeCount = 0
        var aboveRangeCount = 0
        var numeric: [Int] = []
        for value in values {
            switch value {
            case .belowRange: belowRangeCount += 1
            case .aboveRange: aboveRangeCount += 1
            case .mgdl(let mgdl): numeric.append(mgdl)
            }
        }
        let ordered = OrderedValues(
            belowRangeCount: belowRangeCount, sortedMgdl: OrderedValues.sortedAscending(numeric), aboveRangeCount: aboveRangeCount
        )
        return ordered.nearestRank(percentile)
    }
}

/// Glucose values in ascending order, kept as three parts so LOW and HIGH never become numbers:
/// all LOWs, then the numeric values sorted, then all HIGHs.
struct OrderedValues {
    let belowRangeCount: Int
    let sortedMgdl: [Int]
    let aboveRangeCount: Int

    var count: Int { belowRangeCount + sortedMgdl.count + aboveRangeCount }

    /// The r-th smallest value with r = ⌈p × n / 100⌉ (1-based); `nil` if empty or p ∉ 1…100.
    func nearestRank(_ percentile: Int) -> GlucoseValue? {
        guard count > 0, (1...100).contains(percentile) else { return nil }
        // Integer ceiling of p × n / 100. p ≥ 1 and n ≥ 1, so rank ≥ 1; p ≤ 100, so rank ≤ n.
        let rank = (percentile * count + 99) / 100
        if rank <= belowRangeCount { return .belowRange }
        let numericRank = rank - belowRangeCount
        if numericRank <= sortedMgdl.count { return .mgdl(sortedMgdl[numericRank - 1]) }
        return .aboveRange
    }

    /// Spreads (largest − smallest, mg/dL) above this are sorted with `sorted()` instead of a tally.
    /// Sensor values span at most 360 (40–400); only corrupt imported history can exceed this.
    static let maximumTallySpread = 4_096

    /// Exactly `values.sorted()` (AGPTests compares the two on thousands of arrays).
    ///
    /// Computed by tallying how many readings have each mg/dL between the smallest and the largest
    /// value, then writing each value out as many times as it was counted: a counting sort, exact
    /// for integers. Why not `sorted()`: in the unoptimised builds that `swift test` and the test
    /// gate time, the standard library's generic sort costs ~20 ms for the 96 buckets of a 90-day
    /// period, most of the 90-day budget (docs/statistics.md, Performance).
    static func sortedAscending(_ values: [Int]) -> [Int] {
        guard var smallest = values.first else { return [] }
        var largest = smallest
        for value in values {
            if value < smallest { smallest = value }
            if value > largest { largest = value }
        }
        let (spread, overflow) = largest.subtractingReportingOverflow(smallest)
        guard !overflow, spread <= maximumTallySpread else { return values.sorted() }

        var tally = Array(repeating: 0, count: spread + 1)
        for value in values {
            tally[value - smallest] += 1
        }
        var sorted: [Int] = []
        sorted.reserveCapacity(values.count)
        for offset in 0...spread {
            var remaining = tally[offset]
            while remaining > 0 {
                sorted.append(smallest + offset)
                remaining -= 1
            }
        }
        return sorted
    }
}
