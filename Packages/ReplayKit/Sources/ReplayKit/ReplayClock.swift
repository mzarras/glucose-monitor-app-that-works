// Replay time. DEBUG only (S6): this whole file is compiled out of Release.
#if DEBUG
import Foundation

/// The clock a replay source plays its timeline against. Events are delivered when the clock
/// reaches their date. Three implementations:
/// - `ImmediateReplayClock`: virtual time that jumps to each deadline (tests: a scenario plays
///   instantly and deterministically);
/// - `ManualReplayClock`: virtual time that moves only when a test advances it;
/// - `ScaledReplayClock`: wall-clock time, real time or accelerated (UI demos).
public protocol ReplayClock: Sendable {
    /// The replay's "now". An accelerated run moves ahead of the phone clock, so the app's DEBUG
    /// replay wiring must use this as its clock (staleness, alerts, `LiveReadingGate` `now`).
    func now() async -> Date
    /// Returns once `now() >= deadline`. Throws `CancellationError` if the task is cancelled first.
    func sleep(until deadline: Date) async throws
}

/// Virtual time that jumps straight to each deadline. Nothing ever waits.
public actor ImmediateReplayClock: ReplayClock {
    private var current: Date

    public init(start: Date) {
        current = start
    }

    public func now() -> Date {
        current
    }

    public func sleep(until deadline: Date) throws {
        try Task.checkCancellation()
        if deadline > current {
            current = deadline
        }
    }
}

/// Wall-clock replay time. Scenario time starts at `start` when the clock is created and runs
/// `speed` times faster than real time: 1 = real time (dates track the phone clock when `start`
/// is now), 60 = one scenario hour per wall-clock minute.
public struct ScaledReplayClock: ReplayClock {
    public let start: Date
    public let speed: Double
    private let wallStart: ContinuousClock.Instant

    public init(start: Date, speed: Double) {
        precondition(speed > 0 && speed.isFinite, "speed must be a positive number")
        self.start = start
        self.speed = speed
        self.wallStart = ContinuousClock.now
    }

    public func now() -> Date {
        Self.scenarioDate(start: start, speed: speed, wallElapsed: ContinuousClock.now - wallStart)
    }

    public func sleep(until deadline: Date) async throws {
        let delay = Self.wallDelay(until: deadline, from: now(), speed: speed)
        guard delay > 0 else { return }
        // Task.sleep throws CancellationError when the task is cancelled (stop()).
        try await Task.sleep(for: .seconds(delay))
    }

    /// Scenario date after `wallElapsed` of real time.
    static func scenarioDate(start: Date, speed: Double, wallElapsed: Duration) -> Date {
        let seconds = Double(wallElapsed.components.seconds) + Double(wallElapsed.components.attoseconds) / 1e18
        return start.addingTimeInterval(seconds * speed)
    }

    /// Real seconds to wait for scenario time to go from `now` to `deadline` (0 if already past).
    static func wallDelay(until deadline: Date, from now: Date, speed: Double) -> TimeInterval {
        max(0, deadline.timeIntervalSince(now) / speed)
    }
}
#endif
