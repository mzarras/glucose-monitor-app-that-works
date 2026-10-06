import XCTest
import GlucoseCore
@testable import GlucoseStats

/// The single entry point: every metric for one period.
final class GlucoseStatisticsTests: XCTestCase {

    private let oneDay = DateInterval(start: Fixture.day0, duration: Fixture.day)

    func testEmptyInput() {
        let stats = GlucoseStatistics.compute(readings: [], interval: oneDay, options: Fixture.utcOptions)

        XCTAssertEqual(stats.interval, oneDay)
        XCTAssertEqual(stats.calendarDayCount, 1)
        XCTAssertEqual(stats.readingCount, 0)
        XCTAssertEqual(stats.duplicateCount, 0)
        XCTAssertFalse(stats.containsImportedReadings)
        XCTAssertNil(stats.ranges.inRange.percent)
        XCTAssertNil(stats.meanAndVariability.meanMgdl)
        XCTAssertNil(stats.meanAndVariability.standardDeviationMgdl)
        XCTAssertNil(stats.meanAndVariability.coefficientOfVariationPercent)
        XCTAssertFalse(stats.gmi.isMeaningful)
        XCTAssertNil(stats.gmi.percent)
        XCTAssertEqual(stats.dataSufficiency.percent, 0)
        XCTAssertTrue(stats.dataSufficiency.isBelowWarningThreshold)
        XCTAssertTrue(stats.agp.buckets.allSatisfy { $0.readingCount == 0 && $0.p50 == nil })
        XCTAssertEqual(stats.hypoEvents.level1.count, 0)
        XCTAssertEqual(stats.hypoEvents.level2.count, 0)
        XCTAssertNil(stats.overnightAndDay.overnight.inRangePercent)
        XCTAssertNil(stats.overnightAndDay.day.inRangePercent)
        XCTAssertNil(stats.longestInRangeStreak)
        XCTAssertEqual(stats.afterExerciseTimeInRange, .unavailable)
    }

    func testComputeMatchesEachMetricOnTheSamePeriod() {
        let readings = Fixture.series(Fixture.mg(65, 65, 65, 100, 120, 140, 200, 260) + [.belowRange, .aboveRange])
        let stats = GlucoseStatistics.compute(readings: readings, interval: oneDay, options: Fixture.utcOptions)
        let period = Fixture.period(readings, oneDay)

        XCTAssertEqual(stats.readingCount, 10)
        XCTAssertEqual(stats.ranges, RangeDistribution(period))
        XCTAssertEqual(stats.meanAndVariability, MeanAndVariability(period))
        XCTAssertEqual(stats.dataSufficiency, DataSufficiency(period))
        XCTAssertEqual(stats.agp, AGPProfile(period))
        XCTAssertEqual(stats.hypoEvents, HypoEvents(period))
        XCTAssertEqual(stats.overnightAndDay, OvernightAndDayTimeInRange(period, window: .defaultOvernight))
        XCTAssertEqual(stats.longestInRangeStreak, InRangeStreak.longest(in: period))
        XCTAssertEqual(stats.gmi, GlucoseManagementIndicator(meanMgdl: stats.meanAndVariability.meanMgdl, calendarDayCount: 1))
    }

    func testReadingsMoreThanADayOutsideTheIntervalChangeNothing() {
        // Beyond the 24 h context window (look-back starts at day0 − 24 h, look-ahead ends at end + 24 h,
        // exclusive), readings are ignored entirely.
        let inside = Fixture.series(from: Fixture.at(60), Fixture.mg(100, 110, 65, 65, 65, 120))
        let outside = [
            Fixture.reading(Fixture.day0.addingTimeInterval(-Fixture.day - 1), .belowRange),
            Fixture.reading(oneDay.end.addingTimeInterval(Fixture.day), .aboveRange),
            Fixture.reading(oneDay.end.addingTimeInterval(2 * Fixture.day), .mgdl(300)),
        ]
        let clean = GlucoseStatistics.compute(readings: inside, interval: oneDay, options: Fixture.utcOptions)
        let noisy = GlucoseStatistics.compute(readings: outside + inside, interval: oneDay, options: Fixture.utcOptions)
        XCTAssertEqual(noisy.ranges, clean.ranges)
        XCTAssertEqual(noisy.meanAndVariability, clean.meanAndVariability)
        XCTAssertEqual(noisy.agp, clean.agp)
        XCTAssertEqual(noisy.hypoEvents, clean.hypoEvents)
        XCTAssertEqual(noisy.longestInRangeStreak, clean.longestInRangeStreak)
        XCTAssertEqual(noisy.dataSufficiency, clean.dataSufficiency)
    }

