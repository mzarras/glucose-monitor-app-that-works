// Original to Sensor (no ported code).
// Validates a feed document and turns it into ForecastKit's types. All or nothing: any rule below
// that fails rejects the whole document with a `ForecastDocumentError`, and nothing from it is used
// (PROGRESS D57: "a malformed or future-dated feed document is rejected whole").
//
// Rules (docs/forecast.md "Validation"):
//   1. The body is a JSON object; every known key has its JSON type (unknown keys are ignored).
//   2. `as_of` is present. Every timestamp present parses (FeedTimestamp), is no later than the
//      phone's clock + ForecastLimits.clockSkewTolerance, and (except `as_of`) no later than
//      as_of + tolerance.
//   3. Every non-null forecast value is finite and inside its plausible range (ForecastLimits).
//   4. Values need their time: Zen values without `generated_at`, or `bg.mg_dl` without `bg.ts`,
//      reject the document. A time without values is simply "nothing published".
//   5. Null means absent: a null horizon is no point; a null or all-null `zen` (or null
//      `generated_at` with no values) is "no forecast yet"; a null `oref` or `bg` is not shown.
//
// The document is stamped with the instant it was received (`ForecastInstant`, both clocks): the
// wall clock judges "future-dated", and both clocks later judge the run's age (ForecastFreshness).

import Foundation

public enum ForecastFeedDecoder {
    /// Validates latest.json received at `instant` (injected; the client passes
    /// `ForecastInstant.now()` when the response arrives) and stamps it with that instant.
    public static func decodeLatest(_ data: Data, at instant: ForecastInstant) throws(ForecastDocumentError) -> LatestForecast {
        let now = instant.wall
        let document = try decode(LatestDocument.self, from: data)
        guard let asOf = try timestamp(document.asOf, field: "as_of", now: now, asOf: nil) else {
            throw .missingField("as_of")
        }

        let predictions = document.predictions
        let generatedAt = try timestamp(predictions?.generatedAt, field: "predictions.generated_at", now: now, asOf: asOf)
        let zenPoints = try forecastPoints(predictions?.zen, field: "predictions.zen", plausible: ForecastLimits.plausibleZenMgdl)
        let orefPoints = try forecastPoints(predictions?.oref, field: "predictions.oref", plausible: ForecastLimits.plausibleOrefMgdl)

        var zen: ForecastRun?
        if !zenPoints.isEmpty {
            guard let generatedAt else { throw .valueWithoutTimestamp(field: "predictions.zen") }
            zen = ForecastRun(generatedAt: generatedAt, points: zenPoints)
        }

        return LatestForecast(
            asOf: asOf,
            zen: zen,
            oref: orefPoints.isEmpty ? nil : OrefForecast(points: orefPoints),
            feedGlucose: try feedGlucose(document.bg, now: now, asOf: asOf),
            modelVersion: document.modelVersion,
            receivedAt: instant
        )
    }

    /// Validates metrics.json received at `instant` (injected, as for `decodeLatest`) and stamps it
    /// with that instant.
    public static func decodeAccuracy(_ data: Data, at instant: ForecastInstant) throws(ForecastDocumentError) -> ForecastAccuracy {
        let now = instant.wall
        let document = try decode(MetricsDocument.self, from: data)
        guard let asOf = try timestamp(document.asOf, field: "as_of", now: now, asOf: nil) else {
            throw .missingField("as_of")
        }
        return ForecastAccuracy(
            asOf: asOf,
            modelVersion: document.modelVersion,
            sevenDays: try accuracyWindow(document.windows?.sevenDays, field: "windows.7d"),
            thirtyDays: try accuracyWindow(document.windows?.thirtyDays, field: "windows.30d"),
            receivedAt: instant
        )
    }

    // MARK: - Rule 1: JSON shape

    private static func decode<Document: Decodable>(_ type: Document.Type, from data: Data) throws(ForecastDocumentError) -> Document {
        // JSONSerialization first, so "not an object at all" is told apart from "a key has the wrong
        // type". Without `.fragmentsAllowed` or `.json5Allowed` it also refuses bare NaN/Infinity.
        guard let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else {
            throw .notAJSONObject
        }
        do {
            return try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw .wrongType(field: fieldPath(of: error))
        }
    }

