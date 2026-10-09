// DEBUG only: Zen Predict feed documents (latest.json, metrics.json) with times relative to a given
// moment, in the shape zen-predict-infra's publish.py writes them (docs/forecast.md "The feed").
// Used by previews, screenshots, unit tests and the DEBUG fixture feed (`-forecastFixture`). Every
// document is validated by ForecastKit's decoder like the real feed; nothing here is a reading.
// All values are made up.

#if DEBUG
import ForecastKit
import Foundation

enum ForecastFixtureDocuments {
    /// Predicted mg/dL per horizon (minutes) for previews and screenshots: a dip, then a rise, from
    /// the mockup curve's 105 (`Fixtures.mockupCurve`).
    static let zen: [Int: Double] = [5: 103.8, 30: 98.2, 60: 104.6, 120: 121.3]
    /// Trio's oref forecast as the feed also publishes it. Deliberately different from `zen`, so a
    /// test or a screenshot shows at once if it were ever drawn (D57: oref is not shown in v1).
    static let oref: [Int: Double] = [5: 101, 30: 87, 60: 71.5, 120: 45]
    static let modelVersion = "20260901T000000-0example"
    /// 7-day mean absolute error per horizon and the run count. Synthetic.
    static let sevenDayMAE: [Int: Double] = [5: 5.2, 30: 16.3, 60: 23.4, 120: 30.6]
    static let sevenDayRuns = 2_016

    /// `2026-09-23T16:32:00Z` (FeedTimestamp accepts `Z`).
    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// latest.json. Null `generatedAt` with null `zen` is "no forecast yet".
    static func latest(asOf: Date, generatedAt: Date?, zen: [Int: Double]? = zen, oref: [Int: Double]? = oref,
                       feedGlucose: Int? = 105, modelVersion: String? = modelVersion) -> Data {
        let document: [String: Any] = [
            "as_of": timestamp(asOf),
            "bg": feedGlucose.map { ["ts": timestamp(generatedAt ?? asOf), "mg_dl": $0, "trend": "Flat"] as [String: Any] } ?? NSNull(),
            "predictions": [
                "generated_at": generatedAt.map(timestamp) ?? NSNull(),
                "zen": zen.map(horizons) ?? NSNull(),
                "oref": oref.map(horizons) ?? NSNull(),
            ] as [String: Any],
            "model_version": modelVersion ?? NSNull(),
        ]
        return json(document)
    }

    /// metrics.json with a 7-day and a 30-day window.
    static func metrics(asOf: Date, sevenDayMAE: [Int: Double] = sevenDayMAE, runs: Int = sevenDayRuns) -> Data {
        func window(mae: [Int: Double], runs: Int) -> [String: Any] {
            [
                "mae": horizons(mae),
                "persistence_mae": horizons(mae.mapValues { $0 * 1.2 }),
                "win_rate_vs_oref": horizons(mae.mapValues { _ in 0.58 }),
                "n": runs,
                "parkes_ab_pct": 97.45,
            ]
        }
        let document: [String: Any] = [
            "as_of": timestamp(asOf),
            "windows": [
                "7d": window(mae: sevenDayMAE, runs: runs),
                "30d": window(mae: sevenDayMAE.mapValues { $0 * 1.1 }, runs: runs * 4),
            ],
            "model_version": modelVersion,
        ]
        return json(document)
    }

    /// A fixture instant: the wall clock at `wall`, and a monotonic reading that agrees with it
    /// (seconds since 1970), so fixtures and tests can move both clocks together, or only the wall.
    static func instant(_ wall: Date) -> ForecastInstant {
        ForecastInstant(wall: wall, monotonic: wall.timeIntervalSince1970)
    }

    /// Decoded with ForecastKit's validation at `instant` (when it "arrived"), as the app decodes
    /// the real feed. Nil if the document is refused (a fixture bug; the tests that use fixtures
    /// fail on it).
    static func decodedLatest(asOf: Date, generatedAt: Date?, zen: [Int: Double]? = zen, oref: [Int: Double]? = oref,
                              feedGlucose: Int? = 105, at instant: ForecastInstant) -> LatestForecast? {
        try? ForecastFeedDecoder.decodeLatest(latest(asOf: asOf, generatedAt: generatedAt, zen: zen, oref: oref, feedGlucose: feedGlucose), at: instant)
    }

    static func decodedAccuracy(asOf: Date, sevenDayMAE: [Int: Double] = sevenDayMAE, at instant: ForecastInstant) -> ForecastAccuracy? {
        try? ForecastFeedDecoder.decodeAccuracy(metrics(asOf: asOf, sevenDayMAE: sevenDayMAE), at: instant)
    }

    /// `{"5": 103.8, "30": …}`: the feed's horizon keys are strings (publish.py `LATEST_HORIZONS`).
    private static func horizons(_ values: [Int: Double]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: values.map { (String($0.key), $0.value) })
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
#endif
