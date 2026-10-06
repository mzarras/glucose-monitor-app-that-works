// The clocks the pipeline and the alert service run on. Production: the phone clock and the
// monotonic uptime clock. DEBUG replay: the replay clock (an accelerated run moves ahead of the
// phone clock, so staleness, alerts and the gate's `now` must use it — docs/replay.md "Time").
// Tests: a clock they set by hand.

import AlertEngine
import Foundation

/// An `AlertClock` over the pipeline's `now`, so the alert engine and the gate agree on the time.
@MainActor
final class PipelineAlertClock: AlertClock {
    private let wallClock: @Sendable () -> Date
    private let uptimeClock: (@MainActor () -> Uptime?)?

    /// - Parameters:
    ///   - now: the wall clock.
    ///   - uptime: the monotonic clock, or nil where it does not follow `now` (replay, tests); the
    ///     engine then detects a clock rollback from wall-clock time alone (docs/alerts.md §5).
    init(now: @escaping @Sendable () -> Date, uptime: (@MainActor () -> Uptime?)?) {
        self.wallClock = now
        self.uptimeClock = uptime
    }

    var now: Date { wallClock() }
    var uptime: Uptime? { uptimeClock?() }

    /// The phone clock with the real monotonic clock (`SystemAlertClock`).
    static func system() -> PipelineAlertClock {
        let system = SystemAlertClock()
        return PipelineAlertClock(now: { Date() }, uptime: { system.uptime })
    }
}
