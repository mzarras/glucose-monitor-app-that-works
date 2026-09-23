// How many local calendar dates a period touches. Drives GMI's 14-day rule (HANDOFF §7.3 item 2).

import Foundation

public enum CalendarDays {
    /// The number of local calendar dates that the half-open interval `[start, end)` overlaps.
    ///
    /// Counted by date (year/month/day), not by 24-hour steps between instants: where DST starts at
    /// midnight (e.g. America/Santiago) a date begins at 01:00 and lasts 23 h, and stepping from
    /// that 01:00 would miss it.
    ///
    /// Examples (see GMIAndCalendarDaysTests): `[Jan 5 00:00, Jan 19 00:00)` → 14;
    /// the Trends "14 D" period `[Jan 5 00:00, Jan 18 12:35)` → 14 (Jan 5 … Jan 18);
    /// a 23- or 25-hour DST day → 1; an empty interval → 0.
    public static func count(in interval: DateInterval, calendar: Calendar) -> Int {
        guard interval.duration > 0 else { return 0 }
        let firstDate = dateNumber(of: interval.start, calendar: calendar)
        var lastDate = dateNumber(of: interval.end, calendar: calendar)
        // `end` is exclusive: if it is the first instant of its date, that date is not touched.
        if calendar.startOfDay(for: interval.end) == interval.end { lastDate -= 1 }
        return lastDate - firstDate + 1
    }

    /// Consecutive integer per local date (the date's ordinal within the calendar's era).
    static func dateNumber(of date: Date, calendar: Calendar) -> Int {
        // Only nil for calendars without eras or days; the Gregorian calendar always answers.
        calendar.ordinality(of: .day, in: .era, for: date) ?? 0
    }
}
