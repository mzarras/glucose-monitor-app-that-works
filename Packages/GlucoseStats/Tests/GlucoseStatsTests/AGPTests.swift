import XCTest
import GlucoseCore
@testable import GlucoseStats

final class AGPTests: XCTestCase {

    // MARK: Nearest-rank percentile: rank r = ⌈p × n / 100⌉, value = r-th smallest (1-based).

    func testNearestRankFiveValues() {
        // [100, 120, 90, 150, 110] → sorted [90, 100, 110, 120, 150], n = 5
        //   p5:  ⌈0.25⌉ = 1 → 90      p25: ⌈1.25⌉ = 2 → 100     p50: ⌈2.5⌉ = 3 → 110
        //   p75: ⌈3.75⌉ = 4 → 120     p95: ⌈4.75⌉ = 5 → 150
        let values = Fixture.mg(100, 120, 90, 150, 110)
        XCTAssertEqual(AGPProfile.nearestRankPercentile(5, of: values), .mgdl(90))
        XCTAssertEqual(AGPProfile.nearestRankPercentile(25, of: values), .mgdl(100))
        XCTAssertEqual(AGPProfile.nearestRankPercentile(50, of: values), .mgdl(110))
        XCTAssertEqual(AGPProfile.nearestRankPercentile(75, of: values), .mgdl(120))
        XCTAssertEqual(AGPProfile.nearestRankPercentile(95, of: values), .mgdl(150))
    }

    func testNearestRankTwentyValues() {
        // [10, 20, …, 200], n = 20
        //   p5: ⌈1⌉ = 1 → 10   p25: ⌈5⌉ = 5 → 50   p50: ⌈10⌉ = 10 → 100   p75: 15 → 150   p95: 19 → 190
        // (No interpolation: p50 is 100, not the 105 a linear method would give.)
        let values = (1...20).map { GlucoseValue.mgdl($0 * 10) }
        XCTAssertEqual(AGPProfile.nearestRankPercentile(5, of: values), .mgdl(10))
        XCTAssertEqual(AGPProfile.nearestRankPercentile(25, of: values), .mgdl(50))
        XCTAssertEqual(AGPProfile.nearestRankPercentile(50, of: values), .mgdl(100))
        XCTAssertEqual(AGPProfile.nearestRankPercentile(75, of: values), .mgdl(150))
        XCTAssertEqual(AGPProfile.nearestRankPercentile(95, of: values), .mgdl(190))
        XCTAssertEqual(AGPProfile.nearestRankPercentile(100, of: values), .mgdl(200))
    }

    func testNearestRankOrdersLowBelowAndHighAboveEveryNumber() {
        // [HIGH, 80, LOW, 90, LOW] → ordered [LOW, LOW, 80, 90, HIGH], n = 5 → ranks 1, 2, 3, 4, 5.
        let values: [GlucoseValue] = [.aboveRange, .mgdl(80), .belowRange, .mgdl(90), .belowRange]
        XCTAssertEqual(AGPProfile.nearestRankPercentile(5, of: values), .belowRange)
        XCTAssertEqual(AGPProfile.nearestRankPercentile(25, of: values), .belowRange)
        XCTAssertEqual(AGPProfile.nearestRankPercentile(50, of: values), .mgdl(80))
        XCTAssertEqual(AGPProfile.nearestRankPercentile(75, of: values), .mgdl(90))
        XCTAssertEqual(AGPProfile.nearestRankPercentile(95, of: values), .aboveRange)
    }

    func testNearestRankEdgeCases() {
        XCTAssertNil(AGPProfile.nearestRankPercentile(50, of: []))
        XCTAssertNil(AGPProfile.nearestRankPercentile(0, of: Fixture.mg(100)))
        XCTAssertNil(AGPProfile.nearestRankPercentile(101, of: Fixture.mg(100)))
        for p in AGPProfile.percentiles {
            XCTAssertEqual(AGPProfile.nearestRankPercentile(p, of: Fixture.mg(123)), .mgdl(123))
        }
    }

    // MARK: Ordering used by the percentiles

    func testTallySortEqualsStandardSort() {
        // 2 000 pseudo-random arrays: spreads up to 4 096 use the tally, wider ones fall back to sorted().
        var generator = LinearCongruentialGenerator(seed: 7)
        let spreads = [1, 10, 360, 4_096, 5_000, 1_000_000]
        for trial in 0..<2_000 {
            let count = Int(generator.next() % 300)
            let spread = spreads[trial % spreads.count]
            let values = (0..<count).map { _ in Int(generator.next() % UInt64(spread + 1)) - spread / 2 }
            XCTAssertEqual(OrderedValues.sortedAscending(values), values.sorted(), "trial \(trial)")
        }
    }

    func testTallySortEdgeCases() {
        XCTAssertEqual(OrderedValues.sortedAscending([]), [])
        XCTAssertEqual(OrderedValues.sortedAscending([7]), [7])
        XCTAssertEqual(OrderedValues.sortedAscending([400, 40, 400, 40, 41]), [40, 40, 41, 400, 400])
        // Spread overflows Int → falls back to sorted() instead of trapping.
        XCTAssertEqual(OrderedValues.sortedAscending([Int.max, Int.min, 0]), [Int.min, 0, Int.max])
    }

    // MARK: Buckets

    func testNinetySixFifteenMinuteBuckets() {
        let profile = AGPProfile(Fixture.period([], Fixture.interval(minutes: 1_440)))
        XCTAssertEqual(AGPProfile.bucketMinutes, 15)
        XCTAssertEqual(profile.buckets.count, 96)
        XCTAssertEqual(profile.buckets.map(\.startMinuteOfDay), Array(stride(from: 0, to: 1_440, by: 15)))
        XCTAssertEqual(AGPProfile.percentiles, [5, 25, 50, 75, 95])
        for bucket in profile.buckets {
            XCTAssertEqual(bucket.readingCount, 0)
            XCTAssertNil(bucket.p5)
            XCTAssertNil(bucket.p25)
            XCTAssertNil(bucket.p50)
            XCTAssertNil(bucket.p75)
            XCTAssertNil(bucket.p95)
        }
    }

