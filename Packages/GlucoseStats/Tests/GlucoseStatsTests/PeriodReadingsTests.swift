import XCTest
import GlucoseCore
@testable import GlucoseStats

/// Which readings count toward a period: inside the half-open interval, one per instant, ascending,
/// each with its local wall-clock time of day.
final class PeriodReadingsTests: XCTestCase {

    func testKeepsOnlyReadingsInsideHalfOpenInterval() {
        // Interval [00:00, 01:00). Readings at −5, 0, 30, 60, 65 minutes.
        // Inside: 0 and 30 (start inclusive, end exclusive, as GlucoseReadingRepository.readings).
        let interval = Fixture.interval(minutes: 60)
        let readings = [-5.0, 0, 30, 60, 65].map { Fixture.reading(Fixture.at($0), .mgdl(100)) }

        let period = Fixture.period(readings, interval)

        XCTAssertEqual(period.readings.map(\.date), [Fixture.at(0), Fixture.at(30)])
        XCTAssertEqual(period.outsideIntervalCount, 3)
        // Outside the interval but within 24 h: kept only as hypo-detection context.
        XCTAssertEqual(period.lookBackReadings.map(\.date), [Fixture.at(-5)])
        XCTAssertEqual(period.lookAheadReadings.map(\.date), [Fixture.at(60), Fixture.at(65)])
        XCTAssertEqual(period.duplicateCount, 0)
        XCTAssertEqual(period.interval, interval)
    }

    func testSortsUnsortedInputAscending() {
        let interval = Fixture.interval(minutes: 60)
        let readings = [
            Fixture.reading(Fixture.at(10), .mgdl(130)),
            Fixture.reading(Fixture.at(0), .mgdl(110)),
            Fixture.reading(Fixture.at(5), .mgdl(120)),
        ]

        let period = Fixture.period(readings, interval)

        XCTAssertEqual(period.readings.map(\.date), [Fixture.at(0), Fixture.at(5), Fixture.at(10)])
        XCTAssertEqual(period.readings.map(\.value), Fixture.mg(110, 120, 130))
    }

    func testDuplicateInstantPrefersSensorOverImportedInEitherInputOrder() {
        // Same instant: sensor says 100, Nightscout history says 150. Rule: one reading per instant,
        // the live sensor wins, so the counted value is 100 and one duplicate is dropped.
        let interval = Fixture.interval(minutes: 60)
        let sensor = Fixture.reading(Fixture.at(5), .mgdl(100))
        let imported = Fixture.reading(Fixture.at(5), .mgdl(150), source: .imported(.nightscout))

        for input in [[sensor, imported], [imported, sensor]] {
            let period = Fixture.period(input, interval)
            XCTAssertEqual(period.readings.count, 1)
            XCTAssertEqual(period.readings.first?.value, .mgdl(100))
            XCTAssertEqual(period.readings.first?.source, .sensor)
            XCTAssertEqual(period.duplicateCount, 1)
        }
    }

    func testDuplicateInstantSourcePreferenceOrder() {
        // Preference: sensor, then imported, then replay, then mock.
        let interval = Fixture.interval(minutes: 60)
        let date = Fixture.at(0)
        let imported = Fixture.reading(date, .mgdl(101), source: .imported(.clarityCSV))
        let replay = Fixture.reading(date, .mgdl(102), source: .replay)
        let mock = Fixture.reading(date, .mgdl(103), source: .mock)

        XCTAssertEqual(Fixture.period([mock, replay, imported], interval).readings.map(\.value), Fixture.mg(101))
        XCTAssertEqual(Fixture.period([mock, replay], interval).readings.map(\.value), Fixture.mg(102))
        XCTAssertEqual(Fixture.period([replay, mock], interval).readings.map(\.value), Fixture.mg(102))
    }

    func testDuplicateInstantPrefersLiveOverBackfill() {
        let interval = Fixture.interval(minutes: 60)
        let live = Fixture.reading(Fixture.at(0), .mgdl(100), serial: "SN-B")
        let backfill = Fixture.reading(Fixture.at(0), .mgdl(200), isBackfill: true, serial: "SN-A")

        for input in [[live, backfill], [backfill, live]] {
            XCTAssertEqual(Fixture.period(input, interval).readings.map(\.value), Fixture.mg(100))
        }
    }