    func testReadingsWithinADayOutsideTheIntervalAreOnlyHypoContext() {
        // A LOW 1 s before the interval and a HIGH at its end are context: every interval metric is
        // unchanged. The low at 01:10 (15 min) is the same event; only why it ended differs — with the
        // HIGH 22 h later in view, the readings did not run out, a gap followed.
        let inside = Fixture.series(from: Fixture.at(60), Fixture.mg(100, 110, 65, 65, 65, 120))
        let outside = [
            Fixture.reading(Fixture.day0.addingTimeInterval(-1), .belowRange),
            Fixture.reading(oneDay.end, .aboveRange),
        ]
        let clean = GlucoseStatistics.compute(readings: inside, interval: oneDay, options: Fixture.utcOptions)
        let noisy = GlucoseStatistics.compute(readings: outside + inside, interval: oneDay, options: Fixture.utcOptions)
        XCTAssertEqual(noisy.readingCount, clean.readingCount)
        XCTAssertEqual(noisy.ranges, clean.ranges)
        XCTAssertEqual(noisy.meanAndVariability, clean.meanAndVariability)
        XCTAssertEqual(noisy.agp, clean.agp)
        XCTAssertEqual(noisy.longestInRangeStreak, clean.longestInRangeStreak)
        XCTAssertEqual(noisy.dataSufficiency, clean.dataSufficiency)
        XCTAssertEqual(noisy.overnightAndDay, clean.overnightAndDay)
        XCTAssertEqual(noisy.hypoEvents.level1.events.map(\.start), clean.hypoEvents.level1.events.map(\.start))
        XCTAssertEqual(noisy.hypoEvents.level1.events.map(\.duration), [900])
        XCTAssertEqual(clean.hypoEvents.level1.events.map(\.endedBy), [.noMoreReadings])
        XCTAssertEqual(noisy.hypoEvents.level1.events.map(\.endedBy), [.gap])
    }

    func testDuplicateTimestampsAreCountedOnce() {
        // 100 at 00:00 and 00:05 from the sensor; the same two instants again from Nightscout at 300.
        // Counted: the two sensor readings → n = 2, mean 100, in range 100 %, 2 duplicates dropped.
        let sensor = Fixture.series(Fixture.mg(100, 100))
        let imported = Fixture.series(Fixture.mg(300, 300), source: .imported(.nightscout))
        let stats = GlucoseStatistics.compute(readings: imported + sensor, interval: oneDay, options: Fixture.utcOptions)

        XCTAssertEqual(stats.readingCount, 2)
        XCTAssertEqual(stats.duplicateCount, 2)
        XCTAssertEqual(stats.meanAndVariability.meanMgdl, 100)
        XCTAssertEqual(stats.ranges.inRange.percent, 100)
        XCTAssertEqual(stats.dataSufficiency.presentReadingCount, 2)
        XCTAssertFalse(stats.containsImportedReadings)
    }

    func testImportedReadingsSetTheFootnoteFlag() {
        let readings = [
            Fixture.reading(Fixture.at(0), .mgdl(100)),
            Fixture.reading(Fixture.at(5), .mgdl(100), source: .imported(.clarityCSV)),
        ]
        let stats = GlucoseStatistics.compute(readings: readings, interval: oneDay, options: Fixture.utcOptions)
        XCTAssertTrue(stats.containsImportedReadings)
        XCTAssertEqual(stats.readingCount, 2, "imported history counts toward statistics (S6 allows charts and stats)")
    }

    func testGMIIsReportedForFourteenDays() {
        // 14 days of 150 mg/dL hourly → mean 150 → GMI 6.898 %.
        let fortnight = DateInterval(start: Fixture.day0, duration: 14 * Fixture.day)
        let readings = Fixture.series(spacingMinutes: 60, Array(repeating: .mgdl(150), count: 14 * 24))
        let stats = GlucoseStatistics.compute(readings: readings, interval: fortnight, options: Fixture.utcOptions)
        XCTAssertEqual(stats.calendarDayCount, 14)
        XCTAssertTrue(stats.gmi.isMeaningful)
        XCTAssertEqual(stats.gmi.percent!, 6.898, accuracy: 1e-12)
    }

