// Period comparison (HANDOFF §6: "Each metric vs the immediately preceding equal-length period").

import Foundation

/// Every metric of `current` minus the same metric of `previous`.
///
/// Units: `…DeltaPoints` are percentage points (75 % vs 50 % → +25), `…DeltaMgdl` mg/dL,
/// `…DeltaSeconds` seconds, `…CountDelta` events. A delta is `nil` when either side has no value
/// (e.g. no readings, GMI withheld). Event-count deltas are `nil` when either period has no
/// readings, because "0 events" in a period without data is unknown, not zero.
public struct PeriodComparison: Sendable, Equatable {
    public let current: PeriodStatistics
    public let previous: PeriodStatistics

    public let veryLowDeltaPoints: Double?
    public let lowDeltaPoints: Double?
    /// Time in range 70–180: the Trends hero delta ("+4 pts vs prior 14d").
    public let inRangeDeltaPoints: Double?
    public let highDeltaPoints: Double?
    public let veryHighDeltaPoints: Double?
    public let tightRangeDeltaPoints: Double?
    public let below70DeltaPoints: Double?
    public let above180DeltaPoints: Double?

    public let meanDeltaMgdl: Double?
    public let standardDeviationDeltaMgdl: Double?
    public let coefficientOfVariationDeltaPoints: Double?
    public let gmiDeltaPoints: Double?
    public let dataSufficiencyDeltaPoints: Double?

    public let level1EventCountDelta: Int?
    public let level2EventCountDelta: Int?
    public let level1MeanDurationDeltaSeconds: TimeInterval?
    public let level2MeanDurationDeltaSeconds: TimeInterval?

    public let overnightInRangeDeltaPoints: Double?
    public let dayInRangeDeltaPoints: Double?
    public let longestInRangeStreakDeltaSeconds: TimeInterval?

    /// The previous period meets the 70 % data-sufficiency threshold. When false, the UI should
    /// say the comparison rests on thin data (or not show it).
    public var previousHasSufficientData: Bool { !previous.dataSufficiency.isBelowWarningThreshold }

    public init(current: PeriodStatistics, previous: PeriodStatistics) {
        func delta(_ now: Double?, _ before: Double?) -> Double? {
            guard let now, let before else { return nil }
            return now - before
        }
        let bothHaveReadings = current.readingCount > 0 && previous.readingCount > 0

        self.current = current
        self.previous = previous

        veryLowDeltaPoints = delta(current.ranges.veryLow.percent, previous.ranges.veryLow.percent)
        lowDeltaPoints = delta(current.ranges.low.percent, previous.ranges.low.percent)
        inRangeDeltaPoints = delta(current.ranges.inRange.percent, previous.ranges.inRange.percent)
        highDeltaPoints = delta(current.ranges.high.percent, previous.ranges.high.percent)
        veryHighDeltaPoints = delta(current.ranges.veryHigh.percent, previous.ranges.veryHigh.percent)
        tightRangeDeltaPoints = delta(current.ranges.tightRange.percent, previous.ranges.tightRange.percent)
        below70DeltaPoints = delta(current.ranges.below70.percent, previous.ranges.below70.percent)
        above180DeltaPoints = delta(current.ranges.above180.percent, previous.ranges.above180.percent)

        meanDeltaMgdl = delta(current.meanAndVariability.meanMgdl, previous.meanAndVariability.meanMgdl)
        standardDeviationDeltaMgdl = delta(
            current.meanAndVariability.standardDeviationMgdl, previous.meanAndVariability.standardDeviationMgdl
        )
        coefficientOfVariationDeltaPoints = delta(
            current.meanAndVariability.coefficientOfVariationPercent, previous.meanAndVariability.coefficientOfVariationPercent
        )
        gmiDeltaPoints = delta(current.gmi.percent, previous.gmi.percent)
        dataSufficiencyDeltaPoints = delta(current.dataSufficiency.percent, previous.dataSufficiency.percent)

        level1EventCountDelta = bothHaveReadings ? current.hypoEvents.level1.count - previous.hypoEvents.level1.count : nil
        level2EventCountDelta = bothHaveReadings ? current.hypoEvents.level2.count - previous.hypoEvents.level2.count : nil
        level1MeanDurationDeltaSeconds = delta(current.hypoEvents.level1.meanDuration, previous.hypoEvents.level1.meanDuration)
        level2MeanDurationDeltaSeconds = delta(current.hypoEvents.level2.meanDuration, previous.hypoEvents.level2.meanDuration)

        overnightInRangeDeltaPoints = delta(
            current.overnightAndDay.overnight.inRangePercent, previous.overnightAndDay.overnight.inRangePercent
        )
        dayInRangeDeltaPoints = delta(current.overnightAndDay.day.inRangePercent, previous.overnightAndDay.day.inRangePercent)
        longestInRangeStreakDeltaSeconds = delta(
            current.longestInRangeStreak?.duration, previous.longestInRangeStreak?.duration
        )
    }
}
