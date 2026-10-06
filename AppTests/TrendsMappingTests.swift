import GlucoseCore
import GlucoseStats
import WidgetCore
import XCTest
@testable import Sensor

/// Trends view state from GlucoseStats (HANDOFF §6, §7.3.2; docs/statistics.md wiring notes).
final class TrendsMappingTests: XCTestCase {
    private let now = t0 // 2026-09-23 12:35 UTC

    private func trends(_ period: TrendsPeriod, _ readings: [GlucoseReading]) -> TrendsViewState {
        TrendsMapping.make(period: period, readings: readings, now: now, calendar: utcCalendar)
    }

    private func days(_ n: Double) -> TimeInterval { n * 86_400 }

    /// Trends fetches [previous-period start − 24 h, now): the previous period plus hypo context.
    func test_fetchIntervalCoversThePreviousPeriodAndA24HourMargin() {
        let interval = TrendsMapping.fetchInterval(period: .fourteenDays, now: now, calendar: utcCalendar)
        let previous = CalendarDayPeriod.fourteenDays.precedingInterval(endingAt: now, calendar: utcCalendar)
        XCTAssertEqual(interval.start, previous.start.addingTimeInterval(-86_400))
        XCTAssertEqual(interval.end, now)
        // 14 D on Sep 23 = Sep 10 – Sep 23 vs Aug 27 – Sep 9; fetch from Aug 26 00:00.
        XCTAssertEqual(interval.start, utcCalendar.date(from: DateComponents(year: 2026, month: 8, day: 26)))
    }

    /// HANDOFF §7.3.2: GMI only for 14 D and longer — nil below, whatever the data.
    func test_gmiOnlyFor14DaysAndLonger() {
        let readings = series(from: now.addingTimeInterval(-days(200)), to: now) { _ in .mgdl(120) }
        for period in [TrendsPeriod.oneDay, .threeDays, .sevenDays] {
            let state = trends(period, readings)
            XCTAssertNil(state.gmiPercent, "\(period)")
            XCTAssertEqual(TrendsText.gmi(state.gmiPercent, period: period), "needs 14 days")
        }
        for period in [TrendsPeriod.fourteenDays, .thirtyDays, .ninetyDays] {
            let state = trends(period, readings)
            XCTAssertEqual(state.gmiPercent ?? 0, 3.31 + 0.02392 * 120, accuracy: 0.0001, "\(period)")
            XCTAssertEqual(state.meanMgdl, 120)
            XCTAssertEqual(state.timeInRange, 100)
            XCTAssertNil(TrendsText.sufficiencyWarning(state.dataSufficiency), "\(period): full coverage")
        }
    }

    /// HANDOFF §6: the data-sufficiency warning under 70 % on every period, and next to GMI.
    func test_dataSufficiencyWarningUnder70PercentIncludingNextToGMI() {
        // One reading every 10 minutes = 50 % of the expected 5-minute readings.
        let readings = series(from: now.addingTimeInterval(-days(40)), to: now, step: 600) { _ in .mgdl(110) }
        for period in [TrendsPeriod.oneDay, .sevenDays, .fourteenDays, .thirtyDays] {
            let state = trends(period, readings)
            XCTAssertEqual(state.dataSufficiency, 50, accuracy: 1, "\(period)")
            XCTAssertNotNil(TrendsText.sufficiencyWarning(state.dataSufficiency), "\(period)")
        }
        let fourteen = trends(.fourteenDays, readings)
        XCTAssertNotNil(fourteen.gmiPercent, "GMI is shown from 14 D even on sparse data…")
        XCTAssertEqual(TrendsText.gmiNote(period: .fourteenDays, coverage: fourteen.dataSufficiency), "est. A1C · only 50% of readings",
                       "…with the warning next to it")
        XCTAssertEqual(TrendsText.gmiNote(period: .fourteenDays, coverage: 95), "est. A1C")
    }

