// Trends: stored readings → `TrendsViewState`, through GlucoseStats (HANDOFF §6, §7.3.2;
// docs/statistics.md). Pure and nonisolated: `AppModel` runs it off the main actor. Nothing here
// creates, smooths or changes a reading (S1); LOW/HIGH stay flags everywhere (S4). The only
// smoothing is `AGPDisplaySmoothing.smoothedForDisplay`, whose output is chart geometry.
//
// Imported history counts for Trends (S6 allows charts and stats); the view state footnotes it.

import Foundation
import GlucoseCore
import GlucoseStats
import WidgetCore

enum TrendsMapping {
    /// Hours the "lows" note looks at: "4 of 6 between 2–5 AM".
    static let lowsWindowHours = 3
    /// The note names a busiest window only when there are at least this many lows (one low has no
    /// pattern to point out).
    static let lowsWindowMinimumEvents = 2

    static func calendarPeriod(_ period: TrendsPeriod) -> CalendarDayPeriod {
        switch period {
        case .oneDay: return .today
        case .threeDays: return .threeDays
        case .sevenDays: return .sevenDays
        case .fourteenDays: return .fourteenDays
        case .thirtyDays: return .thirtyDays
        case .ninetyDays: return .ninetyDays
        }
    }

    /// What Trends reads from the store: [previous period start − 24 h, now). The 24 h before the
    /// previous period are hypo-event context (docs/statistics.md "Which readings count").
    static func fetchInterval(period: TrendsPeriod, now: Date, calendar: Calendar) -> DateInterval {
        let previous = calendarPeriod(period).precedingInterval(endingAt: now, calendar: calendar)
        let start = previous.start.addingTimeInterval(-PeriodReadings.contextDuration)
        return DateInterval(start: start, end: max(start, now))
    }

    /// Every metric for `period` ending `now`, compared with the preceding equal number of days.
    /// - Parameter readings: stored readings covering `fetchInterval(period:now:calendar:)`, any source.
    static func make(period: TrendsPeriod, readings: [GlucoseReading], now: Date, calendar: Calendar) -> TrendsViewState {
        let options = StatisticsOptions(calendar: calendar)
        let comparison = GlucoseStatistics.compare(readings: readings, period: calendarPeriod(period), now: now, options: options)
        return make(period: period, comparison: comparison, readings: readings, now: now, calendar: calendar)
    }

    static func make(period: TrendsPeriod, comparison: PeriodComparison, readings: [GlucoseReading], now: Date, calendar: Calendar) -> TrendsViewState {
        let current = comparison.current
        let hasReadings = current.readingCount > 0
        var state = TrendsViewState.empty(period: period)
        state.interval = hasReadings ? current.interval : nil
        state.timeInRange = current.ranges.inRange.percent
        // Percentage deltas exist whenever both periods have readings (docs/statistics.md,
        // "Periods and comparison"); count and streak deltas are not shown on this screen.
        state.timeInRangeChange = comparison.inRangeDeltaPoints
        state.priorPeriodIsSparse = comparison.previous.readingCount > 0 && !comparison.previousHasSufficientData
        state.rangeBins = hasReadings ? rangeBins(current.ranges) : nil
        state.profile = hasReadings ? profile(period: period, statistics: current, readings: readings, now: now, calendar: calendar) : .none
        state.tightRange = current.ranges.tightRange.percent
        state.meanMgdl = current.meanAndVariability.meanMgdl
        // nil below 14 calendar dates (GlucoseManagementIndicator.isMeaningful), and the screen also
        // gates on the period, so a short-period GMI cannot appear by either path.
        state.gmiPercent = current.gmi.percent
        state.cvPercent = current.meanAndVariability.coefficientOfVariationPercent
        state.lows = hasReadings ? lows(current.hypoEvents.level1) : nil
        state.overnightTimeInRange = current.overnightAndDay.overnight.inRangePercent
        state.longestInRangeStreak = current.longestInRangeStreak?.duration
        state.afterExerciseTimeInRange = nil // v1.1 (HealthKit), row hidden
        // `nil` only when no reading is expected yet (a period of under 5 minutes): show 0 %, which
        // raises the warning, rather than hide it.
        state.dataSufficiency = current.dataSufficiency.percent ?? 0
        state.importedData = current.containsImportedReadings ? importedNote(readings: readings, interval: current.interval) : nil
        return state
    }

    // MARK: Parts

