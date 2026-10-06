import XCTest
import GlucoseCore
@testable import GlucoseStats

/// Hypoglycaemia events (Battelino et al., Lancet Diabetes Endocrinol 2023;11:42, Table 4).
/// Conventions used in the arithmetic below:
/// - A reading covers from its timestamp to the earliest of (+5 min, the next reading, a limit). The
///   limit is the period end when no reading follows the period, else the detection window end
///   (period end + 24 h).
/// - A run's duration = coverage end of its last reading − its first reading.
/// - A gap between consecutive readings of more than 15 min ends any run and any event.
/// - Level 1 ends after 15 min ≥ 70; level 2 after 15 min ≥ 54.
final class HypoEventTests: XCTestCase {

    /// Readings every 5 min from 00:00 UTC on day0; period [00:00, 02:00) unless given.
    private func events(_ values: [GlucoseValue], periodMinutes: Double = 120) -> HypoEvents {
        HypoEvents(Fixture.period(Fixture.series(values), Fixture.interval(minutes: periodMinutes)))
    }

    private func events(_ readings: [GlucoseReading], periodMinutes: Double = 1_440) -> HypoEvents {
        HypoEvents(Fixture.period(readings, Fixture.interval(minutes: periodMinutes)))
    }

    private func events(_ readings: [GlucoseReading], in interval: DateInterval) -> HypoEvents {
        HypoEvents(Fixture.period(readings, interval))
    }

    func testThresholds() {
        XCTAssertEqual(HypoLevel.level1.entryThresholdMgdl, 70)
        XCTAssertEqual(HypoLevel.level2.entryThresholdMgdl, 54)
        XCTAssertEqual(HypoLevel.level1.exitThresholdMgdl, 70)
        XCTAssertEqual(HypoLevel.level2.exitThresholdMgdl, 54)
        XCTAssertEqual(HypoEventSummary.minimumDuration, 15 * 60)
        XCTAssertEqual(HypoEventSummary.recoveryDuration, 15 * 60)
    }

    func testFifteenMinutesBelow70IsALevel1Event() {
        // 00:00 100 | 00:05 65 | 00:10 65 | 00:15 65 | 00:20 100 | 00:25 100 | 00:30 100
        //   low run 00:05–00:15: coverage end of 00:15 = next reading 00:20 → 20 − 5 = 15 min ≥ 15 → event starts 00:05
        //   recovery 00:20–00:30: coverage end of 00:30 = 00:35 → 35 − 20 = 15 min ≥ 15 → event ends
        //   end = coverage end of the last reading < 70 (00:15) = 00:20 → duration 15 min
        let result = events(Fixture.mg(100, 65, 65, 65, 100, 100, 100))

        XCTAssertEqual(result.level1.events, [
            HypoEvent(level: .level1, start: Fixture.at(5), end: Fixture.at(20), endedBy: .recovery, startHourOfDay: 0),
        ])
        XCTAssertEqual(result.level1.events.first?.duration, 900)
        XCTAssertEqual(result.level1.count, 1)
        XCTAssertEqual(result.level1.meanDuration, 900)
        XCTAssertEqual(result.level2.count, 0)
        XCTAssertNil(result.level2.meanDuration)
    }

    func testTenMinutesBelow70IsNotAnEvent() {
        // Low run 00:05–00:10: coverage end 00:15 → 10 min < 15.
        XCTAssertEqual(events(Fixture.mg(100, 65, 65, 100, 100, 100)).level1.count, 0)
    }

    func testShortRecoveryDoesNotEndTheEvent() {
        // 65 65 65 | 75 | 65 65 | 100 100 100   (00:00 … 00:40)
        //   event starts 00:00 (run 00:00–00:15 = 15 min)
        //   00:15 75 → recovery run only 00:15–00:20 = 5 min, then 00:20 is low again → event continues
        //   recovery 00:30–00:40: coverage end 00:45 → 15 min → event ends
        //   last reading < 70 is 00:25 → end 00:30 → duration 30 min. One event, not two.
        let result = events(Fixture.mg(65, 65, 65, 75, 65, 65, 100, 100, 100))
        XCTAssertEqual(result.level1.events, [
            HypoEvent(level: .level1, start: Fixture.at(0), end: Fixture.at(30), endedBy: .recovery, startHourOfDay: 0),
        ])
    }