    /// Deltas are nil when there is nothing to compare with; sparse prior periods are marked.
    func test_deltasNilWhenNotComparable() {
        let currentOnly = series(from: utcCalendar.startOfDay(for: now), to: now) { _ in .mgdl(120) }
        let state = trends(.oneDay, currentOnly)
        XCTAssertNotNil(state.timeInRange)
        XCTAssertNil(state.timeInRangeChange, "no prior data")
        XCTAssertEqual(TrendsText.change(state.timeInRangeChange, period: .oneDay), "no prior data to compare")

        // Yesterday: half in range (100 / 200 alternating); today: all in range → +50 points.
        let yesterday = series(from: utcCalendar.startOfDay(for: now).addingTimeInterval(-86_400), to: utcCalendar.startOfDay(for: now)) { date in
            Int(date.timeIntervalSince1970 / 300) % 2 == 0 ? .mgdl(100) : .mgdl(200)
        }
        let compared = trends(.oneDay, yesterday + currentOnly)
        XCTAssertEqual(compared.timeInRangeChange ?? 0, 50, accuracy: 0.5)
        XCTAssertFalse(compared.priorPeriodIsSparse)

        // A sparse prior day (one reading an hour) still compares, but says so.
        let sparseYesterday = series(from: utcCalendar.startOfDay(for: now).addingTimeInterval(-86_400), to: utcCalendar.startOfDay(for: now), step: 3_600) { _ in .mgdl(250) }
        let sparse = trends(.oneDay, sparseYesterday + currentOnly)
        XCTAssertTrue(sparse.priorPeriodIsSparse)
        XCTAssertTrue(TrendsText.change(sparse.timeInRangeChange, period: .oneDay, priorIsSparse: true).hasSuffix("(sparse data)"))
    }

    /// S4: LOW/HIGH stay flags in every part of Trends — bins, mean, AGP lines, daily traces.
    func test_S4_trendsNeverTurnFlagsIntoNumbers() {
        // 14 days: LOW every day 02:00–03:00, HIGH 12:00–12:30, otherwise 150.
        let readings = series(from: now.addingTimeInterval(-days(30)), to: now) { date in
            let minute = utcCalendar.component(.hour, from: date) * 60 + utcCalendar.component(.minute, from: date)
            if (120..<180).contains(minute) { return .belowRange }
            if (720..<750).contains(minute) { return .aboveRange }
            return .mgdl(150)
        }
        let state = trends(.fourteenDays, readings)
        XCTAssertEqual(state.meanMgdl, 150, "flags are excluded from the mean, never counted as 40/400")
        XCTAssertGreaterThan(state.rangeBins?.veryLow ?? 0, 0, "LOW counts below 54")
        XCTAssertGreaterThan(state.rangeBins?.veryHigh ?? 0, 0, "HIGH counts above 250")
        guard case .percentiles(let buckets) = state.profile else { return XCTFail("expected an AGP") }
        let at0230 = buckets.first { $0.minuteOfDay == 150 }
        XCTAssertEqual(at0230?.p50, .belowRange, "a LOW percentile stays LOW")
        XCTAssertNil(at0230?.p50.mgdl)
        let at1215 = buckets.first { $0.minuteOfDay == 735 }
        XCTAssertEqual(at1215?.p50, .aboveRange, "a HIGH percentile stays HIGH")
        for bucket in buckets {
            for value in [bucket.p5, bucket.p25, bucket.p50, bucket.p75, bucket.p95] {
                if let mgdl = value.mgdl { XCTAssertTrue((40...400).contains(mgdl)) }
            }
        }
        // Drawn at the chart's edges, spoken as LOW/HIGH.
        XCTAssertEqual(AGPLineValue.belowRange.chartY(floor: 40, ceiling: 250), 40)
        XCTAssertEqual(AGPLineValue.aboveRange.chartY(floor: 40, ceiling: 250), 250)
        XCTAssertTrue(TrendsText.agpSpeech(buckets).contains("LOW (below sensor range)"))

        for period in [TrendsPeriod.oneDay, .threeDays] {
            guard case .days(let traces) = trends(period, readings).profile else { return XCTFail("expected daily traces") }
            let values = traces.flatMap(\.points).map(\.value)
            XCTAssertTrue(values.contains(.belowRange), "\(period)")
            XCTAssertFalse(values.contains(.mgdl(40)))
            XCTAssertFalse(values.contains(.mgdl(400)))
            XCTAssertEqual(traces.count, period.days)
            XCTAssertEqual(traces.filter(\.isToday).count, 1)
        }
    }