    func testDuplicateInstantSameSourceTieBreaksOnSmallestID() {
        // Two sensor readings at one instant from different serials: ids "SN-A:…" < "SN-B:…".
        let interval = Fixture.interval(minutes: 60)
        let a = Fixture.reading(Fixture.at(0), .mgdl(100), serial: "SN-A")
        let b = Fixture.reading(Fixture.at(0), .mgdl(200), serial: "SN-B")

        for input in [[a, b], [b, a]] {
            let period = Fixture.period(input, interval)
            XCTAssertEqual(period.readings.map(\.value), Fixture.mg(100))
            XCTAssertEqual(period.duplicateCount, 1)
        }
    }

    func testReadingsOneSecondApartAreNotDuplicates() {
        // Only an identical instant is a duplicate; near-duplicates are the store's job (§4.5 step 3).
        let interval = Fixture.interval(minutes: 60)
        let readings = [
            Fixture.reading(Fixture.at(0), .mgdl(100)),
            Fixture.reading(Fixture.at(0).addingTimeInterval(1), .mgdl(100), source: .imported(.nightscout)),
        ]
        XCTAssertEqual(Fixture.period(readings, interval).readings.count, 2)
    }

    func testContainsImportedReadingsOnlyForCountedReadings() {
        let interval = Fixture.interval(minutes: 60)
        let sensor = Fixture.reading(Fixture.at(0), .mgdl(100))
        let importedDuplicate = Fixture.reading(Fixture.at(0), .mgdl(100), source: .imported(.nightscout))
        let importedOutside = Fixture.reading(Fixture.at(90), .mgdl(100), source: .imported(.nightscout))
        let importedInside = Fixture.reading(Fixture.at(30), .mgdl(100), source: .imported(.clarityCSV))

        XCTAssertFalse(Fixture.period([sensor], interval).containsImportedReadings)
        // The imported copy lost to the sensor reading, and the other one is outside the interval.
        XCTAssertFalse(Fixture.period([sensor, importedDuplicate, importedOutside], interval).containsImportedReadings)
        XCTAssertTrue(Fixture.period([sensor, importedInside], interval).containsImportedReadings)
    }

    func testBandAndGapFlagsAreComputedPerCountedReading() {
        // 00:00 LOW | 00:15 100 (15 min later: bridged) | 00:31 300 (16 min: gap) | 00:32 60
        // plus an imported duplicate of 00:00, which must not affect the gap flags.
        let readings = [
            Fixture.reading(Fixture.at(0), .belowRange),
            Fixture.reading(Fixture.at(0), .mgdl(90), source: .imported(.nightscout)),
            Fixture.reading(Fixture.at(15), .mgdl(100)),
            Fixture.reading(Fixture.at(31), .mgdl(300)),
            Fixture.reading(Fixture.at(32), .mgdl(60)),
        ]
        let period = Fixture.period(readings, Fixture.interval(minutes: 60))
        XCTAssertEqual(period.readings.map(\.band), [.veryLow, .inRange, .veryHigh, .low])
        XCTAssertEqual(period.readings.map(\.startsAfterGap), [false, false, true, false])
    }

    func testContextReadingsAroundTheInterval() {
        // Interval [01:00, 02:00). Input: 00:40 sensor + an imported copy of it (look-back), 01:00, 01:05 and
        // an imported copy of 01:05 (interval), 02:00, 02:10 (look-ahead).
        //   01:00 is 20 min after 00:40 → it starts after a gap, judged against the look-back reading.
        //   duplicateCount and containsImportedReadings describe the interval only: 1 and false.
        //   outsideIntervalCount = 7 inputs − 3 inside = 4.
        let interval = DateInterval(start: Fixture.at(60), duration: Fixture.hour)
        let readings = [
            Fixture.reading(Fixture.at(40), .mgdl(100)),
            Fixture.reading(Fixture.at(40), .mgdl(100), source: .imported(.nightscout)),
            Fixture.reading(Fixture.at(60), .mgdl(100)),
            Fixture.reading(Fixture.at(65), .mgdl(100)),
            Fixture.reading(Fixture.at(65), .mgdl(90), source: .imported(.nightscout)),
            Fixture.reading(Fixture.at(120), .mgdl(100)),
            Fixture.reading(Fixture.at(130), .mgdl(100)),
        ]
        let period = Fixture.period(readings, interval)

        XCTAssertEqual(period.lookBackReadings.map(\.date), [Fixture.at(40)])
        XCTAssertEqual(period.readings.map(\.date), [Fixture.at(60), Fixture.at(65)])
        XCTAssertEqual(period.lookAheadReadings.map(\.date), [Fixture.at(120), Fixture.at(130)])
        XCTAssertEqual(period.readings.map(\.startsAfterGap), [true, false])
        XCTAssertEqual(period.duplicateCount, 1)
        XCTAssertFalse(period.containsImportedReadings)
        XCTAssertEqual(period.outsideIntervalCount, 4)
    }