    func testFifteenMinuteRecoverySeparatesTwoEvents() {
        // 65 ×3 | 100 ×3 | 65 ×3 | 100 ×3 → events 00:00–00:15 and 00:30–00:45, each 15 min, mean 15 min.
        let result = events(Fixture.mg(65, 65, 65, 100, 100, 100, 65, 65, 65, 100, 100, 100))
        XCTAssertEqual(result.level1.events.map(\.start), [Fixture.at(0), Fixture.at(30)])
        XCTAssertEqual(result.level1.events.map(\.end), [Fixture.at(15), Fixture.at(45)])
        XCTAssertEqual(result.level1.meanDuration, 900)
    }

    func testMeanDurationAveragesEvents() {
        // Event A 00:00–00:15 (15 min); event B 00:30–00:50 (4 lows, 20 min). Mean = (900 + 1 200) / 2 = 1 050 s.
        let result = events(Fixture.mg(65, 65, 65, 100, 100, 100, 65, 65, 65, 65, 100, 100, 100))
        XCTAssertEqual(result.level1.events.map(\.duration), [900, 1_200])
        XCTAssertEqual(result.level1.meanDuration, 1_050)
    }

    func testGapOfMoreThanFifteenMinutesEndsTheEvent() {
        // 00:00 65, 00:05 65, 00:10 65 | no data 00:10 → 00:40 (30 min gap) | 00:40 65, 00:45 65, 00:50 65; period [0, 60)
        //   event 1 starts 00:00; the gap ends it: end = coverage end of 00:10 = 00:15 (15 min), endedBy .gap
        //   event 2: run 00:40–00:50, coverage end min(00:55, period end 01:00) = 00:55 → 15 min;
        //            no reading follows → endedBy .noMoreReadings, end 00:55
        let readings = [0.0, 5, 10, 40, 45, 50].map { Fixture.reading(Fixture.at($0), .mgdl(65)) }
        let result = events(readings, periodMinutes: 60)
        XCTAssertEqual(result.level1.events, [
            HypoEvent(level: .level1, start: Fixture.at(0), end: Fixture.at(15), endedBy: .gap, startHourOfDay: 0),
            HypoEvent(level: .level1, start: Fixture.at(40), end: Fixture.at(55), endedBy: .noMoreReadings, startHourOfDay: 0),
        ])
    }

    func testGapSplitsARunSoNeitherHalfQualifies() {
        // 00:00 65, 00:05 65 | 25 min gap | 00:30 65, 00:35 65 | 00:40…00:50 100
        //   each low run is 10 min → no event (joined, it would have been 4 lows).
        let readings = [0.0, 5, 30, 35].map { Fixture.reading(Fixture.at($0), .mgdl(65)) }
            + [40.0, 45, 50].map { Fixture.reading(Fixture.at($0), .mgdl(100)) }
        XCTAssertEqual(events(readings).level1.count, 0)
    }

    func testGapOfExactlyFifteenMinutesIsBridged() {
        // 00:00 65 | 00:15 65 | 00:20 100, 00:25 100, 00:30 100
        //   gap 15 min is not > 15 → one run; coverage end of 00:15 = next reading 00:20 → 20 min → event
        //   end 00:20, duration 20 min (the 10 unobserved minutes are bridged, as the chart line is, §7.5).
        let readings = [Fixture.reading(Fixture.at(0), .mgdl(65)), Fixture.reading(Fixture.at(15), .mgdl(65))]
            + [20.0, 25, 30].map { Fixture.reading(Fixture.at($0), .mgdl(100)) }
        let result = events(readings)
        XCTAssertEqual(result.level1.events.map(\.duration), [1_200])
    }

    func testGapOfFifteenMinutesAndOneSecondBreaksTheRun() {
        // 00:00 65 | 00:15:01 65 → two runs of 5 min each → no event.
        let late = Fixture.at(15).addingTimeInterval(1)
        let readings = [Fixture.reading(Fixture.at(0), .mgdl(65)), Fixture.reading(late, .mgdl(65))]
            + [5.0, 10, 15].map { Fixture.reading(late.addingTimeInterval($0 * 60), .mgdl(100)) }
        XCTAssertEqual(events(readings).level1.count, 0)
    }

