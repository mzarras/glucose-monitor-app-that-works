// The only source of "now" outside tests. Tests inject a clock they advance by hand, so every
// time-driven behaviour (repeats, snooze expiry, delays, missed readings, quiet hours) is tested
// without sleeping.

import Foundation

@MainActor
public protocol AlertClock: AnyObject {
    /// Wall-clock time. Can jump when the user or NTP changes the phone's clock.
    var now: Date { get }
    /// Real elapsed time on a clock that only moves forward and keeps counting while the phone
    /// sleeps, with the boot it belongs to; `nil` if unavailable. Lets the engine tell a wall-clock
    /// change from real time passing, even with no input in between (review WS4 delta).
    var uptime: Uptime? { get }
}

/// A reading of the monotonic clock. Two readings can be compared only within the same boot.
public struct Uptime: Sendable, Equatable, Codable {
    public let seconds: TimeInterval
    /// Identifies the boot (`kern.bootsessionuuid`); `nil` if unknown.
    public let boot: String?

    public init(seconds: TimeInterval, boot: String?) {
        self.seconds = seconds
        self.boot = boot
    }

    /// Real seconds from `earlier` to `self`, or `nil` if they are not comparable (different or
    /// unknown boot, or the clock went backwards, i.e. a reboot).
    public func seconds(since earlier: Uptime) -> TimeInterval? {
        guard boot == earlier.boot, seconds >= earlier.seconds else { return nil }
        return seconds - earlier.seconds
    }
}

@MainActor
public final class SystemAlertClock: AlertClock {
    public init() {}
    public var now: Date { Date() }

    /// Darwin `CLOCK_MONOTONIC_RAW`: "unaffected by frequency or time adjustments", and it keeps
    /// counting in sleep (clock_gettime(3): `CLOCK_UPTIME_RAW` is "in the same manner as
    /// CLOCK_MONOTONIC_RAW, but … does not increment while the system is asleep"). The boot session
    /// makes "same boot" explicit, so a reboot is never mistaken for a clock change.
    public var uptime: Uptime? {
        Uptime(seconds: TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000, boot: Self.bootSession)
    }

    /// `sysctl kern.bootsessionuuid`: a UUID string that changes at every boot.
    private static let bootSession: String? = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()
}
