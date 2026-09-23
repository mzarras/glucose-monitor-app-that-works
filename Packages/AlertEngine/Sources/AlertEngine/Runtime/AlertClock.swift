// The only source of "now" outside tests. Tests inject a clock they advance by hand, so every
// time-driven behaviour (repeats, snooze expiry, delays, missed readings, quiet hours) is tested
// without sleeping.

import Foundation

@MainActor
public protocol AlertClock: AnyObject {
    var now: Date { get }
}

@MainActor
public final class SystemAlertClock: AlertClock {
    public init() {}
    public var now: Date { Date() }
}