    func testLevel2EventEndsAfterFifteenMinutesAtOrAbove54() {
        // 50 50 50 | 60 60 | 100 100 100   (00:00 … 00:35)
        //   level 2: run < 54 00:00–00:15 = 15 min → starts 00:00; recovery ≥ 54 from 00:15:
        //            coverage end of 00:25 = 00:30 → 30 − 15 = 15 min → ends; last reading < 54 is 00:10
        //            → end 00:15 → 15 min
        //   level 1: all < 70 until 00:25; recovery ≥ 70 00:25–00:40 = 15 min; last < 70 is 00:20
        //            → end 00:25 → 25 min
        let result = events(Fixture.mg(50, 50, 50, 60, 60, 100, 100, 100))
        XCTAssertEqual(result.level2.events, [
            HypoEvent(level: .level2, start: Fixture.at(0), end: Fixture.at(15), endedBy: .recovery, startHourOfDay: 0),
        ])
        XCTAssertEqual(result.level1.events, [
            HypoEvent(level: .level1, start: Fixture.at(0), end: Fixture.at(25), endedBy: .recovery, startHourOfDay: 0),
        ])
    }

    func testLongLevel1LowHoldsTwoLevel2Events() {
        // Reviewer probe: 50 ×3 (00:00–00:10) | 60 ×20 (00:15–01:50) | 50 ×3 (01:55–02:05); period [0, 3 h).
        //   level 2 event A: run < 54 00:00–00:10, coverage end 00:15 → 15 min → starts 00:00;
        //                    ≥ 54 from 00:15, coverage end of 00:25 = 00:30 → 15 min → recovered;
        //                    end = coverage end of 00:10 = 00:15 → 15 min
        //   level 2 event B: run < 54 01:55–02:05, coverage end 02:10 → 15 min → starts 01:55;
        //                    readings stop → end 02:10 → 15 min, endedBy .noMoreReadings
        //   level 1: all 26 readings < 70 → one event 00:00 → coverage end of 02:05 = 02:10 → 130 min
        let values = Fixture.mg(50, 50, 50) + Array(repeating: GlucoseValue.mgdl(60), count: 20) + Fixture.mg(50, 50, 50)
        let result = events(values, periodMinutes: 180)

        XCTAssertEqual(result.level2.events, [
            HypoEvent(level: .level2, start: Fixture.at(0), end: Fixture.at(15), endedBy: .recovery, startHourOfDay: 0),
            HypoEvent(level: .level2, start: Fixture.at(115), end: Fixture.at(130), endedBy: .noMoreReadings, startHourOfDay: 1),
        ])
        XCTAssertEqual(result.level2.meanDuration, 900)
        XCTAssertEqual(result.level1.events, [
            HypoEvent(level: .level1, start: Fixture.at(0), end: Fixture.at(130), endedBy: .noMoreReadings, startHourOfDay: 0),
        ])
        XCTAssertEqual(result.level1.events.first?.duration, 7_800)
    }

    func testLevel1WithoutFifteenMinutesBelow54IsNotLevel2() {
        // 50 50 | 60 60 60 | 100 100 100: run < 54 is 10 min → no level 2; level 1 runs 00:00–00:25.
        let result = events(Fixture.mg(50, 50, 60, 60, 60, 100, 100, 100))
        XCTAssertEqual(result.level2.count, 0)
        XCTAssertEqual(result.level1.events.map(\.duration), [1_500])
    }

    func testEventStillOpenWhenReadingsStop() {
        // 65 65 65 | 100 100; period [0, 25): recovery 00:15–00:25 is 10 min → not recovered.
        //   endedBy .noMoreReadings, end = coverage end of 00:10 = 00:15 → 15 min.
        let result = events(Fixture.mg(65, 65, 65, 100, 100), periodMinutes: 25)
        XCTAssertEqual(result.level1.events, [
            HypoEvent(level: .level1, start: Fixture.at(0), end: Fixture.at(15), endedBy: .noMoreReadings, startHourOfDay: 0),
        ])
    }

    func testCoverageStopsAtThePeriodEndWhenNoReadingFollows() {
        // 65 at 00:00, 00:05, 00:10 and nothing after. With no reading after the period, its end (for
        // today so far: now) caps coverage, so no event ends in the future and a count never drops when
        // the next reading arrives.
        //   period [0, 12): coverage end of 00:10 = 00:12 → 12 min → no event yet
        //   period [0, 15): coverage end of 00:10 = 00:15 → 15 min → one event, end 00:15
        XCTAssertEqual(events(Fixture.mg(65, 65, 65), periodMinutes: 12).level1.count, 0)
        XCTAssertEqual(events(Fixture.mg(65, 65, 65), periodMinutes: 15).level1.events, [
            HypoEvent(level: .level1, start: Fixture.at(0), end: Fixture.at(15), endedBy: .noMoreReadings, startHourOfDay: 0),
        ])
    }

