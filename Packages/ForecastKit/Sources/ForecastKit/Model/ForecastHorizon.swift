// Original to Sensor (no ported code).
// The four horizons Zen Predict publishes. Source: zen-predict-infra
// lambdas/handlers/publish.py `LATEST_HORIZONS = ("5", "30", "60", "120")`, used as the string keys
// of `predictions.zen`, `predictions.oref` and every per-horizon map in metrics.json.

import Foundation

/// How far ahead a forecast looks: minutes after the model run's `generatedAt`.
public enum ForecastHorizon: Int, CaseIterable, Sendable, Hashable, Comparable {
    case fiveMinutes = 5
    case thirtyMinutes = 30
    case oneHour = 60
    case twoHours = 120

    public var minutes: Int { rawValue }

    /// The horizon as a time interval (seconds).
    public var interval: TimeInterval { TimeInterval(rawValue) * 60 }

    /// The key the feed uses for this horizon: "5", "30", "60", "120".
    var feedKey: String { String(rawValue) }

    public static func < (lhs: ForecastHorizon, rhs: ForecastHorizon) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
