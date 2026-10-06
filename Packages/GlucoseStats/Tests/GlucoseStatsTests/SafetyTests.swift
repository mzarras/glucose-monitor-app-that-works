import XCTest
import GlucoseCore
@testable import GlucoseStats

/// HANDOFF §2 safety rules that GlucoseStats touches.
///
/// S1 — never fabricate a reading: every statistic is computed from real readings only; the AGP's
///      display smoothing is a separate function whose output never feeds a metric.
/// S4 — LOW/HIGH stay flags: excluded from mean/SD/GMI, counted in the extreme bins, never 40/400.
final class SafetyTests: XCTestCase {

    private let oneDay = DateInterval(start: Fixture.day0, duration: Fixture.day)
    private let fortnight = DateInterval(start: Fixture.day0, duration: 14 * Fixture.day)

    // MARK: S1

    func test_S1_displaySmoothingLeavesTheProfileUntouched() {
        // Buckets 40, 41, 42 (10:00, 10:15, 10:30) hold 100, 110, 130.
        let readings = [
            Fixture.reading(Fixture.at(600), .mgdl(100)),
            Fixture.reading(Fixture.at(615), .mgdl(110)),
            Fixture.reading(Fixture.at(630), .mgdl(130)),
        ]
        let period = Fixture.period(readings, oneDay)
        let profile = AGPProfile(period)
        let snapshot = profile

        let smoothed = AGPDisplaySmoothing.smoothedForDisplay(profile)

        // Smoothing did change what is drawn: (100 + 2 × 110 + 130) / 4 = 112.5 …
        XCTAssertEqual(smoothed[41].p50, .mgdl(112.5))
        // … but the profile, and the profile the statistics carry, still hold the observed 110.
        XCTAssertEqual(profile, snapshot)
        XCTAssertEqual(profile.buckets[41].p50, .mgdl(110))
        let stats = GlucoseStatistics.compute(readings: readings, interval: oneDay, options: Fixture.utcOptions)
        XCTAssertEqual(stats.agp, snapshot)
        XCTAssertEqual(stats.agp.buckets[41].p50, .mgdl(110))
    }

    func test_S1_statisticsNeverContainDisplaySmoothedValues() {
        // Walk every stored property of the statistics and comparison values: no display-smoothed type
        // appears anywhere, so no metric (or anything the UI reads as a metric) can be a smoothed number.
        let readings = Fixture.ninetyDays().prefix(2 * 288)
        let comparison = GlucoseStatistics.compare(
            readings: Array(readings), period: .today,
            now: Fixture.day0.addingTimeInterval(Fixture.day + 12 * Fixture.hour), options: Fixture.utcOptions
        )
        var visited = 0
        func walk(_ value: Any, path: String) {
            visited += 1
            XCTAssertFalse(value is AGPDisplayValue, "display-smoothed value at \(path)")
            XCTAssertFalse(value is AGPDisplayBucket, "display-smoothed bucket at \(path)")
            for child in Mirror(reflecting: value).children {
                walk(child.value, path: path + "." + (child.label ?? "?"))
            }
        }
        walk(comparison, path: "comparison")
        XCTAssertGreaterThan(visited, 1_000, "the walk reached the AGP buckets")
    }

    func test_S1_everyAGPPercentileIsAnObservedReading() {
        // Nearest-rank never interpolates: each percentile of each bucket is one of that bucket's readings.
        let readings = Fixture.ninetyDays()
        let interval = DateInterval(start: Fixture.day0, duration: 90 * Fixture.day)
        let period = Fixture.period(readings, interval)
        var observed = Array(repeating: Set<GlucoseValue>(), count: 96)
        for reading in period.readings {
            observed[reading.secondOfDay / 900].insert(reading.value)
        }
        let profile = AGPProfile(period)
        for (index, bucket) in profile.buckets.enumerated() {
            for value in [bucket.p5, bucket.p25, bucket.p50, bucket.p75, bucket.p95] {
                XCTAssertTrue(value.map { observed[index].contains($0) } ?? false, "bucket \(index): \(String(describing: value))")
            }
        }
    }

    func test_S1_noMetricFabricatesValuesAcrossGaps() {
        // 100 at 10:00 and 10:05, then nothing until 11:00 (55 min gap), then 250 and 100 at 11:00, 11:05.
        let readings = [
            Fixture.reading(Fixture.at(600), .mgdl(100)),
            Fixture.reading(Fixture.at(605), .mgdl(100)),
            Fixture.reading(Fixture.at(660), .mgdl(250)),
            Fixture.reading(Fixture.at(665), .mgdl(100)),
        ]
        let stats = GlucoseStatistics.compute(readings: readings, interval: oneDay, options: Fixture.utcOptions)

        // Only the four real readings count: mean (100 + 100 + 250 + 100) / 4 = 137.5.
        XCTAssertEqual(stats.readingCount, 4)
        XCTAssertEqual(stats.ranges.readingCount, 4)
        XCTAssertEqual(stats.dataSufficiency.presentReadingCount, 4)
        XCTAssertEqual(stats.meanAndVariability.numericReadingCount, 4)
        XCTAssertEqual(stats.meanAndVariability.meanMgdl, 137.5)
        // AGP buckets inside the gap (10:15, 10:30, 10:45 → 41, 42, 43) stay empty; no value is invented.
        for index in 41...43 {
            XCTAssertEqual(stats.agp.buckets[index].readingCount, 0)
            XCTAssertNil(stats.agp.buckets[index].p50)
        }
        XCTAssertEqual(stats.agp.buckets[40].readingCount, 2)
        XCTAssertEqual(stats.agp.buckets[44].readingCount, 2)
        // The in-range run does not continue across the gap: 10:00–10:10 is 10 min.
        XCTAssertEqual(stats.longestInRangeStreak?.duration, 600)
        XCTAssertEqual(stats.longestInRangeStreak?.start, Fixture.at(600))
    }

