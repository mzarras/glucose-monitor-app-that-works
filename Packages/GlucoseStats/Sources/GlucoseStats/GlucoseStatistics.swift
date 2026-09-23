// Public entry points. Pure functions: no I/O, no clock, no stored state. Callers pass the readings
// (typically `GlucoseReadingRepository.readings(from:to:)` for the whole span), the period, `now`
// where relevant, and the user's calendar.

import Foundation
import GlucoseCore

public enum GlucoseStatistics {
    /// Every metric for `interval`. Readings outside it are ignored; see `PeriodReadings` for the
    /// selection rules.
    public static func compute(readings: [GlucoseReading], interval: DateInterval, options: StatisticsOptions) -> PeriodStatistics {
        let period = PeriodReadings(readings: readings, interval: interval, calendar: options.calendar)
        return PeriodStatistics(period, options: options)
    }

    /// The Now screen's "Today so far": `compute` over [local midnight, now). "Lows" there is
    /// `hypoEvents.level1.count`.
    public static func todaySoFar(readings: [GlucoseReading], now: Date, options: StatisticsOptions) -> PeriodStatistics {
        compute(readings: readings, interval: CalendarDayPeriod.today.interval(endingAt: now, calendar: options.calendar), options: options)
    }

    /// A Trends period and the equal number of calendar days immediately before it (see
    /// `CalendarDayPeriod`). `readings` must cover both periods.
    public static func compare(readings: [GlucoseReading], period: CalendarDayPeriod, now: Date, options: StatisticsOptions) -> PeriodComparison {
        let current = compute(readings: readings, interval: period.interval(endingAt: now, calendar: options.calendar), options: options)
        let previous = compute(readings: readings, interval: period.precedingInterval(endingAt: now, calendar: options.calendar), options: options)
        return PeriodComparison(current: current, previous: previous)
    }
}