    // MARK: Period boundaries (events belong to the period containing their start)

    /// Day A = [day0, day0 + 1 d), day B = [day0 + 1 d, day0 + 2 d).
    private let dayA = DateInterval(start: Fixture.day0, duration: Fixture.day)
    private let dayB = DateInterval(start: Fixture.day0.addingTimeInterval(Fixture.day), duration: Fixture.day)

    func testLowCrossingMidnightIsCountedOnceInThePeriodWhereItStarts() {
        // 65 at 23:50, 23:55 (day A), 00:00, 00:05 (day B); 100 at 00:10, 00:15, 00:20.
        //   Neither day alone holds 15 min of lows (10 min each). With 24 h of context on each side:
        //   day A: run 23:50 → coverage end of 00:05 = next reading 00:10 → 20 min → event starts 23:50 (in A);
        //          recovery 00:10–00:20, coverage end 00:25 → 15 min; end 00:10 → 20 min
        //   day B: the same event is seen through the look-back; it started in A, so B counts none.
        let readings = Fixture.series(from: Fixture.at(1_430), Fixture.mg(65, 65, 65, 65, 100, 100, 100))

        let a = events(readings, in: dayA)
        XCTAssertEqual(a.level1.events, [
            HypoEvent(level: .level1, start: Fixture.at(1_430), end: Fixture.at(1_450), endedBy: .recovery, startHourOfDay: 23),
        ])
        XCTAssertEqual(a.level1.startHourHistogram[23], 1)
        XCTAssertEqual(events(readings, in: dayB).level1.count, 0)
    }

    func testEventsOverlappingAnInterval() {
        // The 23:50–00:10 low from the test above, seen from day B: it starts in A (not in B's `events`)
        // but overlaps B. Overlap means start < interval.end and end > interval.start.
        let readings = Fixture.series(from: Fixture.at(1_430), Fixture.mg(65, 65, 65, 65, 100, 100, 100))
        let b = events(readings, in: dayB).level1
        let low = HypoEvent(level: .level1, start: Fixture.at(1_430), end: Fixture.at(1_450), endedBy: .recovery, startHourOfDay: 23)
        XCTAssertEqual(b.events, [])
        XCTAssertEqual(b.events(overlapping: dayB), [low])
        XCTAssertEqual(b.events(overlapping: dayA), [low])
        // Touching is not overlapping: an interval starting exactly at the event's end.
        XCTAssertEqual(b.events(overlapping: DateInterval(start: Fixture.at(1_450), duration: Fixture.hour)), [])
        XCTAssertEqual(b.events(overlapping: DateInterval(start: Fixture.at(1_449), duration: Fixture.hour)), [low])
    }

    func testOngoingLowAtPeriodStartIsNotANewEvent() {
        // A low from 23:30 (day A) to 00:30 (day B), then recovery. Day B sees its readings after 00:00
        // (30 min < 70) but the look-back shows they continue an event that started in A.
        let readings = Fixture.series(from: Fixture.at(1_410), Array(repeating: GlucoseValue.mgdl(60), count: 12) + Fixture.mg(100, 100, 100))
        XCTAssertEqual(events(readings, in: dayA).level1.events.map(\.start), [Fixture.at(1_410)])
        XCTAssertEqual(events(readings, in: dayB).level1.count, 0)
    }

    func testEventStartingAfterThePeriodIsNotCounted() {
        // Day A's look-ahead sees a low starting 01:00 on day B; it belongs to B only.
        let readings = Fixture.series(from: Fixture.at(1_500), Fixture.mg(65, 65, 65, 100, 100, 100))
        XCTAssertEqual(events(readings, in: dayA).level1.count, 0)
        XCTAssertEqual(events(readings, in: dayB).level1.events.map(\.start), [Fixture.at(1_500)])
    }

    func testContextOlderThanTwentyFourHoursIsNotUsed() {
        // Lows from day A 00:00 to 00:10 are 24 h before day B … exactly at the look-back limit (kept);
        // they start an event in A, which day B never counts. A reading 1 s before the limit is dropped.
        XCTAssertEqual(PeriodReadings.contextDuration, 24 * 3_600)
        let readings = Fixture.series(from: Fixture.day0, Fixture.mg(65, 65, 65, 100, 100, 100))
        let period = Fixture.period(readings, dayB)
        XCTAssertEqual(period.lookBackReadings.count, 6)
        let older = Fixture.period([Fixture.reading(Fixture.day0.addingTimeInterval(-1), .mgdl(65))], dayB)
        XCTAssertTrue(older.lookBackReadings.isEmpty)
    }

