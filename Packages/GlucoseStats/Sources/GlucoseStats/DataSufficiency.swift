// Data sufficiency: share of expected 5-minute readings present (HANDOFF §6). The 70 % threshold is
// the consensus "Percentage of time CGM is active (recommend 70% of data from 14 days)" (Battelino
// et al., Diabetes Care 2019;42:1593, Table 2 "Standardized CGM Metrics for Clinical Care").

import Foundation

public struct DataSufficiency: Sendable, Equatable {
    /// Periods under this percentage show the data-sufficiency warning.
    public static let warningThresholdPercent: Double = 70

    /// Counted readings in the period (after duplicate removal).
    public let presentReadingCount: Int
    /// ⌊ period length in real elapsed seconds / 300 ⌋. Real elapsed time, not wall-clock hours:
    /// a 23-hour spring-forward day expects 276 readings and a 25-hour fall-back day 300.
    public let expectedReadingCount: Int
    /// min(present, expected) / expected × 100, capped at 100 so more-frequent data never reads as
    /// "more than complete"; `nil` when the period is shorter than one reading interval.
    public let percent: Double?
    /// `percent < 70`. Also true when `percent` is `nil`: too little time to judge is insufficient.
    public let isBelowWarningThreshold: Bool

    public init(_ period: PeriodReadings) {
        let present = period.readings.count
        let expected = Int((period.interval.duration / Continuity.readingInterval).rounded(.down))
        let percent = percentage(min(present, expected), of: expected)

        presentReadingCount = present
        expectedReadingCount = expected
        self.percent = percent
        isBelowWarningThreshold = (percent ?? 0) < Self.warningThresholdPercent
    }
}
