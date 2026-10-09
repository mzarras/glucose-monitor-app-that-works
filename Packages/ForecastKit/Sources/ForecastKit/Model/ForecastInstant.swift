// Original to Sensor (no ported code).
// A moment read from two clocks, so a forecast's age survives the phone's clock being changed.
//
// The wall clock alone is not enough: if the user sets the clock back after a document arrived, a
// run measured only by the wall clock looks younger than it is, and newer documents are refused as
// future-dated, so the old run would be shown as current for longer than 15 minutes (review of
// 79c2c40, M2). The monotonic reading measures real time since the document arrived, whatever
// happens to the wall clock; `ForecastFreshness` takes the larger of the two ages.

import Foundation

/// The phone's wall clock and a monotonic clock, read together.
public struct ForecastInstant: Sendable, Equatable {
    /// The phone's clock. Can jump when the user or the network changes the time.
    public let wall: Date
    /// Seconds on a clock that only moves forward and keeps counting while the phone sleeps. Only
    /// the difference between two readings means anything, and only within one boot (the app
    /// keeps feed documents in memory only, so every pair it compares comes from one boot).
    public let monotonic: TimeInterval

    /// For tests and fakes; the app uses `now()`.
    public init(wall: Date, monotonic: TimeInterval) {
        self.wall = wall
        self.monotonic = monotonic
    }

    /// Both clocks now.
    ///
    /// The monotonic clock is Darwin `CLOCK_MONOTONIC_RAW`, the one the app's clock-mismatch check
    /// uses (AlertEngine `SystemAlertClock.uptime`, App/Sources/Pipeline/ClockMismatchMonitor.swift):
    /// unaffected by changes to the time and it keeps counting while the phone sleeps
    /// (clock_gettime(3): `CLOCK_UPTIME_RAW` is "in the same manner as CLOCK_MONOTONIC_RAW, but …
    /// does not increment while the system is asleep"). `ProcessInfo.systemUptime` is not used: it
    /// stops while the phone sleeps, so after a sleep it would understate a run's age.
    public static func now() -> ForecastInstant {
        ForecastInstant(
            wall: Date(),
            monotonic: TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
        )
    }
}