    func test_S1_displaySmoothingNeverFillsAnEmptyBucket() {
        // Buckets 40 and 42 hold readings; 41 between them is empty and must stay empty on the chart.
        let readings = [Fixture.reading(Fixture.at(600), .mgdl(100)), Fixture.reading(Fixture.at(630), .mgdl(200))]
        let smoothed = AGPDisplaySmoothing.smoothedForDisplay(AGPProfile(Fixture.period(readings, oneDay)))
        XCTAssertNil(smoothed[41].p50)
        XCTAssertNil(smoothed[41].p5)
        XCTAssertNil(smoothed[41].p95)
        XCTAssertEqual(smoothed.filter { $0.p50 != nil }.count, 2)
    }

    func test_S1_hypoEventsAreNotJoinedAcrossGaps() {
        // Two 10-minute lows separated by a 25-minute gap: joined they would be 20 min (an event); they are not.
        let readings = [0.0, 5, 30, 35].map { Fixture.reading(Fixture.at($0), .mgdl(60)) }
        let stats = GlucoseStatistics.compute(readings: readings, interval: oneDay, options: Fixture.utcOptions)
        XCTAssertEqual(stats.hypoEvents.level1.count, 0)
    }

    // MARK: S4

    func test_S4_lowAndHighAreExcludedFromMeanSDAndGMI() {
        // [LOW, 100, 200, HIGH] over 14 days.
        //   Correct (flags excluded): n = 2, mean 150, sample SD √5 000 = 70.71067811865476,
        //                             GMI 3.31 + 0.02392 × 150 = 6.898
        //   Wrong (LOW = 40, HIGH = 400): mean (40 + 100 + 200 + 400) / 4 = 185, GMI 7.7352
        let readings = Fixture.series([.belowRange, .mgdl(100), .mgdl(200), .aboveRange])
        let stats = GlucoseStatistics.compute(readings: readings, interval: fortnight, options: Fixture.utcOptions)

        XCTAssertEqual(stats.meanAndVariability.numericReadingCount, 2)
        XCTAssertEqual(stats.meanAndVariability.meanMgdl, 150)
        XCTAssertEqual(stats.meanAndVariability.standardDeviationMgdl!, 70.71067811865476, accuracy: 1e-9)
        XCTAssertEqual(stats.gmi.percent!, 6.898, accuracy: 1e-12)
        XCTAssertNotEqual(stats.meanAndVariability.meanMgdl, 185)
    }

    func test_S4_lowCountsBelow54AndHighCountsAbove250() {
        // Same four readings: each is 1/4 = 25 % of the denominator, flags included.
        let readings = Fixture.series([.belowRange, .mgdl(100), .mgdl(200), .aboveRange])
        let stats = GlucoseStatistics.compute(readings: readings, interval: oneDay, options: Fixture.utcOptions)
        XCTAssertEqual(stats.ranges.readingCount, 4)
        XCTAssertEqual(stats.ranges.veryLow, RangeShare(count: 1, percent: 25))
        XCTAssertEqual(stats.ranges.inRange, RangeShare(count: 1, percent: 25))
        XCTAssertEqual(stats.ranges.high, RangeShare(count: 1, percent: 25))
        XCTAssertEqual(stats.ranges.veryHigh, RangeShare(count: 1, percent: 25))
        XCTAssertEqual(stats.ranges.tightRange, RangeShare(count: 1, percent: 25))
    }

    func test_S4_allLowGivesNilMeanAndHundredPercentBelow54() {
        // 14 days of LOW, hourly (336 readings).
        let readings = Fixture.series(spacingMinutes: 60, Array(repeating: .belowRange, count: 14 * 24))
        let stats = GlucoseStatistics.compute(readings: readings, interval: fortnight, options: Fixture.utcOptions)

        XCTAssertEqual(stats.readingCount, 336)
        XCTAssertNil(stats.meanAndVariability.meanMgdl)
        XCTAssertNil(stats.meanAndVariability.standardDeviationMgdl)
        XCTAssertNil(stats.meanAndVariability.coefficientOfVariationPercent)
        XCTAssertTrue(stats.gmi.isMeaningful)
        XCTAssertNil(stats.gmi.percent, "no GMI from flags")
        XCTAssertEqual(stats.ranges.veryLow, RangeShare(count: 336, percent: 100))
        XCTAssertEqual(stats.ranges.below70, RangeShare(count: 336, percent: 100))
        XCTAssertEqual(stats.ranges.inRange.percent, 0)
        XCTAssertEqual(stats.ranges.tightRange.percent, 0)
        XCTAssertNil(stats.longestInRangeStreak)
        XCTAssertEqual(stats.overnightAndDay.overnight.inRangePercent, 0)
        // LOW is below 54, so it is a level 2 low; hourly readings are 60 min apart (gaps), so each LOW is
        // an isolated 5-minute run and no event qualifies.
        XCTAssertEqual(stats.hypoEvents.level2.count, 0)
        for bucket in stats.agp.buckets where bucket.readingCount > 0 {
            XCTAssertEqual(bucket.p5, .belowRange)
            XCTAssertEqual(bucket.p50, .belowRange)
            XCTAssertEqual(bucket.p95, .belowRange)
        }
    }