    func testEmptyInput() {
        let period = Fixture.period([], Fixture.interval(minutes: 60))
        XCTAssertTrue(period.readings.isEmpty)
        XCTAssertEqual(period.outsideIntervalCount, 0)
        XCTAssertEqual(period.duplicateCount, 0)
        XCTAssertFalse(period.containsImportedReadings)
    }

    // MARK: Local time of day

    func testSecondOfDayInUTC() {
        // 13:45:30 UTC = 13 × 3600 + 45 × 60 + 30 = 46 800 + 2 700 + 30 = 49 530 s.
        let date = Fixture.day0.addingTimeInterval(49_530)
        XCTAssertEqual(LocalTimeOfDay.secondOfDay(for: date, in: Fixture.utc.timeZone), 49_530)
        let period = Fixture.period([Fixture.reading(date, .mgdl(100))], Fixture.interval(minutes: 1_440))
        XCTAssertEqual(period.readings.first?.secondOfDay, 49_530)
    }

    func testSecondOfDayUsesCalendarTimeZone() {
        // 2026-01-05 12:00 UTC = 07:00 EST (UTC−5) → 7 × 3600 = 25 200 s.
        let date = Fixture.day0.addingTimeInterval(12 * Fixture.hour)
        let period = Fixture.period(
            [Fixture.reading(date, .mgdl(100))], Fixture.interval(minutes: 1_440), calendar: Fixture.newYork
        )
        XCTAssertEqual(period.readings.first?.secondOfDay, 25_200)
    }

    func testSecondOfDayFallBackRepeatsTheWallClockHour() {
        // 2026-11-01: 05:30 UTC = 01:30 EDT (UTC−4); 06:30 UTC = 01:30 EST (UTC−5).
        // Both are 01:30 on the wall clock → 1.5 × 3600 = 5 400 s.
        let tz = Fixture.newYork.timeZone
        let firstPass = Fixture.fallBackDayStart.addingTimeInterval(1.5 * Fixture.hour)  // 05:30 UTC
        let secondPass = Fixture.fallBackDayStart.addingTimeInterval(2.5 * Fixture.hour) // 06:30 UTC
        XCTAssertEqual(LocalTimeOfDay.secondOfDay(for: firstPass, in: tz), 5_400)
        XCTAssertEqual(LocalTimeOfDay.secondOfDay(for: secondPass, in: tz), 5_400)
    }

    func testSecondOfDaySpringForwardSkipsTheWallClockHour() {
        // 2026-03-08: 06:55 UTC = 01:55 EST → 6 900 s; five minutes later 07:00 UTC = 03:00 EDT → 10 800 s.
        let tz = Fixture.newYork.timeZone
        let before = Fixture.springForwardDayStart.addingTimeInterval(115 * Fixture.minute) // 06:55 UTC
        let after = Fixture.springForwardDayStart.addingTimeInterval(120 * Fixture.minute)  // 07:00 UTC
        XCTAssertEqual(LocalTimeOfDay.secondOfDay(for: before, in: tz), 6_900)
        XCTAssertEqual(LocalTimeOfDay.secondOfDay(for: after, in: tz), 10_800)
    }

    func testSecondOfDayBefore1970IsStillInRange() {
        // 1969-12-31 23:00:00 UTC = Unix −3 600 → 82 800 s after midnight.
        let date = Date(timeIntervalSince1970: -3_600)
        XCTAssertEqual(LocalTimeOfDay.secondOfDay(for: date, in: Fixture.utc.timeZone), 82_800)
    }
}
