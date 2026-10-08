// Original to Sensor (no ported code).
// latest.json, validated. Contract: zen-predict-infra lambdas/handlers/publish.py `LATEST_CONTRACT`
// (exact key set; `filter_doc` emits absent keys as null) built by `build_latest`.
//
// The Zen run itself is not public: the only way to its values is `currentRun(at:)`, which returns
// nil unless the run is current by the 15-minute rule (D57). Everything else the Predict tab needs
// about a run that is not current (its time, its age, why) has its own accessor.

import Foundation

/// One validated latest.json document, stamped with the instant it arrived.
public struct LatestForecast: Sendable, Equatable {
    /// When the publish Lambda wrote the document (`as_of`).
    public let asOf: Date
    /// The newest Zen Predict run, or nil when the feed has none yet (`generated_at` null or every
    /// value null). Internal: use `currentRun(at:)`.
    let zen: ForecastRun?
    /// Trio's oref forecast for comparison, or nil. Internal: it has no time (see `OrefForecast`),
    /// may be up to 48 h old, and is not shown in v1 (PROGRESS D58 (3)). It can become public with
    /// its own freshness once the feed publishes `oref_generated_at`.
    let oref: OrefForecast?
    /// The newest CGM reading the feed had (`bg`), informational only; nil when not published.
    public let feedGlucose: FeedGlucose?
    /// The model that made the Zen run (`model_version`).
    public let modelVersion: String?
    /// When the document arrived (both clocks). A 304 keeps the original instant (see
    /// `ForecastFeedClient.fetchLatest`).
    let receivedAt: ForecastInstant

    init(asOf: Date, zen: ForecastRun?, oref: OrefForecast?, feedGlucose: FeedGlucose?, modelVersion: String?, receivedAt: ForecastInstant) {
        self.asOf = asOf
        self.zen = zen
        self.oref = oref
        self.feedGlucose = feedGlucose
        self.modelVersion = modelVersion
        self.receivedAt = receivedAt
    }

    /// The Zen run's time (`predictions.generated_at`), for "last model run …" when the run is not
    /// current; nil when the feed has no run yet.
    public var zenRunTime: Date? { zen?.generatedAt }

    /// The Zen run's age at `now`, nil when there is no run: the larger of its age by the phone's
    /// clock now and its age when the document arrived plus the real time since
    /// (`ForecastFreshness`), never negative. Setting the phone's clock back does not lower it.
    public func zenRunAge(at now: ForecastInstant) -> TimeInterval? {
        guard let zen else { return nil }
        return ForecastFreshness.conservativeAge(generatedAt: zen.generatedAt, receivedAt: receivedAt, at: now)
    }

    /// Whether the Zen run may be shown as current at `now`; nil when there is no run.
    public func zenFreshness(at now: ForecastInstant) -> ForecastFreshness? {
        guard let zen else { return nil }
        return ForecastFreshness.classify(generatedAt: zen.generatedAt, receivedAt: receivedAt, at: now)
    }

    /// The Zen run if it may be shown as the current forecast at `now` (15-minute rule, D57),
    /// otherwise nil. When this is nil but `zenRunTime` is not, show "out of date" with that time,
    /// never the values. Evaluate it when drawing and at least once a minute.
    public func currentRun(at now: ForecastInstant) -> ForecastRun? {
        guard let zen, zenFreshness(at: now)?.isCurrent == true else { return nil }
        return zen
    }
}