    func test_S4_allHighGivesNilMeanAndHundredPercentAbove250() {
        let readings = Fixture.series(Array(repeating: .aboveRange, count: 288))
        let stats = GlucoseStatistics.compute(readings: readings, interval: oneDay, options: Fixture.utcOptions)

        XCTAssertNil(stats.meanAndVariability.meanMgdl)
        XCTAssertNil(stats.meanAndVariability.standardDeviationMgdl)
        XCTAssertNil(stats.gmi.percent)
        XCTAssertEqual(stats.ranges.veryHigh, RangeShare(count: 288, percent: 100))
        XCTAssertEqual(stats.ranges.above180, RangeShare(count: 288, percent: 100))
        XCTAssertEqual(stats.ranges.inRange.percent, 0)
        XCTAssertNil(stats.longestInRangeStreak)
        XCTAssertEqual(stats.hypoEvents.level1.count, 0)
        XCTAssertTrue(stats.agp.buckets.allSatisfy { $0.p5 == .aboveRange && $0.p95 == .aboveRange })
    }

    func test_S4_lowIsNeverTreatedAs40AndHighNeverAs400() {
        // [LOW, 45]: if LOW were 40 the mean would be 42.5; it is 45 (n = 1).
        let low = GlucoseStatistics.compute(
            readings: Fixture.series([.belowRange, .mgdl(45)]), interval: oneDay, options: Fixture.utcOptions
        )
        XCTAssertEqual(low.meanAndVariability.meanMgdl, 45)
        XCTAssertEqual(low.meanAndVariability.numericReadingCount, 1)
        // [HIGH, 390]: if HIGH were 400 the mean would be 395; it is 390.
        let high = GlucoseStatistics.compute(
            readings: Fixture.series([.aboveRange, .mgdl(390)]), interval: oneDay, options: Fixture.utcOptions
        )
        XCTAssertEqual(high.meanAndVariability.meanMgdl, 390)
    }

    func test_S4_agpPercentilesKeepTheFlags() {
        // One bucket (00:00–00:14) with [LOW, 45, 60, 390, HIGH]: ranks 1 … 5 →
        //   p5 LOW, p25 45, p50 60, p75 390, p95 HIGH. Never .mgdl(40) or .mgdl(400).
        let readings = Fixture.series(spacingMinutes: 3, [.belowRange, .mgdl(45), .mgdl(60), .mgdl(390), .aboveRange])
        let stats = GlucoseStatistics.compute(readings: readings, interval: oneDay, options: Fixture.utcOptions)
        XCTAssertEqual(stats.agp.buckets[0], AGPBucket(
            startMinuteOfDay: 0, readingCount: 5,
            p5: .belowRange, p25: .mgdl(45), p50: .mgdl(60), p75: .mgdl(390), p95: .aboveRange
        ))
    }

    func test_S4_displaySmoothingNeverTurnsAFlagIntoANumber() {
        // Neighbouring buckets LOW | 100 | HIGH: the flags stay flags; 100 is not averaged with 40 or 400.
        let readings = [
            Fixture.reading(Fixture.at(0), .belowRange),
            Fixture.reading(Fixture.at(15), .mgdl(100)),
            Fixture.reading(Fixture.at(30), .aboveRange),
        ]
        let smoothed = AGPDisplaySmoothing.smoothedForDisplay(AGPProfile(Fixture.period(readings, oneDay)))
        XCTAssertEqual(smoothed[0].p50, .belowRange)
        XCTAssertEqual(smoothed[1].p50, .mgdl(100))
        XCTAssertEqual(smoothed[2].p50, .aboveRange)
    }

    func test_S4_lowFlagIsALevel2Low() {
        // LOW ×3 then HIGH ×3 (5-min spacing): a 15-min run below 54 → one level 2 and one level 1 event;
        // HIGH counts as ≥ 70 for recovery.
        let readings = Fixture.series([.belowRange, .belowRange, .belowRange, .aboveRange, .aboveRange, .aboveRange])
        let stats = GlucoseStatistics.compute(readings: readings, interval: oneDay, options: Fixture.utcOptions)
        XCTAssertEqual(stats.hypoEvents.level2.events.map(\.endedBy), [.recovery])
        XCTAssertEqual(stats.hypoEvents.level1.count, 1)
    }
}
