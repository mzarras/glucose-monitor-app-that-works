// How many local calendar dates a period touches. Drives GMI's 14-day rule (HANDOFF §7.3 item 2).

import Foundation

public enum CalendarDays {
    /// The number of local calendar dates that the half-open interval `[start, end)` overlaps.
    ///
    /// Examples (see GMIAndCalendarDaysTests): `[Jan 5 00:00, Jan 19 00:00)` → 14;
    /// the Trends "14 D" period `[Jan 5 00:00, Jan 18 12:35)` → 14 (Jan 5 … Jan 18);
    /// a 23- or 25-hour DST day → 1; an empty interval → 0.
    public static func count(in interval: DateInterval, calendar: Calendar) -> Int {
        guard interval.duration > 0 else { return 0 }
        let firstMidnight = calendar.startOfDay(for: interval.start)
        let lastMidnight = calendar.startOfDay(for: interval.end)
        let wholeDays = calendar.dateComponents([.day], from: firstMidnight, to: lastMidnight).day ?? 0
        // `end` is exclusive: if it falls exactly on a midnight, that date is not touched.
        return interval.end == lastMidnight ? wholeDays : wholeDays + 1
    }
}