    static func rangeBins(_ ranges: RangeDistribution) -> RangeBins {
        RangeBins(
            veryLow: ranges.veryLow.percent ?? 0,
            low: ranges.low.percent ?? 0,
            inRange: ranges.inRange.percent ?? 0,
            high: ranges.high.percent ?? 0,
            veryHigh: ranges.veryHigh.percent ?? 0
        )
    }

    /// 1 D / 3 D: the real readings of each day (HANDOFF §7.3.2). 7 D and longer: the AGP.
    static func profile(period: TrendsPeriod, statistics: PeriodStatistics, readings: [GlucoseReading], now: Date, calendar: Calendar) -> DailyProfile {
        if period.showsDailyTraces {
            let days = dayTraces(dayCount: period.days, readings: readings, now: now, calendar: calendar)
            return days.allSatisfy(\.points.isEmpty) ? .none : .days(days)
        }
        let buckets = agpBuckets(statistics.agp)
        return buckets.isEmpty ? .none : .percentiles(buckets)
    }

    /// Smoothed-for-display AGP lines. Empty buckets are left out (the chart breaks the line where
    /// buckets are more than an hour apart, `AGPSegmentation`); flags stay flags.
    static func agpBuckets(_ profile: AGPProfile) -> [AGPBucket] {
        AGPDisplaySmoothing.smoothedForDisplay(profile).compactMap { bucket in
            guard let p5 = bucket.p5, let p25 = bucket.p25, let p50 = bucket.p50, let p75 = bucket.p75, let p95 = bucket.p95 else {
                return nil
            }
            return AGPBucket(minuteOfDay: bucket.startMinuteOfDay, p5: lineValue(p5), p25: lineValue(p25), p50: lineValue(p50),
                             p75: lineValue(p75), p95: lineValue(p95))
        }
    }

    static func lineValue(_ value: AGPDisplayValue) -> AGPLineValue {
        switch value {
        case .mgdl(let mgdl): return .mgdl(mgdl)
        case .belowRange: return .belowRange
        case .aboveRange: return .aboveRange
        }
    }

    /// Today and the `dayCount − 1` days before it, each with its stored readings in date order,
    /// exactly as stored (flags included). Ids dedupe a reading the store returned twice.
    static func dayTraces(dayCount: Int, readings: [GlucoseReading], now: Date, calendar: Calendar) -> [DayTrace] {
        let today = calendar.startOfDay(for: now)
        let sorted = readings.sorted { $0.date < $1.date }
        return (0..<max(1, dayCount)).compactMap { offset -> DayTrace? in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today).map(calendar.startOfDay(for:)),
                  let next = calendar.date(byAdding: .day, value: 1, to: start).map(calendar.startOfDay(for:)) else { return nil }
            let end = offset == 0 ? min(next, now.addingTimeInterval(LiveReadingGate.futureTolerance)) : next
            var seen = Set<String>()
            let points = sorted
                .filter { $0.date >= start && $0.date < end && seen.insert($0.id).inserted }
                .map(ChartPoint.init)
            return DayTrace(dayStart: start, isToday: offset == 0, points: points, timeZone: calendar.timeZone)
        }
    }

    static func lows(_ level1: HypoEventSummary) -> LowsSummary {
        let window: HourWindow? = level1.count >= lowsWindowMinimumEvents
            ? level1.busiestWindow(hourCount: lowsWindowHours).map { HourWindow(startHour: $0.startHour, endHour: $0.endHour, count: $0.eventCount) }
            : nil
        return LowsSummary(
            count: level1.count,
            meanDurationMinutes: level1.meanDuration.map { Int(($0 / 60).rounded()) },
            peakWindow: window
        )
    }

    /// Which import origins appear in the period, and the part of it they cover (footnote).
    static func importedNote(readings: [GlucoseReading], interval: DateInterval) -> ImportedDataNote? {
        var origins: Set<ImportOrigin> = []
        var first: Date?
        var last: Date?
        for reading in readings where reading.date >= interval.start && reading.date < interval.end {
            guard case .imported(let origin) = reading.source else { continue }
            origins.insert(origin)
            first = min(first ?? reading.date, reading.date)
            last = max(last ?? reading.date, reading.date)
        }
        guard let first, let last else { return nil }
        let ordered: [ImportOrigin] = [.nightscout, .clarityCSV].filter(origins.contains)
        // End just after the last imported reading, so the footnote names its day.
        return ImportedDataNote(origins: ordered, interval: DateInterval(start: first, end: last.addingTimeInterval(1)))
    }
}
