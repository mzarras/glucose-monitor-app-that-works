// Original to Sensor (no ported code).
// The 15-minute rule (PROGRESS D57): only a run made in the last 15 minutes is a current forecast.
//
// A run's age is measured two ways and the larger one counts (review of 79c2c40, M2):
//   by the wall clock now:     now.wall − generatedAt
//   from when it arrived:      (receivedAt.wall − generatedAt) + (now.monotonic − receivedAt.monotonic)
// The second is the run's age when its document arrived plus the real time since, so setting the
// phone's clock back after that cannot make the run look younger. Setting it forward makes the
// first larger, so the run goes stale early: that errs safe.

import Foundation

/// Whether a model run may be shown as the current forecast.
public enum ForecastFreshness: Sendable, Equatable {
    /// Made within the last `ForecastLimits.staleAfter`. `age` is the conservative age above,
    /// never negative (a run up to `ForecastLimits.clockSkewTolerance` ahead of the phone's clock
    /// reports age 0).
    case current(age: TimeInterval)
    /// Older than `ForecastLimits.staleAfter` by either measure, or its age cannot be measured
    /// because the monotonic clock went backwards. The UI shows "out of date", not the values.
    case stale(age: TimeInterval)
    /// More than `ForecastLimits.clockSkewTolerance` ahead of the phone's clock. The decoder
    /// refuses such documents, so this happens only when the clock was set back after the document
    /// arrived. Not current: the UI treats it like stale.
    case aheadOfClock(by: TimeInterval)

    /// True only for `.current`: the only case in which forecast values may be shown.
    public var isCurrent: Bool {
        if case .current = self { return true }
        return false
    }

    /// Classifies a run made at `generatedAt`, whose document arrived at `receivedAt`, at `now`.
    /// Pure; the caller injects both instants. The app reaches it through
    /// `LatestForecast.zenFreshness(at:)` and `currentRun(at:)`.
    static func classify(generatedAt: Date, receivedAt: ForecastInstant, at now: ForecastInstant) -> ForecastFreshness {
        let wallAge = now.wall.timeIntervalSince(generatedAt)
        if wallAge < -ForecastLimits.clockSkewTolerance { return .aheadOfClock(by: -wallAge) }
        let age = conservativeAge(generatedAt: generatedAt, receivedAt: receivedAt, at: now)
        // The monotonic clock cannot go backwards within one boot and documents live only in
        // memory, so this is unreachable in the app. If it ever happens the elapsed time is
        // unknown, and a run of unknown age is never current.
        if now.monotonic < receivedAt.monotonic { return .stale(age: age) }
        if age > ForecastLimits.staleAfter { return .stale(age: age) }
        return .current(age: age)
    }

    /// `max(now.wall − generatedAt, (receivedAt.wall − generatedAt) + (now.monotonic −
    /// receivedAt.monotonic), 0)`. If the monotonic clock went backwards no elapsed time is
    /// counted (the second term is then the age on arrival), and `classify` reports `.stale`.
    static func conservativeAge(generatedAt: Date, receivedAt: ForecastInstant, at now: ForecastInstant) -> TimeInterval {
        let wallAge = now.wall.timeIntervalSince(generatedAt)
        let ageOnArrival = receivedAt.wall.timeIntervalSince(generatedAt)
        let elapsedSinceArrival = max(now.monotonic - receivedAt.monotonic, 0)
        return max(wallAge, ageOnArrival + elapsedSinceArrival, 0)
    }
}