    func testReadingsCloserThanFiveMinutesCoverOnlyUntilTheNextOne() {
        // 65 every 2 min from 00:00 to 00:12 (7 readings), then 100 every 5 min from 00:14.
        //   low run: coverage end of 00:12 = next reading 00:14 → 14 min < 15 → no event.
        let lows = stride(from: 0.0, through: 12, by: 2).map { Fixture.reading(Fixture.at($0), .mgdl(65)) }
        let highs = [14.0, 19, 24].map { Fixture.reading(Fixture.at($0), .mgdl(100)) }
        XCTAssertEqual(events(lows + highs).level1.count, 0)
    }

    func testEmptyInput() {
        let result = events([GlucoseValue]())
        XCTAssertEqual(result.level1.count, 0)
        XCTAssertNil(result.level1.meanDuration)
        XCTAssertEqual(result.level1.startHourHistogram, Array(repeating: 0, count: 24))
        XCTAssertNil(result.level1.busiestWindow(hourCount: 3))
    }

    // MARK: Time of day

    func testStartHourHistogramAndBusiestWindow() {
        // Three separate episodes (65 ×3 then 100 ×3) starting 02:10, 03:40, 14:00 UTC.
        //   histogram: [2] = 1, [3] = 1, [14] = 1
        //   3-hour windows starting at an hour with an event: 02–05 → 2, 03–06 → 1, 14–17 → 1 → 02–05 with 2
        let starts: [Double] = [130, 220, 840]
        let readings = starts.flatMap { start in
            Fixture.series(from: Fixture.at(start), Fixture.mg(65, 65, 65, 100, 100, 100))
        }
        let summary = events(readings).level1

        XCTAssertEqual(summary.count, 3)
        var expected = Array(repeating: 0, count: 24)
        expected[2] = 1
        expected[3] = 1
        expected[14] = 1
        XCTAssertEqual(summary.startHourHistogram, expected)
        XCTAssertEqual(summary.busiestWindow(hourCount: 3), HourWindow(startHour: 2, hourCount: 3, eventCount: 2))
        XCTAssertEqual(summary.busiestWindow(hourCount: 3)?.endHour, 5)
        XCTAssertEqual(summary.busiestWindow(hourCount: 24), HourWindow(startHour: 2, hourCount: 24, eventCount: 3))
        XCTAssertNil(summary.busiestWindow(hourCount: 0))
        XCTAssertNil(summary.busiestWindow(hourCount: 25))
    }

    func testBusiestWindowWrapsPastMidnight() {
        // Events at 23:30 and 00:30 (next day). Window 23–02 holds both; 00–03 holds one.
        let first = Fixture.series(from: Fixture.at(23 * 60 + 30), Fixture.mg(65, 65, 65, 100, 100, 100))
        let second = Fixture.series(from: Fixture.at(24 * 60 + 30), Fixture.mg(65, 65, 65, 100, 100, 100))
        let summary = events(first + second, periodMinutes: 2 * 1_440).level1
        XCTAssertEqual(summary.busiestWindow(hourCount: 3), HourWindow(startHour: 23, hourCount: 3, eventCount: 2))
        XCTAssertEqual(summary.busiestWindow(hourCount: 3)?.endHour, 2)
    }

    func testStartHourUsesLocalWallClockOnFallBackDay() {
        // Nov 1 2026 New York: an episode starting 06:10 UTC = 01:10 EST (second pass of 01:00) → hour 1.
        let start = Fixture.fallBackDayStart.addingTimeInterval(130 * Fixture.minute) // 04:00 + 2:10 = 06:10 UTC
        let readings = Fixture.series(from: start, Fixture.mg(65, 65, 65, 100, 100, 100))
        let day = DateInterval(start: Fixture.fallBackDayStart, duration: 25 * Fixture.hour)
        let summary = HypoEvents(Fixture.period(readings, day, calendar: Fixture.newYork)).level1
        XCTAssertEqual(summary.events.first?.startHourOfDay, 1)
        XCTAssertEqual(summary.startHourHistogram[1], 1)
    }
}
