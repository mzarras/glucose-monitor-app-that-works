import XCTest
import GlucoseCore
@testable import GlucoseStats

final class PeriodComparisonTests: XCTestCase {

    /// Now = Jan 6 12:00 UTC. "1 D" = [Jan 6 00:00, 12:00); preceding = [Jan 5 00:00, Jan 6 00:00).
    private let now = Fixture.day0.addingTimeInterval(Fixture.day + 12 * Fixture.hour)
    private let jan6 = Fixture.day0.addingTimeInterval(Fixture.day)

    /// Jan 5 08:00–08:15: 100 100 200 200 (previous).  Jan 6 08:00–08:15: 100 100 100 200 (current).
    /// Plus one reading after `now` (Jan 6 13:00) that must be ignored.
    private var readings: [GlucoseReading] {
        Fixture.series(from: Fixture.day0.addingTimeInterval(8 * Fixture.hour), Fixture.mg(100, 100, 200, 200))
            + Fixture.series(from: jan6.addingTimeInterval(8 * Fixture.hour), Fixture.mg(100, 100, 100, 200))
            + [Fixture.reading(jan6.addingTimeInterval(13 * Fixture.hour), .belowRange)]
    }

    func testDeltasAreCurrentMinusPrevious() {
        let comparison = GlucoseStatistics.compare(readings: readings, period: .today, now: now, options: Fixture.utcOptions)

        XCTAssertEqual(comparison.current.interval, DateInterval(start: jan6, end: now))
        XCTAssertEqual(comparison.previous.interval, DateInterval(start: Fixture.day0, end: jan6))
        XCTAssertEqual(comparison.current.readingCount, 4, "the reading after now is not counted")

        // Time in range: current 3/4 = 75 %, previous 2/4 = 50 % → +25 points.
        XCTAssertEqual(comparison.inRangeDeltaPoints, 25)
        // 181–250: current 1/4 = 25 %, previous 2/4 = 50 % → −25 points. Above 180 likewise.
        XCTAssertEqual(comparison.highDeltaPoints, -25)
        XCTAssertEqual(comparison.above180DeltaPoints, -25)
        XCTAssertEqual(comparison.veryLowDeltaPoints, 0)
        XCTAssertEqual(comparison.lowDeltaPoints, 0)
        XCTAssertEqual(comparison.veryHighDeltaPoints, 0)
        XCTAssertEqual(comparison.below70DeltaPoints, 0)
        // Tight 70–140: current 3/4 = 75 %, previous 2/4 = 50 % → +25.
        XCTAssertEqual(comparison.tightRangeDeltaPoints, 25)

        // Mean: current 500/4 = 125, previous 600/4 = 150 → −25 mg/dL.
        XCTAssertEqual(comparison.meanDeltaMgdl, -25)
        // SD: previous [100,100,200,200]: Σ dev² = 4 × 2 500 = 10 000 → √(10 000/3) = 57.735026918962575
        //     current  [100,100,100,200]: Σ dev² = 3 × 625 + 5 625 = 7 500 → √(7 500/3) = 50
        //     delta = 50 − 57.735026918962575 = −7.735026918962575
        XCTAssertEqual(comparison.standardDeviationDeltaMgdl!, -7.735026918962575, accuracy: 1e-9)
        // CV: previous 57.735026918962575/150 × 100 = 38.49001794597505; current 50/125 × 100 = 40
        //     delta = 1.50998205402495 points
        XCTAssertEqual(comparison.coefficientOfVariationDeltaPoints!, 1.50998205402495, accuracy: 1e-9)
        // GMI is withheld for 1-day periods.
        XCTAssertNil(comparison.gmiDeltaPoints)
        // Sufficiency: current 4 / (12 h / 5 min = 144) × 100 = 2.777…; previous 4/288 × 100 = 1.388… → +1.388…
        XCTAssertEqual(comparison.dataSufficiencyDeltaPoints!, 400.0 / 144.0 - 400.0 / 288.0, accuracy: 1e-12)
        // No lows in either period.
        XCTAssertEqual(comparison.level1EventCountDelta, 0)
        XCTAssertEqual(comparison.level2EventCountDelta, 0)
        XCTAssertNil(comparison.level1MeanDurationDeltaSeconds)
        // All readings are at 08:00 → none overnight; day TIR delta equals the overall one.
        XCTAssertNil(comparison.overnightInRangeDeltaPoints)
        XCTAssertEqual(comparison.dayInRangeDeltaPoints, 25)
        // Streak: current 08:00–08:15 (15 min), previous 08:00–08:10 (10 min) → +300 s.
        XCTAssertEqual(comparison.longestInRangeStreakDeltaSeconds, 300)
        XCTAssertFalse(comparison.previousHasSufficientData)
    }