    func testReadingsGoToTheirLocalFifteenMinuteBucket() {
        // UTC. 00:00 → 100 and 00:14 → 110 in bucket 0; 00:15 → 200 in bucket 1; 23:59 → 300 in bucket 95.
        // Bucket 0: sorted [100, 110], n = 2 → p5 ⌈0.1⌉=1 → 100, p25 ⌈0.5⌉=1 → 100, p50 ⌈1⌉=1 → 100,
        //           p75 ⌈1.5⌉=2 → 110, p95 ⌈1.9⌉=2 → 110.
        let readings = [
            Fixture.reading(Fixture.at(0), .mgdl(100)),
            Fixture.reading(Fixture.at(14), .mgdl(110)),
            Fixture.reading(Fixture.at(15), .mgdl(200)),
            Fixture.reading(Fixture.at(1_439), .mgdl(300)),
        ]
        let profile = AGPProfile(Fixture.period(readings, Fixture.interval(minutes: 1_440)))

        XCTAssertEqual(profile.buckets[0], AGPBucket(
            startMinuteOfDay: 0, readingCount: 2,
            p5: .mgdl(100), p25: .mgdl(100), p50: .mgdl(100), p75: .mgdl(110), p95: .mgdl(110)
        ))
        XCTAssertEqual(profile.buckets[1].readingCount, 1)
        XCTAssertEqual(profile.buckets[1].p50, .mgdl(200))
        XCTAssertEqual(profile.buckets[95].readingCount, 1)
        XCTAssertEqual(profile.buckets[95].p95, .mgdl(300))
        XCTAssertEqual(profile.buckets.map(\.readingCount).reduce(0, +), 4)
    }

    func testDaysPoolIntoTheSameTimeOfDayBucket() {
        // 08:00 on three days: 100, 130, 160 → bucket 32 (8 × 4), sorted n = 3 → p50 ⌈1.5⌉ = 2 → 130.
        let readings = [100, 130, 160].enumerated().map { day, value in
            Fixture.reading(Fixture.day0.addingTimeInterval(Double(day) * Fixture.day + 8 * Fixture.hour), .mgdl(value))
        }
        let profile = AGPProfile(Fixture.period(readings, DateInterval(start: Fixture.day0, duration: 3 * Fixture.day)))
        XCTAssertEqual(profile.buckets[32].readingCount, 3)
        XCTAssertEqual(profile.buckets[32].p50, .mgdl(130))
        XCTAssertEqual(profile.buckets[32].p5, .mgdl(100))
        XCTAssertEqual(profile.buckets[32].p95, .mgdl(160))
    }

    func testFallBackDayPoolsBothPassesOfTheRepeatedHour() {
        // Nov 1 2026, New York, 25 h, a reading every 5 min → 300 readings. Index i is at 04:00 UTC + 5i min.
        //   i 12…23 → 01:00–01:55 EDT (first pass)  = 100
        //   i 24…35 → 01:00–01:55 EST (second pass) = 200
        //   everything else                         = 150
        // Bucket 4 (01:00–01:14) holds i 12, 13, 14 and 24, 25, 26: sorted [100 ×3, 200 ×3], n = 6
        //   p5 ⌈0.3⌉=1 → 100   p25 ⌈1.5⌉=2 → 100   p50 ⌈3⌉=3 → 100   p75 ⌈4.5⌉=5 → 200   p95 ⌈5.7⌉=6 → 200
        // Buckets 4…7 hold 6 readings each, the other 92 hold 3: 4 × 6 + 92 × 3 = 300.
        let values: [GlucoseValue] = (0..<300).map { i in
            if (12...23).contains(i) { return .mgdl(100) }
            if (24...35).contains(i) { return .mgdl(200) }
            return .mgdl(150)
        }
        let day = DateInterval(start: Fixture.fallBackDayStart, duration: 25 * Fixture.hour)
        let readings = Fixture.series(from: Fixture.fallBackDayStart, values)
        let profile = AGPProfile(Fixture.period(readings, day, calendar: Fixture.newYork))

        XCTAssertEqual(profile.buckets[4], AGPBucket(
            startMinuteOfDay: 60, readingCount: 6,
            p5: .mgdl(100), p25: .mgdl(100), p50: .mgdl(100), p75: .mgdl(200), p95: .mgdl(200)
        ))
        for index in 0..<96 {
            XCTAssertEqual(profile.buckets[index].readingCount, (4...7).contains(index) ? 6 : 3, "bucket \(index)")
        }
    }

    func testSpringForwardDayLeavesTheSkippedHourEmpty() {
        // Mar 8 2026, New York, 23 h → 276 readings. 02:00–02:59 never happens on the wall clock, so
        // buckets 8…11 are empty and every other bucket holds 3: 92 × 3 = 276.
        let day = DateInterval(start: Fixture.springForwardDayStart, duration: 23 * Fixture.hour)
        let readings = Fixture.series(from: Fixture.springForwardDayStart, Array(repeating: .mgdl(120), count: 276))
        let profile = AGPProfile(Fixture.period(readings, day, calendar: Fixture.newYork))

        for index in 0..<96 {
            let expected = (8...11).contains(index) ? 0 : 3
            XCTAssertEqual(profile.buckets[index].readingCount, expected, "bucket \(index)")
            XCTAssertEqual(profile.buckets[index].p50, expected == 0 ? nil : .mgdl(120))
        }
    }
}
