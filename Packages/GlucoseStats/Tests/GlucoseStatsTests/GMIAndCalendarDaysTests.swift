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

    func testDayThatStartsAt0100IsStillOneDay() {
        // America/Santiago, 2026-09-06: clocks jump 00:00 → 01:00, so the date starts at 01:00 and lasts 23 h.
        // Counted by y/m/d, not by whole 24-hour steps from the day's first instant.
        let calendar = Fixture.santiago
        XCTAssertEqual(CalendarDays.count(in: DateInterval(start: Fixture.santiagoSep6, end: Fixture.santiagoSep7), calendar: calendar), 1)
        XCTAssertEqual(CalendarDays.count(in: DateInterval(start: Fixture.santiagoSep6, duration: 11 * Fixture.hour), calendar: calendar), 1)
        XCTAssertEqual(CalendarDays.count(in: DateInterval(start: Fixture.santiagoSep5, end: Fixture.santiagoSep8), calendar: calendar), 3)
        // Ending exactly at Sep 6's first instant (01:00) does not touch Sep 6.
        XCTAssertEqual(CalendarDays.count(in: DateInterval(start: Fixture.santiagoSep5, end: Fixture.santiagoSep6), calendar: calendar), 1)
    }

    func testLocalDateNotUTCDateDecidesTheDay() {
        // Regression: Foundation's `ordinality(of: .day, in: .era)` numbers days by UTC regardless of the
        // calendar's time zone (Swift 6.2.3 / macOS 26). Counting must follow local dates:
        //   New York [Jan 5 00:00 EST, Jan 5 23:30 EST): 23:30 EST is Jan 6 04:30 UTC, still Jan 5 locally → 1
        //   Tokyo    [Jan 5 00:00 JST, Jan 5 10:00 JST): 00:00 JST is Jan 4 15:00 UTC, already Jan 5 locally → 1
        let newYorkJan5 = Fixture.day0.addingTimeInterval(5 * Fixture.hour) // 00:00 EST = 05:00 UTC
        XCTAssertEqual(CalendarDays.count(in: DateInterval(start: newYorkJan5, duration: 23.5 * Fixture.hour), calendar: Fixture.newYork), 1)
        let tokyo = Fixture.calendar("Asia/Tokyo")
        let tokyoJan5 = Fixture.day0.addingTimeInterval(-9 * Fixture.hour) // 00:00 JST = Jan 4 15:00 UTC
        XCTAssertEqual(CalendarDays.count(in: DateInterval(start: tokyoJan5, duration: 10 * Fixture.hour), calendar: tokyo), 1)
        XCTAssertEqual(CalendarDays.count(in: DateInterval(start: tokyoJan5, duration: 14 * Fixture.day), calendar: tokyo), 14)
    }

    func testNonGregorianCalendarAcrossAnEraChange() {
        // Japanese calendar, Asia/Tokyo: Heisei ended 2019-04-30 and Reiwa began 2019-05-01, so that
        // calendar's day-of-era ordinal restarts (Apr 29 → 11 069, May 3 → 3). Dates are counted with a
        // Gregorian calendar in the same time zone: [Apr 29, May 3) → Apr 29, 30, May 1, 2 = 4.
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let apr29 = Date(timeIntervalSince1970: 1_556_463_600) // 2019-04-29 00:00 JST
        let may3 = Date(timeIntervalSince1970: 1_556_809_200)  // 2019-05-03 00:00 JST
        XCTAssertEqual(CalendarDays.count(in: DateInterval(start: apr29, end: may3), calendar: japanese), 4)
        // "14 D" on May 10 at noon spans Apr 27 … May 10: 14 dates across the era change → GMI shown.
        let may10Noon = may3.addingTimeInterval(7 * Fixture.day + 12 * Fixture.hour)
        let fortnight = CalendarDayPeriod.fourteenDays.interval(endingAt: may10Noon, calendar: japanese)
        XCTAssertEqual(CalendarDays.count(in: fortnight, calendar: japanese), 14)
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
