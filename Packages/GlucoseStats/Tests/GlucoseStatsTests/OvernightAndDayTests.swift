import XCTest
import GlucoseCore
@testable import GlucoseStats

final class OvernightAndDayTests: XCTestCase {

    /// UTC day0: 01:00 100 · 03:00 50 · 05:59 150 · 06:00 200 · 12:00 100 · 23:59 250
    private let readings: [GlucoseReading] = [
        (60.0, 100), (180, 50), (359, 150), (360, 200), (720, 100), (1_439, 250),
    ].map { Fixture.reading(Fixture.at($0.0), .mgdl($0.1)) }

    private let oneDay = Fixture.interval(minutes: 1_440)

    func testDefaultWindowIsMidnightToSix() {
        XCTAssertEqual(DailyWindow.defaultOvernight.startMinuteOfDay, 0)
        XCTAssertEqual(DailyWindow.defaultOvernight.endMinuteOfDay, 360)
        XCTAssertEqual(StatisticsOptions(calendar: Fixture.utc).overnightWindow, .defaultOvernight)
    }

    func testDefaultSplit() {
        // Overnight [00:00, 06:00): 01:00 100 ✓, 03:00 50 ✗, 05:59 150 ✓ → 2 / 3 = 66.666… %
        // Day (the rest):           06:00 200 ✗, 12:00 100 ✓, 23:59 250 ✗ → 1 / 3 = 33.333… %
        let result = OvernightAndDayTimeInRange(Fixture.period(readings, oneDay), window: .defaultOvernight)

        XCTAssertEqual(result.window, .defaultOvernight)
        XCTAssertEqual(result.overnight.readingCount, 3)
        XCTAssertEqual(result.overnight.inRangeCount, 2)
        XCTAssertEqual(result.overnight.inRangePercent!, 200.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(result.day.readingCount, 3)
        XCTAssertEqual(result.day.inRangeCount, 1)
        XCTAssertEqual(result.day.inRangePercent!, 100.0 / 3.0, accuracy: 1e-12)
    }

    func testWindowWrappingMidnight() {
        // Overnight 22:00–06:00: 01:00 ✓, 03:00 ✗, 05:59 ✓, 23:59 ✗ → 2 / 4 = 50 %
        // Day 06:00–22:00:       06:00 ✗, 12:00 ✓                → 1 / 2 = 50 %
        let window = DailyWindow(startMinuteOfDay: 22 * 60, endMinuteOfDay: 6 * 60)!
        let result = OvernightAndDayTimeInRange(Fixture.period(readings, oneDay), window: window)
        XCTAssertEqual(result.overnight.readingCount, 4)
        XCTAssertEqual(result.overnight.inRangePercent, 50)
        XCTAssertEqual(result.day.readingCount, 2)
        XCTAssertEqual(result.day.inRangePercent, 50)
    }

    func testLowAndHighFlagsCountAsOutOfRange() {
        // Overnight: 01:00 LOW, 02:00 HIGH, 03:00 100 → 1 / 3 in range.
        let flagged = [
            Fixture.reading(Fixture.at(60), .belowRange),
            Fixture.reading(Fixture.at(120), .aboveRange),
            Fixture.reading(Fixture.at(180), .mgdl(100)),
        ]
        let result = OvernightAndDayTimeInRange(Fixture.period(flagged, oneDay), window: .defaultOvernight)
        XCTAssertEqual(result.overnight.readingCount, 3)
        XCTAssertEqual(result.overnight.inRangeCount, 1)
        XCTAssertEqual(result.day.readingCount, 0)
        XCTAssertNil(result.day.inRangePercent)
    }

    func testEmptyInput() {
        let result = OvernightAndDayTimeInRange(Fixture.period([], oneDay), window: .defaultOvernight)
        XCTAssertNil(result.overnight.inRangePercent)
        XCTAssertNil(result.day.inRangePercent)
    }

    func testFallBackRepeatedHourIsOvernightTwice() {
        // Nov 1 2026 New York: 01:30 EDT (05:30 UTC) and 01:30 EST (06:30 UTC) are both overnight;
        // 07:00 EST (12:00 UTC) is day.
        let day = DateInterval(start: Fixture.fallBackDayStart, duration: 25 * Fixture.hour)
        let local = [
            Fixture.reading(Fixture.fallBackDayStart.addingTimeInterval(1.5 * Fixture.hour), .mgdl(100)),
            Fixture.reading(Fixture.fallBackDayStart.addingTimeInterval(2.5 * Fixture.hour), .mgdl(100)),
            Fixture.reading(Fixture.fallBackDayStart.addingTimeInterval(8 * Fixture.hour), .mgdl(100)),
        ]
        let result = OvernightAndDayTimeInRange(Fixture.period(local, day, calendar: Fixture.newYork), window: .defaultOvernight)
        XCTAssertEqual(result.overnight.readingCount, 2)
        XCTAssertEqual(result.day.readingCount, 1)
    }

    // MARK: DailyWindow

    func testDailyWindowValidation() {
        XCTAssertNil(DailyWindow(startMinuteOfDay: -1, endMinuteOfDay: 360))
        XCTAssertNil(DailyWindow(startMinuteOfDay: 1_440, endMinuteOfDay: 360))
        XCTAssertNil(DailyWindow(startMinuteOfDay: 0, endMinuteOfDay: -1))
        XCTAssertNil(DailyWindow(startMinuteOfDay: 0, endMinuteOfDay: 1_441))
        XCTAssertNil(DailyWindow(startMinuteOfDay: 360, endMinuteOfDay: 360), "an empty window is not a window")
        XCTAssertNotNil(DailyWindow(startMinuteOfDay: 0, endMinuteOfDay: 1_440))
    }

    func testDailyWindowContainsIsHalfOpen() {
        let window = DailyWindow.defaultOvernight
        XCTAssertTrue(window.contains(secondOfDay: 0))
        XCTAssertTrue(window.contains(secondOfDay: 21_599))   // 05:59:59
        XCTAssertFalse(window.contains(secondOfDay: 21_600))  // 06:00:00
        let wrapping = DailyWindow(startMinuteOfDay: 22 * 60, endMinuteOfDay: 6 * 60)!
        XCTAssertTrue(wrapping.contains(secondOfDay: 22 * 3_600))
        XCTAssertTrue(wrapping.contains(secondOfDay: 3_600))
        XCTAssertFalse(wrapping.contains(secondOfDay: 12 * 3_600))
        XCTAssertFalse(wrapping.contains(secondOfDay: 6 * 3_600))
    }
}
