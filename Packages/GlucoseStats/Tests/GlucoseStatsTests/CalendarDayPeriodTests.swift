import XCTest
import GlucoseCore
@testable import GlucoseStats

/// Trends periods (§7.3 item 2): N local calendar days ending now, compared with the N full days before.
final class CalendarDayPeriodTests: XCTestCase {

    private let calendar = Fixture.newYork
    /// 2026-03-10 12:35 EDT = 16:35 UTC. Two days after the spring-forward.
    private let now = Date(timeIntervalSince1970: 1_773_160_500)

    private func newYorkMidnight(month: Int, day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    func testChoicesAndValidation() {
        XCTAssertEqual(CalendarDayPeriod.trendsChoices.map(\.dayCount), [1, 3, 7, 14, 30, 90])
        XCTAssertEqual(CalendarDayPeriod.trendsDefault.dayCount, 14)
        XCTAssertEqual(CalendarDayPeriod.today.dayCount, 1)
        XCTAssertNil(CalendarDayPeriod(dayCount: 0))
        XCTAssertNil(CalendarDayPeriod(dayCount: -3))
        XCTAssertEqual(CalendarDayPeriod(dayCount: 3), CalendarDayPeriod.threeDays)
    }

    func testOneDayIsTodaySoFarAndComparesWithAllOfYesterday() {
        // Current: [Mar 10 00:00 EDT (04:00 UTC), 12:35 EDT). Preceding: [Mar 9 00:00 EDT, Mar 10 00:00 EDT) = 24 h.
        let current = CalendarDayPeriod.today.interval(endingAt: now, calendar: calendar)
        XCTAssertEqual(current, DateInterval(start: newYorkMidnight(month: 3, day: 10), end: now))
        XCTAssertEqual(current.start.timeIntervalSince1970, 1_773_115_200) // 04:00 UTC

        let preceding = CalendarDayPeriod.today.precedingInterval(endingAt: now, calendar: calendar)
        XCTAssertEqual(preceding, DateInterval(start: newYorkMidnight(month: 3, day: 9), end: newYorkMidnight(month: 3, day: 10)))
        XCTAssertEqual(preceding.duration, 24 * Fixture.hour)
    }

    func testThreeDaysStartsOnTheSpringForwardDay() {
        // Current: [Mar 8 00:00 EST (05:00 UTC), now). Preceding: [Mar 5 00:00 EST, Mar 8 00:00 EST) = 72 h.
        let current = CalendarDayPeriod.threeDays.interval(endingAt: now, calendar: calendar)
        XCTAssertEqual(current.start, Fixture.springForwardDayStart)
        let preceding = CalendarDayPeriod.threeDays.precedingInterval(endingAt: now, calendar: calendar)
        XCTAssertEqual(preceding, DateInterval(start: newYorkMidnight(month: 3, day: 5), end: Fixture.springForwardDayStart))
        XCTAssertEqual(preceding.duration, 72 * Fixture.hour)
    }

    func testPrecedingDayCanBeTwentyThreeHours() {
        // Now = Mar 9 10:00 EDT. Yesterday was the 23-hour spring-forward day.
        let mondayMorning = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 10))!
        let preceding = CalendarDayPeriod.today.precedingInterval(endingAt: mondayMorning, calendar: calendar)
        XCTAssertEqual(preceding.start, Fixture.springForwardDayStart)
        XCTAssertEqual(preceding.duration, 23 * Fixture.hour)
    }

    func testFourteenDays() {
        // Mar 10 − 13 days = Feb 25. Current: [Feb 25 00:00 EST, now) touches 14 dates → GMI shown.
        // Preceding: [Feb 11 00:00 EST, Feb 25 00:00 EST), also 14 dates.
        let current = CalendarDayPeriod.fourteenDays.interval(endingAt: now, calendar: calendar)
        let preceding = CalendarDayPeriod.fourteenDays.precedingInterval(endingAt: now, calendar: calendar)
        XCTAssertEqual(current.start, newYorkMidnight(month: 2, day: 25))
        XCTAssertEqual(preceding, DateInterval(start: newYorkMidnight(month: 2, day: 11), end: newYorkMidnight(month: 2, day: 25)))
        XCTAssertEqual(CalendarDays.count(in: current, calendar: calendar), 14)
        XCTAssertEqual(CalendarDays.count(in: preceding, calendar: calendar), 14)
    }

    func testNinetyDays() {
        // Mar 10 − 89 days = Dec 11 2025 (Mar 10 → Feb 10 is 28 days, → Jan 10 is 59, → Dec 11 is 89).
        let current = CalendarDayPeriod.ninetyDays.interval(endingAt: now, calendar: calendar)
        let expectedStart = calendar.date(from: DateComponents(year: 2025, month: 12, day: 11))!
        XCTAssertEqual(current.start, expectedStart)
        XCTAssertEqual(CalendarDays.count(in: current, calendar: calendar), 90)
    }

    func testNowExactlyAtMidnight() {
        // Now = Mar 10 00:00 EDT: "today so far" is empty; the preceding day is Mar 9.
        let midnight = newYorkMidnight(month: 3, day: 10)
        let current = CalendarDayPeriod.today.interval(endingAt: midnight, calendar: calendar)
        XCTAssertEqual(current.duration, 0)
        XCTAssertEqual(
            CalendarDayPeriod.today.precedingInterval(endingAt: midnight, calendar: calendar).start,
            newYorkMidnight(month: 3, day: 9)
        )
    }
}