    /// The JSON path a `DecodingError` points at, e.g. "predictions.zen.30", or "(document)" when
    /// it names none. (JSONDecoder reports a number it cannot represent, such as -1e400 or a
    /// fractional `n`, as corrupt data at the root even though JSONSerialization accepted it.)
    private static func fieldPath(of error: any Error) -> String {
        var path: [any CodingKey] = []
        switch error as? DecodingError {
        case .typeMismatch(_, let context), .valueNotFound(_, let context),
             .keyNotFound(_, let context), .dataCorrupted(let context):
            path = context.codingPath
        default:
            break
        }
        return path.isEmpty ? "(document)" : path.map(\.stringValue).joined(separator: ".")
    }

    // MARK: - Rule 2: timestamps

    /// Parses and checks a timestamp against the phone's clock `now`; nil when the feed published
    /// null. `asOf` nil = this is `as_of`.
    private static func timestamp(_ text: String?, field: String, now: Date, asOf: Date?) throws(ForecastDocumentError) -> Date? {
        guard let text else { return nil }
        guard let date = FeedTimestamp.parse(text) else {
            throw .unparseableTimestamp(field: field, text: text)
        }
        guard date <= now.addingTimeInterval(ForecastLimits.clockSkewTolerance) else {
            throw .futureDated(field: field)
        }
        if let asOf, date > asOf.addingTimeInterval(ForecastLimits.clockSkewTolerance) {
            throw .laterThanAsOf(field: field)
        }
        return date
    }

    // MARK: - Rules 3–5: values

    /// The non-null forecast values of a horizon map, each checked against `plausible`.
    private static func forecastPoints(_ map: HorizonValues?, field: String, plausible: ClosedRange<Double>) throws(ForecastDocumentError) -> [ForecastPoint] {
        guard let map else { return [] }
        var points: [ForecastPoint] = []
        for horizon in ForecastHorizon.allCases {
            guard let value = map.values[horizon] else { continue }
            guard value.isFinite, plausible.contains(value) else {
                throw .implausibleForecast(field: "\(field).\(horizon.feedKey)", value: value)
            }
            points.append(ForecastPoint(horizon: horizon, predictedMgdl: value))
        }
        return points
    }

    private static func feedGlucose(_ bg: BGDocument?, now: Date, asOf: Date) throws(ForecastDocumentError) -> FeedGlucose? {
        guard let bg else { return nil }
        let date = try timestamp(bg.ts, field: "bg.ts", now: now, asOf: asOf)
        guard let mgdl = bg.mgdl else { return nil }
        guard let date else { throw .valueWithoutTimestamp(field: "bg.mg_dl") }
        guard mgdl.isFinite, ForecastLimits.plausibleFeedGlucose.contains(mgdl) else {
            throw .implausibleFeedGlucose(value: mgdl)
        }
        return FeedGlucose(date: date, value: FeedGlucoseValue.classify(mgdl), trend: bg.trend)
    }

    private static func accuracyWindow(_ window: WindowDocument?, field: String) throws(ForecastDocumentError) -> AccuracyWindow? {
        guard let window else { return nil }
        let mae = try metricValues(window.mae, field: "\(field).mae", plausible: ForecastLimits.plausibleMeanAbsoluteErrorMgdl)
        let persistence = try metricValues(window.persistenceMae, field: "\(field).persistence_mae", plausible: ForecastLimits.plausibleMeanAbsoluteErrorMgdl)
        let winRate = try metricValues(window.winRateVsOref, field: "\(field).win_rate_vs_oref", plausible: ForecastLimits.plausibleWinRate)
        if let n = window.n, n < 0 {
            throw .implausibleMetric(field: "\(field).n", value: Double(n))
        }
        if let percent = window.parkesABPercent, !(percent.isFinite && ForecastLimits.plausiblePercent.contains(percent)) {
            throw .implausibleMetric(field: "\(field).parkes_ab_pct", value: percent)
        }
        return AccuracyWindow(
            sampleCount: window.n,
            parkesABPercent: window.parkesABPercent,
            meanAbsoluteErrors: mae,
            persistenceMeanAbsoluteErrors: persistence,
            winRatesVsOref: winRate
        )
    }

    private static func metricValues(_ map: HorizonValues?, field: String, plausible: ClosedRange<Double>) throws(ForecastDocumentError) -> [ForecastHorizon: Double] {
        guard let map else { return [:] }
        for horizon in ForecastHorizon.allCases {
            guard let value = map.values[horizon] else { continue }
            guard value.isFinite, plausible.contains(value) else {
                throw .implausibleMetric(field: "\(field).\(horizon.feedKey)", value: value)
            }
        }
        return map.values
    }
}
