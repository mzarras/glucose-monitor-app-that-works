// The full statistics of one period: what the Trends screen and "Today so far" display.

import Foundation
import GlucoseCore

/// Inputs other than the readings and the interval.
public struct StatisticsOptions: Sendable, Equatable {
    /// Its time zone defines local time of day (AGP buckets, overnight window, hypo histogram) and
    /// its calendar days drive Trends periods and GMI's 14-day rule. Pass the user's current
    /// calendar; there is deliberately no default, so nothing depends on the host's time zone.
    public var calendar: Calendar
    public var overnightWindow: DailyWindow

    public init(calendar: Calendar, overnightWindow: DailyWindow = .defaultOvernight) {
        self.calendar = calendar
        self.overnightWindow = overnightWindow
    }
}

/// "In range after runs" (HANDOFF §6, §12: v1.1, needs HealthKit workouts). Not implemented in v1:
/// always `.unavailable`, and the Trends row stays hidden while `isImplemented` is false.
public enum AfterExerciseTimeInRange: Sendable, Equatable {
    case unavailable

    public static let isImplemented = false
}

/// Every HANDOFF §6 metric for one period. Units: percentages are 0…100 (unrounded), glucose is
/// mg/dL, durations are seconds.
public struct PeriodStatistics: Sendable, Equatable {
    /// `[start, end)`; readings outside it were ignored.
    public let interval: DateInterval
    /// Local calendar dates the interval touches (see `CalendarDays`).
    public let calendarDayCount: Int
    /// Counted readings: in the interval, one per instant.
    public let readingCount: Int
    /// Readings dropped because another reading had the same instant.
    public let duplicateCount: Int
    /// Some counted reading is imported history: show the Trends footnote (HANDOFF §4.5 step 4).
    public let containsImportedReadings: Bool

    /// Consensus bins, tight range, below 70, above 180.
    public let ranges: RangeDistribution
    /// Mean, sample SD, CV (numeric readings only).
    public let meanAndVariability: MeanAndVariability
    /// Withheld below 14 calendar days.
    public let gmi: GlucoseManagementIndicator
    /// Share of expected 5-minute readings present, and the < 70 % warning.
    public let dataSufficiency: DataSufficiency
    /// Raw percentile profile. For the chart, pass it to `AGPDisplaySmoothing`.
    public let agp: AGPProfile
    /// Level 1 and level 2 events.
    public let hypoEvents: HypoEvents
    public let overnightAndDay: OvernightAndDayTimeInRange
    /// `nil` without in-range readings.
    public let longestInRangeStreak: InRangeStreak?
    /// v1.1 stub.
    public let afterExerciseTimeInRange: AfterExerciseTimeInRange

    init(_ period: PeriodReadings, options: StatisticsOptions) {
        interval = period.interval
        calendarDayCount = CalendarDays.count(in: period.interval, calendar: options.calendar)
        readingCount = period.readings.count
        duplicateCount = period.duplicateCount
        containsImportedReadings = period.containsImportedReadings
        ranges = RangeDistribution(period)
        meanAndVariability = MeanAndVariability(period)
        gmi = GlucoseManagementIndicator(meanMgdl: meanAndVariability.meanMgdl, calendarDayCount: calendarDayCount)
        dataSufficiency = DataSufficiency(period)
        agp = AGPProfile(period)
        hypoEvents = HypoEvents(period)
        overnightAndDay = OvernightAndDayTimeInRange(period, window: options.overnightWindow)
        longestInRangeStreak = InRangeStreak.longest(in: period)
        afterExerciseTimeInRange = .unavailable
    }
}
