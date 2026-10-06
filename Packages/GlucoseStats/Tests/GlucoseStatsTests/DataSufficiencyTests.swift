import XCTest
import GlucoseCore
@testable import GlucoseStats

final class DataSufficiencyTests: XCTestCase {

    private func sufficiency(readingCount: Int, spacingMinutes: Double = 5, interval: DateInterval, calendar: Calendar = Fixture.utc) -> DataSufficiency {
        let values = Array(repeating: GlucoseValue.mgdl(100), count: readingCount)
        let readings = Fixture.series(from: interval.start, spacingMinutes: spacingMinutes, values)
        return DataSufficiency(Fixture.period(readings, interval, calendar: calendar))
    }

    private let oneDay = DateInterval(start: Fixture.day0, duration: Fixture.day)

    func testFullDayIsHundredPercent() {
        // 86 400 s / 300 s = 288 expected; 288 present → 100 %.
        let result = sufficiency(readingCount: 288, interval: oneDay)
        XCTAssertEqual(result.expectedReadingCount, 288)
        XCTAssertEqual(result.presentReadingCount, 288)
        XCTAssertEqual(result.percent, 100)
        XCTAssertFalse(result.isBelowWarningThreshold)
    }

    func testWarningThresholdIsSeventyPercent() {
        XCTAssertEqual(DataSufficiency.warningThresholdPercent, 70)
        // 70 % of 288 = 201.6.
        //   201 / 288 × 100 = 69.791666… % → warning
        //   202 / 288 × 100 = 70.138888… % → no warning
        let below = sufficiency(readingCount: 201, interval: oneDay)
        XCTAssertEqual(below.percent!, 201.0 / 288.0 * 100, accuracy: 1e-12)
        XCTAssertTrue(below.isBelowWarningThreshold)

        let above = sufficiency(readingCount: 202, interval: oneDay)
        XCTAssertEqual(above.percent!, 202.0 / 288.0 * 100, accuracy: 1e-12)
        XCTAssertFalse(above.isBelowWarningThreshold)
    }

    func testExactlySeventyPercentIsNotAWarning() {
        // 50 min → 10 expected; 7 present → 70 % exactly. The warning is for "under 70 %".
        let result = sufficiency(readingCount: 7, interval: Fixture.interval(minutes: 50))
        XCTAssertEqual(result.expectedReadingCount, 10)
        XCTAssertEqual(result.percent, 70)
        XCTAssertFalse(result.isBelowWarningThreshold)
    }

    func testMoreReadingsThanExpectedCapsAtHundred() {
        // Readings every 2.5 min for 60 min → 24 present, 12 expected → 24/12 capped at 100 %.
        let result = sufficiency(readingCount: 24, spacingMinutes: 2.5, interval: Fixture.interval(minutes: 60))
        XCTAssertEqual(result.presentReadingCount, 24)
        XCTAssertEqual(result.expectedReadingCount, 12)
        XCTAssertEqual(result.percent, 100)
    }

    func testPartialIntervalRoundsExpectedDown() {
        // 12 min / 5 min = 2.4 → 2 expected; 2 present → 100 %.
        let result = sufficiency(readingCount: 2, interval: Fixture.interval(minutes: 12))
        XCTAssertEqual(result.expectedReadingCount, 2)
        XCTAssertEqual(result.percent, 100)
    }

    func testIntervalShorterThanOneReadingIntervalHasNoPercentAndWarns() {
        // 3 min → 0 expected. No percentage can be computed; the period counts as insufficient.
        let result = sufficiency(readingCount: 1, interval: Fixture.interval(minutes: 3))
        XCTAssertEqual(result.expectedReadingCount, 0)
        XCTAssertNil(result.percent)
        XCTAssertTrue(result.isBelowWarningThreshold)
    }

    func testEmptyInput() {
        let result = sufficiency(readingCount: 0, interval: oneDay)
        XCTAssertEqual(result.percent, 0)
        XCTAssertTrue(result.isBelowWarningThreshold)
    }

    func testSpringForwardDayExpects276Readings() {
        // Mar 8 2026, New York: 00:00 EST → Mar 9 00:00 EDT = 23 h = 82 800 s → 82 800 / 300 = 276.
        let day = DateInterval(start: Fixture.springForwardDayStart, duration: 23 * Fixture.hour)
        let result = sufficiency(readingCount: 276, interval: day, calendar: Fixture.newYork)
        XCTAssertEqual(result.expectedReadingCount, 276)
        XCTAssertEqual(result.percent, 100)
    }

    func testFallBackDayExpects300Readings() {
        // Nov 1 2026, New York: 25 h = 90 000 s → 300 expected. A naive 24 h count (288 present)
        // is 288 / 300 × 100 = 96 %, not 100 %.
        let day = DateInterval(start: Fixture.fallBackDayStart, duration: 25 * Fixture.hour)
        let result = sufficiency(readingCount: 288, interval: day, calendar: Fixture.newYork)
        XCTAssertEqual(result.expectedReadingCount, 300)
        XCTAssertEqual(result.percent, 96)
    }
}