    func testEmptyPreviousPeriodGivesNoDeltas() {
        // Only current readings. Counts are unknown for a period without data, so no count deltas either.
        let current = Fixture.series(from: jan6.addingTimeInterval(8 * Fixture.hour), Fixture.mg(65, 65, 65, 100, 100, 100))
        let comparison = GlucoseStatistics.compare(readings: current, period: .today, now: now, options: Fixture.utcOptions)

        XCTAssertEqual(comparison.current.hypoEvents.level1.count, 1)
        XCTAssertEqual(comparison.previous.readingCount, 0)
        XCTAssertNil(comparison.inRangeDeltaPoints)
        XCTAssertNil(comparison.meanDeltaMgdl)
        XCTAssertNil(comparison.level1EventCountDelta)
        XCTAssertNil(comparison.level2EventCountDelta)
        XCTAssertNil(comparison.longestInRangeStreakDeltaSeconds)
        XCTAssertFalse(comparison.previousHasSufficientData)
    }

    func testEventCountAndDurationDeltas() {
        // Previous day: one 15-min level 1 event. Current: two events, 15 and 20 min (mean 17.5 min).
        //   count delta +1; mean duration delta 1 050 − 900 = +150 s.
        let previous = Fixture.series(from: Fixture.day0.addingTimeInterval(3 * Fixture.hour), Fixture.mg(65, 65, 65, 100, 100, 100))
        let current = Fixture.series(
            from: jan6.addingTimeInterval(3 * Fixture.hour),
            Fixture.mg(65, 65, 65, 100, 100, 100, 65, 65, 65, 65, 100, 100, 100)
        )
        let comparison = GlucoseStatistics.compare(readings: previous + current, period: .today, now: now, options: Fixture.utcOptions)
        XCTAssertEqual(comparison.level1EventCountDelta, 1)
        XCTAssertEqual(comparison.level1MeanDurationDeltaSeconds, 150)
        // Both periods' readings are at 03:00 → all overnight, so the overnight delta exists and the day one does not.
        XCTAssertNotNil(comparison.overnightInRangeDeltaPoints)
        XCTAssertNil(comparison.dayInRangeDeltaPoints)
    }

    func testFourteenDayComparisonHasGMIDelta() {
        // 28 days of flat data: previous 14 days at 150 mg/dL, current 14 days at 100 mg/dL.
        //   GMI previous 3.31 + 0.02392 × 150 = 6.898; current 3.31 + 0.02392 × 100 = 5.702 → −1.196 points.
        let start = Fixture.day0
        let now = start.addingTimeInterval(28 * Fixture.day)
        let previous = Fixture.series(from: start, spacingMinutes: 60, Array(repeating: .mgdl(150), count: 14 * 24))
        let current = Fixture.series(from: start.addingTimeInterval(14 * Fixture.day), spacingMinutes: 60, Array(repeating: .mgdl(100), count: 14 * 24))
        // Evaluated at day 27 23:59:59: today is day 27, so "14 D" = [day 14, now) and the preceding
        // 14 days are [day 0, day 14).
        let comparison = GlucoseStatistics.compare(readings: previous + current, period: .fourteenDays, now: now.addingTimeInterval(-1), options: Fixture.utcOptions)
        XCTAssertEqual(comparison.current.interval.start, start.addingTimeInterval(14 * Fixture.day))
        XCTAssertEqual(comparison.previous.interval, DateInterval(start: start, duration: 14 * Fixture.day))
        XCTAssertEqual(comparison.gmiDeltaPoints!, -1.196, accuracy: 1e-9)
    }
}
