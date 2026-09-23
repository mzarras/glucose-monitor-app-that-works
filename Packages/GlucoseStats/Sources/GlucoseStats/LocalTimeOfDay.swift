// Local wall-clock time of day, the axis of the AGP chart, the overnight window, and the hypo
// time-of-day histogram (HANDOFF §6).

import Foundation

public enum LocalTimeOfDay {
    public static let secondsPerDay = 86_400

    /// Seconds since local midnight on the wall clock, `0..<86_400`.
    ///
    /// Computed as `(Unix time + the zone's UTC offset at that instant) mod 86 400`. Unix time has no
    /// leap seconds and its days start at UTC midnight, so adding the offset in force at the instant
    /// gives local wall-clock time, including on DST days: on a fall-back day both 01:30s map to
    /// 5 400 s; on a spring-forward day no instant maps to 02:00–02:59.
    ///
    /// Used instead of `Calendar.dateComponents` because it is about 3× faster for the 26 k readings
    /// of a 90-day period (measured on the host in a debug build: 3.6 ms vs 11.6 ms).
    public static func secondOfDay(for date: Date, in timeZone: TimeZone) -> Int {
        let unixSeconds = Int(date.timeIntervalSince1970.rounded(.down))
        let localSeconds = unixSeconds + timeZone.secondsFromGMT(for: date)
        let remainder = localSeconds % secondsPerDay
        // Swift's % keeps the dividend's sign; dates before 1970 need the positive remainder.
        return remainder >= 0 ? remainder : remainder + secondsPerDay
    }
}
