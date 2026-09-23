// The only source of "now" outside tests. Tests inject a clock they advance by hand, so every
// time-driven behaviour (repeats, snooze expiry, delays, missed readings, quiet hours) is tested
// without sleeping.

import Foundation

@MainActor
public protocol AlertClock: AnyObject {
    /// Wall-clock time. Can jump when the user or NTP changes the phone's clock.
    var now: Date { get }
    /// Seconds on a clock that only moves forward, keeps counting while the phone sleeps, and is
    /// shared by every process until the next reboot; `nil` if unavailable. Lets the engine tell a
    /// wall-clock change from real time passing, even with no input in between (review WS4 delta).
    var uptime: TimeInterval? { get }
}

@MainActor
public final class SystemAlertClock: AlertClock {
    public init() {}
    public var now: Date { Date() }

    /// Darwin `CLOCK_MONOTONIC`: "continues to increment while the system is asleep" (clock_gettime(3));
    /// unlike `CLOCK_UPTIME_RAW` / `ProcessInfo.systemUptime`, which stop during sleep.
    public var uptime: TimeInterval? {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
}
