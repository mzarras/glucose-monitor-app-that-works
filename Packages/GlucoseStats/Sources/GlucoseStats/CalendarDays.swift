// How many local calendar dates a period touches. Drives GMI's 14-day rule (HANDOFF §7.3 item 2).

import Foundation

public enum CalendarDays {
    /// The number of local calendar dates that the half-open interval `[start, end)` overlaps.
    ///
    /// Counted by walking local days: start at the local start of the day containing `start`, step to
    /// the next day's start (`startOfDay` of one calendar day later) while that start is before `end`.
    /// - Not 24-hour steps between instants: where DST starts at midnight (America/Santiago) a date
    ///   begins at 01:00 and lasts 23 h.
    /// - Not `ordinality(of: .day, in: .era)`: on this toolchain (Swift 6.2.3, macOS 26) Foundation
    ///   numbers those days by UTC whatever the calendar's time zone, so a New York evening or a Tokyo
    ///   morning lands on the wrong date (regression test `testLocalDateNotUTCDateDecidesTheDay`).
    /// - Only the calendar's time zone is used, with a Gregorian calendar: every calendar agrees on
    ///   where local days begin and end, and it avoids calendars whose eras restart (Japanese,
    ///   Heisei → Reiwa on 2019-05-01).
    ///
    /// Examples (see GMIAndCalendarDaysTests): `[Jan 5 00:00, Jan 19 00:00)` → 14;
    /// the Trends "14 D" period `[Jan 5 00:00, Jan 18 12:35)` → 14 (Jan 5 … Jan 18);
    /// a 23- or 25-hour DST day → 1; an empty interval → 0.
    public static func count(in interval: DateInterval, calendar: Calendar) -> Int {
        guard interval.duration > 0 else { return 0 }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone

        var count = 0
        var dayStart = gregorian.startOfDay(for: interval.start)
        while dayStart < interval.end {
            count += 1
            // `date(byAdding:)` only fails outside the calendar's range; stop rather than loop forever.
            guard let sameTimeNextDay = gregorian.date(byAdding: .day, value: 1, to: dayStart) else { break }
            dayStart = gregorian.startOfDay(for: sameTimeNextDay)
        }
        return count
    }
}
