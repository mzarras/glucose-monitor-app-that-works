// Original to Sensor (no ported code).
// metrics.json, validated. Contract: zen-predict-infra lambdas/handlers/publish.py
// `METRICS_CONTRACT` / `_WINDOW_CONTRACT`, built by `build_metrics` and `_window_stats` from the
// daily rollups of scored Zen predictions (all Zen model versions in the window, weighted by n).

import Foundation

/// The published accuracy of Zen Predict, stamped with the instant it arrived.
public struct ForecastAccuracy: Sendable, Equatable {
    /// When the publish Lambda wrote the document (`as_of`).
    public let asOf: Date
    /// `model_version` of the newest Zen run at publish time. The windows aggregate every Zen model
    /// version scored in them, not only this one (publish.py `_window_stats`).
    public let modelVersion: String?
    /// The last 7 days (`windows["7d"]`), or nil if not published.
    public let sevenDays: AccuracyWindow?
    /// The last 30 days (`windows["30d"]`), or nil if not published.
    public let thirtyDays: AccuracyWindow?
    /// When the document arrived (both clocks), like `LatestForecast`'s. Accuracy is not judged by
    /// age (it aggregates days); the stamp keeps the two documents alike.
    let receivedAt: ForecastInstant

    init(asOf: Date, modelVersion: String?, sevenDays: AccuracyWindow?, thirtyDays: AccuracyWindow?, receivedAt: ForecastInstant) {
        self.asOf = asOf
        self.modelVersion = modelVersion
        self.sevenDays = sevenDays
        self.thirtyDays = thirtyDays
        self.receivedAt = receivedAt
    }

    /// The "typical miss" the Predict tab shows next to a forecast (D57): the 7-day mean absolute
    /// error at `horizon` in mg/dL, or nil if not published. The deployed model publishes point
    /// forecasts only, so this is the only uncertainty the app can show.
    public func typicalMiss(at horizon: ForecastHorizon) -> Double? {
        sevenDays?.accuracy(at: horizon).meanAbsoluteError
    }
}

/// Accuracy over one window (7 or 30 days).
public struct AccuracyWindow: Sendable, Equatable {
    /// Number of scored model runs (gridpoints) in the window (`n`); publish.py uses the largest
    /// single-horizon count. Nil if null.
    public let sampleCount: Int?
    /// Percentage of predictions in Parkes error grid zones A+B (`parkes_ab_pct`), 0…100. Nil if null.
    public let parkesABPercent: Double?
    private let meanAbsoluteErrors: [ForecastHorizon: Double]
    private let persistenceMeanAbsoluteErrors: [ForecastHorizon: Double]
    private let winRatesVsOref: [ForecastHorizon: Double]

    init(
        sampleCount: Int?,
        parkesABPercent: Double?,
        meanAbsoluteErrors: [ForecastHorizon: Double],
        persistenceMeanAbsoluteErrors: [ForecastHorizon: Double],
        winRatesVsOref: [ForecastHorizon: Double]
    ) {
        self.sampleCount = sampleCount
        self.parkesABPercent = parkesABPercent
        self.meanAbsoluteErrors = meanAbsoluteErrors
        self.persistenceMeanAbsoluteErrors = persistenceMeanAbsoluteErrors
        self.winRatesVsOref = winRatesVsOref
    }

    /// Accuracy at `horizon`; a field is nil where the feed published null.
    public func accuracy(at horizon: ForecastHorizon) -> HorizonAccuracy {
        HorizonAccuracy(
            meanAbsoluteError: meanAbsoluteErrors[horizon],
            persistenceMeanAbsoluteError: persistenceMeanAbsoluteErrors[horizon],
            winRateVsOref: winRatesVsOref[horizon]
        )
    }
}

/// Accuracy at one horizon within one window. Each field is nil when the feed published null.
public struct HorizonAccuracy: Sendable, Equatable {
    /// Mean absolute error of Zen Predict, mg/dL (`mae`).
    public let meanAbsoluteError: Double?
    /// Mean absolute error of "no change from the current value" (persistence), mg/dL
    /// (`persistence_mae`): the baseline a useful model must beat.
    public let persistenceMeanAbsoluteError: Double?
    /// Fraction of paired runs where Zen's error was smaller than oref's, 0…1 (`win_rate_vs_oref`).
    public let winRateVsOref: Double?

    init(meanAbsoluteError: Double?, persistenceMeanAbsoluteError: Double?, winRateVsOref: Double?) {
        self.meanAbsoluteError = meanAbsoluteError
        self.persistenceMeanAbsoluteError = persistenceMeanAbsoluteError
        self.winRateVsOref = winRateVsOref
    }
}
