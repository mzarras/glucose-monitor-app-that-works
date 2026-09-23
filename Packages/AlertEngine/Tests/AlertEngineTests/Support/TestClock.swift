import Foundation
@testable import AlertEngine

/// A clock the test moves by hand. No test in this package sleeps.
///
/// `advance` by a positive amount is real time passing: wall clock and `uptime` both move.
/// `set`, or `advance` by a negative amount, is someone changing the phone's clock: only the wall
/// clock moves.
@MainActor
final class TestClock: AlertClock {
    private(set) var now: Date
    private(set) var uptime: TimeInterval?

    init(_ start: Date = Fixtures.t0, uptime: TimeInterval? = 1_000) {
        now = start
        self.uptime = uptime
    }

    func advance(minutes: Double) {
        advance(seconds: minutes * 60)
    }

    func advance(seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        if seconds > 0, let current = uptime {
            uptime = current + seconds
        }
    }

    func set(_ date: Date) {
        now = date
    }

    /// The phone rebooted: the monotonic clock starts again from `value`.
    func reboot(uptime value: TimeInterval?) {
        uptime = value
    }
}
