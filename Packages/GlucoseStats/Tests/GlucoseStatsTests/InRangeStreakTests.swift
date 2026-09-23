import XCTest
import GlucoseCore
@testable import GlucoseStats

/// Longest continuous run of 70–180 readings. Same coverage and gap rules as HypoEventTests.
final class InRangeStreakTests: XCTestCase {

    private func streak(_ readings: [GlucoseReading], periodMinutes: Double = 60) -> InRangeStreak? {
        InRangeStreak.longest(in: Fixture.period(readings, Fixture.interval(minutes: periodMinutes)))
    }

    func testLongestRunWins() {
        // 100 at 00:00–00:15 (4) | 200 at 00:20 | 100 at 00:25–00:50 (6); period [0, 60)
        //   run A: coverage end of 00:15 = next reading 00:20 → 20 min
        //   run B: coverage end of 00:50 = min(00:55, 01:00) = 00:55 → 55 − 25 = 30 min  ← longest
        let values = Fixture.mg(100, 100, 100, 100, 200, 100, 100, 100, 100, 100, 100)
        let result = streak(Fixture.series(values))
        XCTAssertEqual(result, InRangeStreak(start: Fixture.at(25), end: Fixture.at(55), readingCount: 6))
        XCTAssertEqual(result?.duration, 1_800)
    }

    func testGapOverFifteenMinutesBreaksTheRun() {
        // 100 at 00:00, 00:05 | 20 min gap | 100 at 00:25, 00:30
        //   runs 00:00–00:10 and 00:25–00:35, 10 min each; ties go to the earliest.
        //   (Bridging the gap would have claimed 35 min.)
        let readings = [0.0, 5, 25, 30].map { Fixture.reading(Fixture.at($0), .mgdl(100)) }
        XCTAssertEqual(streak(readings), InRangeStreak(start: Fixture.at(0), end: Fixture.at(10), readingCount: 2))
    }

    func testGapOfExactlyFifteenMinutesIsBridged() {
        // 100 at 00:00 and 00:15 → one run, coverage end of 00:15 = 00:20 → 20 min.
        let readings = [0.0, 15].map { Fixture.reading(Fixture.at($0), .mgdl(100)) }
        XCTAssertEqual(streak(readings)?.duration, 1_200)
    }

    func testRangeBoundsAreInclusive() {
        // 70, 180 in range; 69 and 181 break it. 69 | 70 180 | 181 → run 00:05–00:15 = 10 min.
        let result = streak(Fixture.series(Fixture.mg(69, 70, 180, 181)))
        XCTAssertEqual(result, InRangeStreak(start: Fixture.at(5), end: Fixture.at(15), readingCount: 2))
    }

    func testCoverageIsCutAtThePeriodEnd() {
        // 100 at 00:00, 00:05, 00:10; period [0, 12) → 00:00–00:12 = 12 min, not 15.
        XCTAssertEqual(streak(Fixture.series(Fixture.mg(100, 100, 100)), periodMinutes: 12)?.duration, 720)
    }

    func testNoInRangeReadingsMeansNoStreak() {
        XCTAssertNil(streak([]))
        XCTAssertNil(streak(Fixture.series([.belowRange, .aboveRange, .mgdl(60), .mgdl(200)])))
    }
}
