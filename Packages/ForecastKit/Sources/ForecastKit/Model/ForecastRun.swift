// Original to Sensor (no ported code).
// Predicted values. A forecast is never a reading (PROGRESS D57): these types share no protocol or
// field names with GlucoseCore's `GlucoseReading`, and this package cannot import GlucoseCore.
// Values are created only by `ForecastFeedDecoder`, so every instance has passed its validation.

import Foundation

/// Where a predicted value sits relative to the Zen model's output clip.
///
/// zen-predict clips every prediction to 40…400 mg/dL (zen-predict @ 0d13ce3 zen_predict/model.py:34-35
/// `BG_FLOOR = 40.0`, `BG_CEIL = 400.0`; `_clip` at :54-55), so a value at an edge means "this low
/// or lower" / "this high or higher", not the number itself. The forecast analogue of S4: the
/// Predict tab shows these as "≤40" / "≥400" from this classification, never by comparing numbers.
public enum ForecastModelBound: Sendable, Equatable {
    /// ≤ 40 mg/dL: at (or, if the clip ever changed, below) the model's floor.
    case atOrBelowFloor
    /// Strictly between 40 and 400 mg/dL: a plain predicted number.
    case within
    /// ≥ 400 mg/dL: at (or above) the model's ceiling.
    case atOrAboveCeiling
}

/// One predicted glucose value at one horizon.
public struct ForecastPoint: Sendable, Equatable {
    public let horizon: ForecastHorizon
    /// Predicted glucose in mg/dL exactly as published (two decimals from the live feed; integers in
    /// the producer's sample fixtures). Not rounded here: rounding for display is the UI's job.
    /// Check `modelBound` first: at the clip edges the number is a bound, not a value.
    public let predictedMgdl: Double

    init(horizon: ForecastHorizon, predictedMgdl: Double) {
        self.horizon = horizon
        self.predictedMgdl = predictedMgdl
    }

    /// `.atOrBelowFloor` at ≤ 40 mg/dL, `.atOrAboveCeiling` at ≥ 400, otherwise `.within`
    /// (`ForecastLimits.zenModelClip`). Oref points use the same edges: oref clamps its curves to
    /// 39 at the bottom (Trio determine-basal.js:995) and anything ≥ 400 is beyond a CGM's range.
    public var modelBound: ForecastModelBound {
        if predictedMgdl <= ForecastLimits.zenModelClip.lowerBound { return .atOrBelowFloor }
        if predictedMgdl >= ForecastLimits.zenModelClip.upperBound { return .atOrAboveCeiling }
        return .within
    }
}

/// One Zen Predict model run: when it ran and what it predicted. The app obtains one only through
/// `LatestForecast.currentRun(at:)`, which returns it only while it is current; ask again when
/// drawing rather than keeping a run.
public struct ForecastRun: Sendable, Equatable {
    /// The run's time, which is the timestamp of the CGM reading the model ran on
    /// (`predictions.generated_at`; zen-predict-infra handlers/predict.py uses the newest reading's
    /// timestamp as `generated_at` and writes `target_time = generated_at + horizon`).
    public let generatedAt: Date
    /// The published (non-null) points, in ascending horizon order. Never empty: a run with no
    /// values is "no forecast yet" and is not a run at all.
    public let points: [ForecastPoint]

    init(generatedAt: Date, points: [ForecastPoint]) {
        self.generatedAt = generatedAt
        self.points = points.sorted { $0.horizon < $1.horizon }
    }

    /// The point at `horizon`, or nil if the feed published null for it.
    public func point(at horizon: ForecastHorizon) -> ForecastPoint? {
        points.first { $0.horizon == horizon }
    }

    /// The time a horizon's prediction is for: `generatedAt + horizon`.
    public func targetDate(for horizon: ForecastHorizon) -> Date {
        generatedAt.addingTimeInterval(horizon.interval)
    }
}

/// Trio's own oref forecast as published next to Zen Predict's, for comparison.
///
/// **It has no time.** publish.py `build_latest` picks oref's newest archived run by oref's own
/// `generated_at` (the Trio loop time, archived by the score Lambda from Nightscout devicestatus) but
/// publishes only the values, not that time. It is not the Zen run's `generated_at`, and it can be up
/// to the feed's 48 h window old (publish.py `HISTORY_WINDOW_HOURS`). So do not label these values
/// with the Zen run's time (S3: timestamps are derived, never assumed) and do not present them as
/// current. Each value is the median of Trio's predBG scenario curves at that horizon
/// (zen-predict zen_predict/oref_points.py `median_curve`). Not shown in v1 (PROGRESS D58).
public struct OrefForecast: Sendable, Equatable {
    /// The published (non-null) points, in ascending horizon order. Never empty.
    public let points: [ForecastPoint]

    init(points: [ForecastPoint]) {
        self.points = points.sorted { $0.horizon < $1.horizon }
    }

    /// The point at `horizon`, or nil if the feed published null for it.
    public func point(at horizon: ForecastHorizon) -> ForecastPoint? {
        points.first { $0.horizon == horizon }
    }
}
