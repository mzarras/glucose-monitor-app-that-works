// Time in ranges (International Consensus on Time in Range; Battelino et al., Diabetes Care
// 2019;42:1593–1603, Table 2 "Standardized CGM Metrics for Clinical Care", items 6–10) and time in
// tight range 70–140 (HANDOFF §6).

import GlucoseCore

/// A count of readings and its share of all counted readings in the period.
public struct RangeShare: Sendable, Equatable {
    public let count: Int
    /// `count / readingCount × 100`, unrounded; `nil` when the period has no readings.
    public let percent: Double?
}

/// Share of readings in each consensus bin. Bins come from `GlucoseBand` / `GlucoseThresholds`
/// (GlucoseCore), so stats, UI and widgets agree.
///
/// - The denominator is every counted reading, LOW and HIGH flags included.
/// - LOW counts in `veryLow` (< 54) and HIGH in `veryHigh` (> 250) (S4). Neither is ever in range,
///   in tight range, or given a number.
/// - Any numeric value is binned by its band, including values outside the sensor's 40–400 that
///   could arrive in imported history.
/// - "Time in range" is the share of readings, as HANDOFF §6 defines it; with 5-minute data each
///   reading stands for five minutes.
public struct RangeDistribution: Sendable, Equatable {
    public let readingCount: Int
    /// < 54 mg/dL and LOW.
    public let veryLow: RangeShare
    /// 54–69 mg/dL.
    public let low: RangeShare
    /// 70–180 mg/dL: time in range (TIR).
    public let inRange: RangeShare
    /// 181–250 mg/dL.
    public let high: RangeShare
    /// > 250 mg/dL and HIGH.
    public let veryHigh: RangeShare
    /// 70–140 mg/dL: time in tight range (TITR). A subset of `inRange`.
    public let tightRange: RangeShare
    /// < 70 mg/dL (`veryLow` + `low`): time below range (TBR).
    public let below70: RangeShare
    /// > 180 mg/dL (`high` + `veryHigh`): time above range (TAR).
    public let above180: RangeShare

    public init(_ period: PeriodReadings) {
        var veryLowCount = 0
        var lowCount = 0
        var inRangeCount = 0
        var highCount = 0
        var veryHighCount = 0
        var tightCount = 0
        period.forEachReading { _, reading in
            switch reading.band {
            case .veryLow: veryLowCount += 1
            case .low: lowCount += 1
            case .inRange: inRangeCount += 1
            case .high: highCount += 1
            case .veryHigh: veryHighCount += 1
            }
            if let value = reading.value.numericMgdl,
               value >= GlucoseThresholds.lowBelow, value <= GlucoseThresholds.tightRangeUpperBound {
                tightCount += 1
            }
        }
        let total = period.readings.count
        func share(_ count: Int) -> RangeShare { RangeShare(count: count, percent: percentage(count, of: total)) }

        readingCount = total
        veryLow = share(veryLowCount)
        low = share(lowCount)
        inRange = share(inRangeCount)
        high = share(highCount)
        veryHigh = share(veryHighCount)
        tightRange = share(tightCount)
        below70 = share(veryLowCount + lowCount)
        above180 = share(highCount + veryHighCount)
    }

    /// The share for one consensus bin.
    public func share(of band: GlucoseBand) -> RangeShare {
        switch band {
        case .veryLow: return veryLow
        case .low: return low
        case .inRange: return inRange
        case .high: return high
        case .veryHigh: return veryHigh
        }
    }
}