    func testCustomOvernightWindowIsUsed() {
        let window = DailyWindow(startMinuteOfDay: 22 * 60, endMinuteOfDay: 7 * 60)!
        let options = StatisticsOptions(calendar: Fixture.utc, overnightWindow: window)
        // 06:30 is overnight under 22:00–07:00 but day under the default.
        let readings = [Fixture.reading(Fixture.at(390), .mgdl(100))]
        let stats = GlucoseStatistics.compute(readings: readings, interval: oneDay, options: options)
        XCTAssertEqual(stats.overnightAndDay.window, window)
        XCTAssertEqual(stats.overnightAndDay.overnight.readingCount, 1)
        XCTAssertEqual(stats.overnightAndDay.day.readingCount, 0)
    }

    func testTodaySoFar() {
        // Now = Jan 5 12:35 UTC. Today so far = [00:00, 12:35). A 15-min low at 03:00 counts as one "low"
        // (level 1 event); a reading at 13:00 is in the future and ignored.
        let now = Fixture.at(12 * 60 + 35)
        let readings = Fixture.series(from: Fixture.at(180), Fixture.mg(65, 65, 65, 100, 100, 100))
            + [Fixture.reading(Fixture.at(13 * 60), .belowRange)]
        let stats = GlucoseStatistics.todaySoFar(readings: readings, now: now, options: Fixture.utcOptions)

        XCTAssertEqual(stats.interval, DateInterval(start: Fixture.day0, end: now))
        XCTAssertEqual(stats.readingCount, 6)
        XCTAssertEqual(stats.hypoEvents.level1.count, 1)
        XCTAssertEqual(stats.level1EventCountOverlappingPeriod, 1)
        // In range 3/6 = 50 %; mean (3 × 65 + 3 × 100) / 6 = 495 / 6 = 82.5.
        XCTAssertEqual(stats.ranges.inRange.percent, 50)
        XCTAssertEqual(stats.meanAndVariability.meanMgdl, 82.5)
    }

    func testTodaySoFarLowsIncludeALowThatBeganBeforeMidnight() {
        // Reviewer probe: 50 mg/dL every 5 min from 23:40 (Jan 5) to 00:40 (Jan 6); now = Jan 6 00:42.
        //   The low started yesterday, so today's start-attributed counts are 0 (Trends counts each low
        //   once, in the period it began), but it overlaps today: "Today so far → lows" = 1.
        //   Its end = coverage end of 00:40 capped at the period end (now, no later reading) = 00:42.
        let readings = Fixture.series(from: Fixture.at(1_420), Array(repeating: GlucoseValue.mgdl(50), count: 13))
        let now = Fixture.at(1_440 + 42)
        let today = GlucoseStatistics.todaySoFar(readings: readings, now: now, options: Fixture.utcOptions)

        XCTAssertEqual(today.readingCount, 9)
        XCTAssertEqual(today.ranges.veryLow.percent, 100)
        XCTAssertEqual(today.hypoEvents.level1.count, 0)
        XCTAssertEqual(today.hypoEvents.level2.count, 0)
        XCTAssertEqual(today.level1EventCountOverlappingPeriod, 1)
        XCTAssertEqual(today.hypoEvents.level1.events(overlapping: today.interval), [
            HypoEvent(level: .level1, start: Fixture.at(1_420), end: now, endedBy: .noMoreReadings, startHourOfDay: 23),
        ])
        XCTAssertEqual(today.hypoEvents.level2.events(overlapping: today.interval).count, 1)
    }

    func testAfterExerciseTimeInRangeIsAStub() {
        XCTAssertFalse(AfterExerciseTimeInRange.isImplemented)
        let readings = Fixture.series(Fixture.mg(100, 110, 120))
        let stats = GlucoseStatistics.compute(readings: readings, interval: oneDay, options: Fixture.utcOptions)
        XCTAssertEqual(stats.afterExerciseTimeInRange, .unavailable)
    }
}
