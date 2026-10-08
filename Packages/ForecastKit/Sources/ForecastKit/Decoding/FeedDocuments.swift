// Original to Sensor (no ported code).
// The feed documents exactly as published, before validation. Every key is optional because
// publish.py `filter_doc` writes absent values as null; a key that is missing altogether is treated
// the same way. Keys not listed here are ignored (forward compatible). A key with the wrong JSON
// type fails decoding and rejects the document.
//
// Contracts: zen-predict-infra lambdas/handlers/publish.py `LATEST_CONTRACT`, `METRICS_CONTRACT`,
// `_WINDOW_CONTRACT`, `_HORIZON_MAP` (keys "5", "30", "60", "120").

import Foundation

/// latest.json as published.
struct LatestDocument: Decodable {
    let asOf: String?
    let bg: BGDocument?
    let predictions: PredictionsDocument?
    let modelVersion: String?

    enum CodingKeys: String, CodingKey {
        case asOf = "as_of"
        case bg
        case predictions
        case modelVersion = "model_version"
    }
}

/// `bg`: the newest Nightscout reading at publish time (publish.py `_current_bg`).
struct BGDocument: Decodable {
    let ts: String?
    let mgdl: Double?
    let trend: String?

    enum CodingKeys: String, CodingKey {
        case ts
        case mgdl = "mg_dl"
        case trend
    }
}

/// `predictions`: the newest Zen run's time and values, and oref's newest values.
struct PredictionsDocument: Decodable {
    let generatedAt: String?
    let zen: HorizonValues?
    let oref: HorizonValues?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case zen
        case oref
    }
}

/// A `{"5": …, "30": …, "60": …, "120": …}` map. Null or missing horizons are left out; other keys
/// (a future horizon) are ignored.
struct HorizonValues: Decodable {
    let values: [ForecastHorizon: Double]

    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var values: [ForecastHorizon: Double] = [:]
        for horizon in ForecastHorizon.allCases {
            if let value = try container.decodeIfPresent(Double.self, forKey: Key(stringValue: horizon.feedKey)) {
                values[horizon] = value
            }
        }
        self.values = values
    }
}

/// metrics.json as published.
struct MetricsDocument: Decodable {
    let asOf: String?
    let windows: WindowsDocument?
    let modelVersion: String?

    enum CodingKeys: String, CodingKey {
        case asOf = "as_of"
        case windows
        case modelVersion = "model_version"
    }
}

/// `windows`: publish.py `METRICS_WINDOWS = {"7d": 7, "30d": 30}`.
struct WindowsDocument: Decodable {
    let sevenDays: WindowDocument?
    let thirtyDays: WindowDocument?

    enum CodingKeys: String, CodingKey {
        case sevenDays = "7d"
        case thirtyDays = "30d"
    }
}

/// One window (publish.py `_WINDOW_CONTRACT`, values from `_window_stats`).
struct WindowDocument: Decodable {
    let mae: HorizonValues?
    let persistenceMae: HorizonValues?
    let winRateVsOref: HorizonValues?
    let n: Int?
    let parkesABPercent: Double?

    enum CodingKeys: String, CodingKey {
        case mae
        case persistenceMae = "persistence_mae"
        case winRateVsOref = "win_rate_vs_oref"
        case n
        case parkesABPercent = "parkes_ab_pct"
    }
}
