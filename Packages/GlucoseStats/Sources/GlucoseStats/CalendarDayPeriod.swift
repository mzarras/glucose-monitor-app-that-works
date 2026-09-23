// Trends periods (HANDOFF §7.3 item 2: 1/3/7/14/30/90 D, default 14 D, "vs yesterday" /
// "vs prior 3 days") and "Today so far" (§7.3 item 1).

import Foundation

/// A period of N local calendar days that ends now, and the N full days immediately before it.
///
///     current   = [start of the day N − 1 days before today, now)
///     preceding = [current.start − N calendar days, current.start)
///
/// So "1 D" is today so far (the same interval as the Now screen's "Today so far") compared with
/// all of yesterday, and "14 D" on Sep 23 is Sep 10 – Sep 23 compared with Aug 27 – Sep 9. Both
/// periods span N calendar days; the current one is shorter in elapsed time because it ends now.
/// All percentages compare fairly; data sufficiency is computed against each period's own
/// elapsed time. Day arithmetic uses the calendar, so a DST day is 23 or 25 hours long.
public struct CalendarDayPeriod: Sendable, Equatable, Hashable {
    public let dayCount: Int

    public static let today = CalendarDayPeriod(validDayCount: 1)
    public static let threeDays = CalendarDayPeriod(validDayCount: 3)
    public static let sevenDays = CalendarDayPeriod(validDayCount: 7)
    public static let fourteenDays = CalendarDayPeriod(validDayCount: 14)
    public static let thirtyDays = CalendarDayPeriod(validDayCount: 30)
    public static let ninetyDays = CalendarDayPeriod(validDayCount: 90)

    /// The Trends selector, in order.
    public static let trendsChoices = [today, threeDays, sevenDays, fourteenDays, thirtyDays, ninetyDays]
    public static let trendsDefault = fourteenDays

    /// `nil` for fewer than 1 day.
    public init?(dayCount: Int) {
        guard dayCount >= 1 else { return nil }
        self.init(validDayCount: dayCount)
    }

    private init(validDayCount: Int) {
        dayCount = validDayCount
    }

    public func interval(endingAt now: Date, calendar: Calendar) -> DateInterval {
        DateInterval(start: start(endingAt: now, calendar: calendar), end: now)
    }

    public func precedingInterval(endingAt now: Date, calendar: Calendar) -> DateInterval {
        let currentStart = start(endingAt: now, calendar: calendar)
        return DateInterval(start: Self.startOfDay(dayCount, daysBefore: currentStart, calendar: calendar), end: currentStart)
    }

    private func start(endingAt now: Date, calendar: Calendar) -> Date {
        Self.startOfDay(dayCount - 1, daysBefore: calendar.startOfDay(for: now), calendar: calendar)
    }

    /// Local midnight `days` calendar days before the day of `date`. `startOfDay` again after adding,
    /// because in zones whose DST change happens at midnight a day can start at 01:00.
    private static func startOfDay(_ days: Int, daysBefore date: Date, calendar: Calendar) -> Date {
        // `date(byAdding:)` only fails for dates outside the calendar's range; stay put rather than crash.
        let shifted = calendar.date(byAdding: .day, value: -days, to: date) ?? date
        return calendar.startOfDay(for: shifted)
    }
}
