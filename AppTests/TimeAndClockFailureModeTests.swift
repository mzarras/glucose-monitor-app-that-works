import GlucoseCore
import GlucoseStats
import WidgetCore
import XCTest
@testable import Sensor

/// Phase 3 failure modes, screens and model side: time zone changes, DST (America/New_York across
/// both 2026 transitions), and manual clock changes.
@MainActor
final class TimeAndClockFailureModeTests: XCTestCase {
    private static let newYork = TimeZone(identifier: "America/New_York")!
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, in zone: TimeZone = newYork) -> Date {
        calendar(zone).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// Every 5 minutes on the real clock (not the wall clock), so a DST day has 276 or 300 readings.
    private func everyFiveMinutes(from start: Date, to end: Date, _ value: @escaping (Date) -> GlucoseValue = { _ in .mgdl(120) }) -> [GlucoseReading] {
        series(from: start, to: end, step: 300, value)
    }

    private var ny: Calendar { calendar(Self.newYork) }
    private let nyContext = DisplayContext(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "America/New_York")!)
    private let tokyoContext = DisplayContext(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "Asia/Tokyo")!)

    // MARK: - DST: "Today so far"

    /// Spring forward (Mar 8 2026, 02:00 → 03:00): today so far counts exactly the readings since
    /// local midnight — 22 real hours at 23:00 — with nothing from yesterday and full coverage.
    func test_todaySoFarOnTheSpringForwardDay() {
        let now = date(2026, 3, 8, 23)
        let midnight = date(2026, 3, 8, 0)
        XCTAssertEqual(now.timeIntervalSince(midnight), 22 * 3_600, "a 23-hour day")
        let readings = everyFiveMinutes(from: midnight.addingTimeInterval(-86_400), to: now) { $0 < midnight ? .mgdl(250) : .mgdl(120) }
        let stats = GlucoseStatistics.todaySoFar(readings: readings, now: now, options: StatisticsOptions(calendar: ny))
        XCTAssertEqual(stats.readingCount, 22 * 12)
        XCTAssertEqual(stats.dataSufficiency.percent ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(NowMapping.today(readings, now: now, calendar: ny), TodaySummary(timeInRangePercent: 100, averageMgdl: 120, lowCount: 0),
                       "no reading from before midnight leaks in")
    }

    /// Fall back (Nov 1 2026, 02:00 → 01:00): the repeated hour is counted once per reading, not
    /// dropped or doubled — 24 real hours at 23:00.
    func test_todaySoFarOnTheFallBackDay() {
        let now = date(2026, 11, 1, 23)
        let midnight = date(2026, 11, 1, 0)
        XCTAssertEqual(now.timeIntervalSince(midnight), 24 * 3_600, "a 25-hour day")
        let readings = everyFiveMinutes(from: midnight.addingTimeInterval(-86_400), to: now) { $0 < midnight ? .mgdl(250) : .mgdl(120) }
        let stats = GlucoseStatistics.todaySoFar(readings: readings, now: now, options: StatisticsOptions(calendar: ny))
        XCTAssertEqual(stats.readingCount, 24 * 12)
        XCTAssertEqual(stats.dataSufficiency.percent ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(NowMapping.today(readings, now: now, calendar: ny).timeInRangePercent, 100)
    }

    // MARK: - DST: Trends periods, labels, AGP, day traces

    /// Every Trends period that contains a DST change counts each reading once (coverage exactly
    /// 100 % with a reading every 5 real minutes) and labels the right local dates.
    func test_trendsPeriodsAcrossBothTransitions() {
        let cases: [(now: Date, period: TrendsPeriod, label: String)] = [
            (date(2026, 3, 8, 23), .oneDay, "MAR 8"),
            (date(2026, 3, 10, 12), .sevenDays, "MAR 4 – MAR 10"),
            (date(2026, 3, 20, 12), .fourteenDays, "MAR 7 – MAR 20"),
            (date(2026, 11, 1, 23), .oneDay, "NOV 1"),
            (date(2026, 11, 3, 12), .sevenDays, "OCT 28 – NOV 3"),
            (date(2026, 11, 10, 12), .thirtyDays, "OCT 12 – NOV 10"),
            (date(2026, 11, 10, 12), .ninetyDays, "AUG 13 – NOV 10"),
        ]
        for (now, period, label) in cases {
            let fetch = TrendsMapping.fetchInterval(period: period, now: now, calendar: ny)
            let readings = everyFiveMinutes(from: fetch.start, to: now)
            let state = TrendsMapping.make(period: period, readings: readings, now: now, calendar: ny)
            XCTAssertEqual(state.dataSufficiency, 100, accuracy: 0.01, "\(period) at \(now): no reading doubled or dropped")
            XCTAssertEqual(TrendsText.dateRange(state.interval, context: nyContext), label, "\(period)")
            XCTAssertEqual(state.interval?.start, ny.startOfDay(for: state.interval?.start ?? now), "\(period) starts at local midnight")
            XCTAssertEqual(state.meanMgdl, 120)
        }
    }

    /// AGP time-of-day buckets across fall back: both 01:30s fall in the 01:30 bucket (wall clock),
    /// every bucket is unique and within the day, and a value seen only in the repeated hour shows up.
    func test_agpBucketsAcrossFallBack() {
        let now = date(2026, 11, 7, 12)
        let fetch = TrendsMapping.fetchInterval(period: .sevenDays, now: now, calendar: ny)
        let firstOne = date(2026, 11, 1, 1) // 01:00 EDT
        let readings = everyFiveMinutes(from: fetch.start, to: now) { date in
            // The second pass through 01:00–01:59 (EST, the hour after the first one) reads 300.
            date >= firstOne.addingTimeInterval(3_600) && date < firstOne.addingTimeInterval(7_200) ? .mgdl(300) : .mgdl(120)
        }
        let state = TrendsMapping.make(period: .sevenDays, readings: readings, now: now, calendar: ny)
        guard case .percentiles(let buckets) = state.profile else { return XCTFail("expected an AGP") }
        XCTAssertEqual(Set(buckets.map(\.minuteOfDay)).count, buckets.count, "unique buckets")
        XCTAssertTrue(buckets.allSatisfy { (0..<1_440).contains($0.minuteOfDay) })
        XCTAssertEqual(buckets.count, 96)
        let at0130 = buckets.first { $0.minuteOfDay == 90 }
        XCTAssertGreaterThan(at0130?.p95.mgdl ?? 0, 200, "the repeated hour's readings are in the 01:xx buckets")
        XCTAssertEqual(state.dataSufficiency, 100, accuracy: 0.01)
    }

    /// 1 D across fall back: today's trace starts at local midnight and holds all 24 h 59 min of real
    /// readings; on the time-of-day axis the last one sits at its clock time, 23:55 (review m17).
    func test_dayTraceOnTheFallBackDay() {
        let now = date(2026, 11, 1, 23, 59)
        let readings = everyFiveMinutes(from: date(2026, 10, 31, 0), to: now)
        let traces = TrendsMapping.dayTraces(dayCount: 1, readings: readings, now: now, calendar: ny)
        XCTAssertEqual(traces.first?.dayStart, date(2026, 11, 1, 0))
        XCTAssertEqual(traces.first?.timeZone, Self.newYork)
        XCTAssertEqual(traces.first?.points.count, 300, "24 h 59 min of real time to 23:59, every 5 min")
        let last = traces.first?.points.last.map { TimeOfDayAxis.hourOfDay($0.date, dayStart: date(2026, 11, 1, 0), timeZone: Self.newYork) } ?? 0
        XCTAssertEqual(last, 23 + 55.0 / 60, accuracy: 0.001)
    }

    /// Review m17: on both DST days every reading sits at its clock time on the overlay's axis (so
    /// the 3 D overlay compares the same clock times), the repeated hour's two passes share x, and
    /// the skipped hour is empty.
    func test_overlayPlotsClockTimeOnDSTDays() {
        let zone = Self.newYork
        for (y, m, d) in [(2026, 3, 8), (2026, 11, 1), (2026, 9, 23)] {
            let midnight = date(y, m, d, 0)
            for (h, min) in [(0, 30), (1, 30), (3, 30), (12, 0), (18, 45), (23, 55)] {
                let instant = date(y, m, d, h, min)
                XCTAssertEqual(TimeOfDayAxis.hourOfDay(instant, dayStart: midnight, timeZone: zone), Double(h) + Double(min) / 60, accuracy: 0.0001,
                               "\(m)/\(d) \(h):\(min)")
                XCTAssertEqual(TimeOfDayAxis.date(atHour: Double(h) + Double(min) / 60, dayStart: midnight, timeZone: zone), instant,
                               "the scrub's inverse, \(m)/\(d) \(h):\(min)")
            }
            let nextMidnight = ny.date(byAdding: .day, value: 1, to: midnight)!
            XCTAssertEqual(TimeOfDayAxis.hourOfDay(nextMidnight, dayStart: midnight, timeZone: zone), 24, accuracy: 0.0001)
            XCTAssertEqual(TimeOfDayAxis.date(atHour: 24, dayStart: midnight, timeZone: zone), nextMidnight)
        }
        // Fall back: 01:30 EDT and 01:30 EST (an hour later) are both at 1.5; the scrub picks the first.
        let fallMidnight = date(2026, 11, 1, 0)
        let firstPass = fallMidnight.addingTimeInterval(1.5 * 3_600)
        let secondPass = firstPass.addingTimeInterval(3_600)
        XCTAssertEqual(TimeOfDayAxis.hourOfDay(secondPass, dayStart: fallMidnight, timeZone: zone), 1.5, accuracy: 0.0001)
        XCTAssertEqual(TimeOfDayAxis.date(atHour: 1.5, dayStart: fallMidnight, timeZone: zone), firstPass)
        // Spring forward: 02:00–02:59 never happens; a finger there selects the moment of the jump.
        let springMidnight = date(2026, 3, 8, 0)
        let jump = springMidnight.addingTimeInterval(2 * 3_600)
        XCTAssertEqual(TimeOfDayAxis.hourOfDay(jump, dayStart: springMidnight, timeZone: zone), 3, accuracy: 0.0001)
        XCTAssertEqual(TimeOfDayAxis.date(atHour: 2.5, dayStart: springMidnight, timeZone: zone), jump)
    }

    /// Review m17: a line never joins two readings across a clock change (it would cross the
    /// skipped hour or double back over the repeated one); every reading is still drawn.
    func test_overlayLinesSplitAtTheClockChange() {
        for midnight in [date(2026, 3, 8, 0), date(2026, 11, 1, 0)] {
            let points = stride(from: 0.0, to: 23 * 3_600, by: 300).map { PlottedPoint(date: midnight.addingTimeInterval($0), mgdl: 120) }
            let lines = TimeOfDayAxis.splitAtClockChanges(points, timeZone: Self.newYork)
            XCTAssertEqual(lines.count, 2, "\(midnight)")
            XCTAssertEqual(lines.flatMap { $0 }, points, "nothing dropped or added (S1)")
            for line in lines {
                let hours = line.map { TimeOfDayAxis.hourOfDay($0.date, dayStart: midnight, timeZone: Self.newYork) }
                XCTAssertEqual(hours, hours.sorted(), "each line runs forward on the axis")
                XCTAssertTrue(zip(hours, hours.dropFirst()).allSatisfy { $1 - $0 < 0.1 }, "no jump across the skipped hour")
            }
        }
        let ordinary = stride(from: 0.0, to: 23 * 3_600, by: 300).map { PlottedPoint(date: date(2026, 9, 23, 0).addingTimeInterval($0), mgdl: 120) }
        XCTAssertEqual(TimeOfDayAxis.splitAtClockChanges(ordinary, timeZone: Self.newYork).count, 1)
    }

    /// The Now chart's 24 H is 24 real hours, whatever the wall clock did.
    func test_nowChartCoversTwentyFourRealHoursAcrossDST() {
        for now in [date(2026, 3, 8, 12), date(2026, 11, 1, 12)] {
            let readings = everyFiveMinutes(from: now.addingTimeInterval(-48 * 3_600), to: now.addingTimeInterval(1))
            let recent = NowMapping.recent(readings, now: now, calendar: ny)
            XCTAssertEqual(recent.chartPoints.count, 24 * 12 + 1, "\(now)")
            XCTAssertEqual(recent.chartPoints.first?.date, now.addingTimeInterval(-24 * 3_600))
        }
    }

    // MARK: - Time zone change

    /// A time zone change moves local midnight: "Today so far" is recomputed in the new zone.
    func test_timeZoneChangeRecomputesTodaySoFar() async {
        let now = t0 // 2026-09-23 12:35 UTC = 08:35 New York = 21:35 Tokyo
        let nyMidnight = calendar(Self.newYork).startOfDay(for: now)
        let readings = everyFiveMinutes(from: now.addingTimeInterval(-36 * 3_600), to: now) { $0 < nyMidnight ? .mgdl(250) : .mgdl(120) }
        let services = PreviewAppServices(readings: readings, sensorState: activeSensor)
        services.latestLiveReading = readings.last
        let defaults = UserDefaults(suiteName: "TimeAndClock.\(UUID().uuidString)")!
        let preferences = AppUIPreferences(defaults: defaults)
        preferences.onboardingCompleted = true
        let model = AppModel.launch(services: services, arguments: [], preferences: preferences, calendar: calendar(Self.newYork),
                                    clock: { now }, protectedDataAvailable: { true })
        model.apply(.sensor)
        await model.settle()
        XCTAssertEqual(model.now.today.timeInRangePercent, 100, "New York: today starts at its midnight")
        model.calendarDidChange(calendar(Self.tokyo))
        await model.settle()
        let tokyoToday = NowMapping.today(readings, now: now, calendar: calendar(Self.tokyo))
        XCTAssertEqual(model.now.today, tokyoToday)
        XCTAssertLessThan(model.now.today.timeInRangePercent ?? 100, 60, "Tokyo's today began 13 h earlier, in the 250s")
    }

    /// Clock-time labels follow the zone: banners, the grace countdown's banner line, calibration
    /// "last calibrated". The countdown itself is a duration and doesn't change.
    func test_clockTimeLabelsFollowTheTimeZone() {
        let endsAt = t0.addingTimeInterval(7 * 3_600)
        let grace = SensorState.gracePeriod(endsAt: endsAt)
        let nyBanner = AppBanners.make(sensorState: grace, latestLiveReadingDate: t0, health: healthy, now: t0, context: nyContext)
            .first { $0.kind == .sensorExpiring }
        let tokyoBanner = AppBanners.make(sensorState: grace, latestLiveReadingDate: t0, health: healthy, now: t0, context: tokyoContext)
            .first { $0.kind == .sensorExpiring }
        XCTAssertEqual(nyBanner?.detail, "Readings stop at \(TimeText.time(endsAt, nyContext)). Replace the sensor soon.")
        XCTAssertEqual(tokyoBanner?.detail, "Readings stop at \(TimeText.time(endsAt, tokyoContext)). Replace the sensor soon.")
        XCTAssertTrue(TimeText.time(endsAt, nyContext).hasPrefix("3:35"))
        XCTAssertTrue(TimeText.time(endsAt, tokyoContext).hasPrefix("4:35"))
        XCTAssertEqual(GraceCountdown.clock(until: endsAt, now: t0), "7:00:00", "the countdown is a duration")

        var state = Fixtures.calibration(.accepted, at: t0)
        state.sensorState = activeSensor
        let submission = CalibrationSubmission(request: CalibrationRequest(mgdl: 112, takenAt: t0), outcome: .status(.accepted), updatedAt: t0)
        XCTAssertEqual(CalibrationRules.lastCalibrationText(submission, state: state, now: t0, context: nyContext),
                       "Last calibration 112 mg/dL at \(TimeText.time(t0, nyContext)): accepted.")
        XCTAssertEqual(CalibrationRules.lastCalibrationText(submission, state: state, now: t0, context: tokyoContext),
                       "Last calibration 112 mg/dL at \(TimeText.time(t0, tokyoContext)): accepted.")
        XCTAssertTrue(TimeText.time(t0, nyContext).hasPrefix("8:35") && TimeText.time(t0, tokyoContext).hasPrefix("9:35"))
    }

    // MARK: - Manual clock changes

    /// The phone's clock jumps forward 30 min: the reading is old, the hero says so (no number), and
    /// the missed-readings banner counts from the reading.
    func test_clockJumpsForward() {
        var state = NowViewState.empty
        state.sensorState = activeSensor
        state.latestLiveReading = latest(.mgdl(120), ageMinutes: 2)
        let jumped = t0.addingTimeInterval(30 * 60)
        guard case .noData = state.display(now: jumped) else { return XCTFail("a 32-minute-old reading is not current") }
        let banner = state.banners(now: jumped, context: testContext).first { $0.kind == .missedReadings }
        XCTAssertEqual(banner?.title, "No reading for 32 min")
    }

    /// The phone's clock is set back 10 min: the reading is now dated in the future — "clock
    /// mismatch", never current; it stays so (latched) after the clock passes the reading's date,
    /// until a newer reading arrives.
    func test_clockSetBack() async {
        let reading = sensorReading(t0.addingTimeInterval(-2 * 60), .mgdl(120))
        let services = PreviewAppServices(readings: [reading], sensorState: activeSensor)
        services.latestLiveReading = reading
        let clock = TestClock(t0.addingTimeInterval(-10 * 60))
        let defaults = UserDefaults(suiteName: "TimeAndClock.\(UUID().uuidString)")!
        let preferences = AppUIPreferences(defaults: defaults)
        preferences.onboardingCompleted = true
        let model = AppModel.launch(services: services, arguments: [], preferences: preferences, calendar: utcCalendar,
                                    clock: { clock.now }, protectedDataAvailable: { true })
        model.apply(.sensor)
        guard case .clockMismatch = model.now.display(now: clock.now) else { return XCTFail("dated 8 min ahead: clock mismatch") }
        XCTAssertTrue(model.now.banners(now: clock.now, context: testContext).contains { $0.kind == .missedReadings && $0.title == "No current reading" })
        clock.now = t0
        model.tick()
        guard case .clockMismatch = model.now.display(now: clock.now) else { return XCTFail("latched after the clock caught up") }
    }

    /// The chart scrub never lands on a reading dated after `now` (clock set back): such a point is
    /// not drawn or selectable until the clock passes it.
    func test_chartScrubNeverLandsOnAFuturePoint() {
        let now = t0
        let points = (0..<30).map { ChartPoint(date: now.addingTimeInterval(Double($0 - 25) * 300), value: .mgdl(100 + $0)) } // last 4 ahead of now
        XCTAssertTrue(points.contains { $0.date > now })
        let visible = NowMapping.visibleChartPoints(points, now: now)
        XCTAssertTrue(visible.allSatisfy { $0.date <= now })
        for offset in stride(from: -3_600.0, through: 0, by: 30) {
            if let selected = ChartScrub.select(at: now.addingTimeInterval(offset), in: visible).reading {
                XCTAssertLessThanOrEqual(selected.date, now, "scrub at \(offset) s")
            }
        }
        // Unfiltered, the scrub at the right edge would have selected a future reading.
        XCTAssertGreaterThan(ChartScrub.select(at: now.addingTimeInterval(200), in: points).reading?.date ?? now, now)
        XCTAssertEqual(NowMapping.visibleChartPoints(Array(points.prefix(10)), now: now), Array(points.prefix(10)), "nothing ahead: unchanged")
    }
}
