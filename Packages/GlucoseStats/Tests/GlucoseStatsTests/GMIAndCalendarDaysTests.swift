import XCTest
import GlucoseCore
@testable import GlucoseStats

final class GMIAndCalendarDaysTests: XCTestCase {

    // MARK: GMI formula (Bergenstal et al. 2018)

    func testFormula() {
        // GMI (%) = 3.31 + 0.02392 × mean
        //   mean 150 → 3.31 + 3.588   = 6.898
        //   mean 100 → 3.31 + 2.392   = 5.702
        //   mean 154 → 3.31 + 3.68368 = 6.99368 (Bergenstal Table 1 lists 154 mg/dL → 7.0 %)
        XCTAssertEqual(GlucoseManagementIndicator.percent(forMeanMgdl: 150), 6.898, accuracy: 1e-12)
        XCTAssertEqual(GlucoseManagementIndicator.percent(forMeanMgdl: 100), 5.702, accuracy: 1e-12)
        XCTAssertEqual(GlucoseManagementIndicator.percent(forMeanMgdl: 154), 6.99368, accuracy: 1e-12)
    }

    func testMeaningfulAndReportedOnlyFromFourteenCalendarDays() {
        XCTAssertEqual(GlucoseManagementIndicator.minimumCalendarDays, 14)

        let thirteen = GlucoseManagementIndicator(meanMgdl: 150, calendarDayCount: 13)
        XCTAssertFalse(thirteen.isMeaningful)
        XCTAssertNil(thirteen.percent, "GMI is withheld below 14 days so it cannot be displayed by mistake")

        let fourteen = GlucoseManagementIndicator(meanMgdl: 150, calendarDayCount: 14)
        XCTAssertTrue(fourteen.isMeaningful)
        XCTAssertEqual(fourteen.percent!, 6.898, accuracy: 1e-12)

        let ninety = GlucoseManagementIndicator(meanMgdl: 100, calendarDayCount: 90)
        XCTAssertEqual(ninety.percent!, 5.702, accuracy: 1e-12)
    }

    func testNoMeanMeansNoGMI() {
        let result = GlucoseManagementIndicator(meanMgdl: nil, calendarDayCount: 14)
        XCTAssertTrue(result.isMeaningful)
        XCTAssertNil(result.percent)
    }

    // MARK: Calendar days touched by an interval

    func testWholeDays() {
        XCTAssertEqual(CalendarDays.count(in: DateInterval(start: Fixture.day0, duration: Fixture.day), calendar: Fixture.utc), 1)
        XCTAssertEqual(CalendarDays.count(in: DateInterval(start: Fixture.day0, duration: 14 * Fixture.day), calendar: Fixture.utc), 14)
        XCTAssertEqual(CalendarDays.count(in: DateInterval(start: Fixture.day0, duration: 13 * Fixture.day), calendar: Fixture.utc), 13)
    }

    func testPartialLastDayCounts() {
        // Trends "14 D" on Jan 18 at 12:35: [Jan 5 00:00, Jan 18 12:35) touches Jan 5 … Jan 18 = 14 dates,
        // although only 13 d 12 h 35 m have elapsed.
        let interval = DateInterval(start: Fixture.day0, duration: 13 * Fixture.day + 12 * Fixture.hour + 35 * Fixture.minute)
        XCTAssertEqual(CalendarDays.count(in: interval, calendar: Fixture.utc), 14)
    }

    func testStartMidDay() {
        // [Jan 5 12:00, Jan 6 01:00) touches Jan 5 and Jan 6.
        let interval = DateInterval(start: Fixture.day0.addingTimeInterval(12 * Fixture.hour), duration: 13 * Fixture.hour)
        XCTAssertEqual(CalendarDays.count(in: interval, calendar: Fixture.utc), 2)
    }

    func testEmptyIntervalTouchesNoDays() {
        XCTAssertEqual(CalendarDays.count(in: DateInterval(start: Fixture.day0, duration: 0), calendar: Fixture.utc), 0)
    }

    func testDSTDaysAreStillOneDayEach() {
        // 23-hour and 25-hour days are one calendar day each.
        let spring = DateInterval(start: Fixture.springForwardDayStart, duration: 23 * Fixture.hour)
        let fall = DateInterval(start: Fixture.fallBackDayStart, duration: 25 * Fixture.hour)
        XCTAssertEqual(CalendarDays.count(in: spring, calendar: Fixture.newYork), 1)
        XCTAssertEqual(CalendarDays.count(in: fall, calendar: Fixture.newYork), 1)
        // Mar 1 00:00 EST → Mar 15 00:00 EDT: 14 dates, 14 × 24 − 1 = 335 hours.
        let marchStart = Fixture.newYork.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let fortnight = DateInterval(start: marchStart, duration: 335 * Fixture.hour)
        XCTAssertEqual(CalendarDays.count(in: fortnight, calendar: Fixture.newYork), 14)
    }
}