    /// Review m1 (S4): with a HIGH percentile the AGP's top is 400, so the HIGH line never sits at a
    /// ceiling (250) that reads as a value; without one, the usual axis.
    func test_S4_agpHighPercentileIsDrawnAboveEveryNumber() {
        let numeric = [AGPBucket(minuteOfDay: 0, p5: 80, p25: 100, p50: 120, p75: 140, p95: 180)]
        XCTAssertEqual(AGPChartScale.upperBound(numeric), ChartScale.yUpperBound(maxPlotted: 180))
        let withHigh = numeric + [AGPBucket(minuteOfDay: 15, p5: .mgdl(150), p25: .mgdl(180), p50: .mgdl(220), p75: .mgdl(240), p95: .aboveRange)]
        XCTAssertEqual(AGPChartScale.upperBound(withHigh), 400)
        XCTAssertEqual(AGPLineValue.aboveRange.chartY(floor: 40, ceiling: Double(AGPChartScale.upperBound(withHigh))), 400)
        XCTAssertGreaterThan(AGPChartScale.upperBound(withHigh), ChartScale.yUpperBound(maxPlotted: 240), "not at the numeric ceiling")
    }

    /// 1 D / 3 D show the real readings of each day, and nothing else (S1).
    func test_S1_dailyTracesAreExactlyTheStoredReadings() {
        let start = utcCalendar.startOfDay(for: now).addingTimeInterval(-2 * 86_400)
        let readings = series(from: start, to: now, step: 900) { date in .mgdl(100 + Int(date.timeIntervalSince1970 / 900) % 50) }
        guard case .days(let traces) = trends(.threeDays, readings).profile else { return XCTFail("expected daily traces") }
        let points = traces.flatMap(\.points)
        XCTAssertEqual(points.count, readings.count)
        XCTAssertEqual(Set(points.map(\.date)), Set(readings.map(\.date)))
        XCTAssertEqual(traces.first { $0.isToday }?.dayStart, utcCalendar.startOfDay(for: now))
    }

    /// HANDOFF §4.5 step 4: periods with imported history carry the footnote.
    func test_importedHistoryIsFootnoted() {
        let importedStart = now.addingTimeInterval(-days(10))
        let imported = stride(from: importedStart.timeIntervalSince1970, to: now.addingTimeInterval(-days(5)).timeIntervalSince1970, by: 300)
            .map { importedReading(Date(timeIntervalSince1970: $0), .mgdl(130)) }
        let live = series(from: now.addingTimeInterval(-days(5)), to: now) { _ in .mgdl(120) }
        let state = trends(.fourteenDays, imported + live)
        XCTAssertEqual(state.importedData?.origins, [.nightscout])
        XCTAssertEqual(state.importedData?.interval.start, importedStart)
        XCTAssertNotNil(TrendsText.importedFootnote(state.importedData))
        XCTAssertNil(trends(.oneDay, imported + live).importedData, "today has no imported readings")
    }

    /// "Lows" row: level 1 events that start in the period, the busiest 3-hour window (§6 histogram).
    func test_lowsNoteFromTheBusiestWindow() {
        let dayStart = utcCalendar.startOfDay(for: now)
        var readings = series(from: dayStart.addingTimeInterval(-6 * 86_400), to: now) { _ in .mgdl(120) }
        // Three 30-minute lows at 02:10 on three days, one at 15:00.
        let lowStarts = [-1, -2, -3].map { dayStart.addingTimeInterval(Double($0) * 86_400 + 2 * 3_600 + 600) }
            + [dayStart.addingTimeInterval(-4 * 86_400 + 15 * 3_600)]
        readings = readings.map { reading in
            lowStarts.contains { reading.date >= $0 && reading.date < $0.addingTimeInterval(1_800) } ? sensorReading(reading.date, .mgdl(60)) : reading
        }
        let lows = trends(.sevenDays, readings).lows
        XCTAssertEqual(lows?.count, 4)
        XCTAssertEqual(lows?.peakWindow, HourWindow(startHour: 2, endHour: 5, count: 3))
        XCTAssertEqual(lows.flatMap(TrendsText.lowsNote), "3 of 4 between 2–5 AM")
        XCTAssertEqual(lows?.meanDurationMinutes, 30)
    }

    func test_noReadingsGivesAnEmptyPeriod() {
        let state = trends(.fourteenDays, [])
        XCTAssertNil(state.interval)
        XCTAssertNil(state.timeInRange)
        XCTAssertNil(state.rangeBins)
        XCTAssertEqual(state.profile, DailyProfile.none)
        XCTAssertNil(state.lows)
        XCTAssertNotNil(TrendsText.sufficiencyWarning(state.dataSufficiency))
    }
}
