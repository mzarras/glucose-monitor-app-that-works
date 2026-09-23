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
    private(set) var uptime: Uptime?

    init(_ start: Date = Fixtures.t0, uptime: TimeInterval? = 1_000) {
        now = start
        self.uptime = uptime.map { Uptime(seconds: $0, boot: "boot-1") }
    }

    func advance(minutes: Double) {
        advance(seconds: minutes * 60)
    }

    func advance(seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        if seconds > 0, let current = uptime {
            uptime = Uptime(seconds: current.seconds + seconds, boot: current.boot)
        }
    }

    func set(_ date: Date) {
        now = date
    }

    /// The phone rebooted: a new boot session, the monotonic clock starting again from `value`.
    func reboot(uptime value: TimeInterval?) {
        let next = "boot-\(Int.random(in: 2...Int.max))"
        uptime = value.map { Uptime(seconds: $0, boot: next) }
    }
}
