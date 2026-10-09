// Original to Sensor (no ported code).
// Why a feed document was rejected. A rejected document is never partially used (PROGRESS D57).

import Foundation

/// The reason `ForecastFeedDecoder` rejected a whole document. Field names are the feed's JSON
/// paths (e.g. `predictions.zen.30`), so a message points straight at the producer's key.
public enum ForecastDocumentError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The body is not a JSON object: invalid JSON (including Python's bare `NaN`/`Infinity`,
    /// which `json.dumps` writes by default), an array, a scalar, or empty.
    case notAJSONObject
    /// A key has the wrong JSON type (e.g. a string where a number belongs).
    case wrongType(field: String)
    /// A required key is missing or null. Only `as_of` is required.
    case missingField(String)
    /// A timestamp is not `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)` or names an impossible time.
    case unparseableTimestamp(field: String, text: String)
    /// A timestamp is later than the phone's clock plus `ForecastLimits.clockSkewTolerance`.
    case futureDated(field: String)
    /// A timestamp is later than the document's own `as_of` plus `ForecastLimits.clockSkewTolerance`.
    case laterThanAsOf(field: String)
    /// Values are present but the time they belong to is null (`predictions.zen` without
    /// `predictions.generated_at`, or `bg.mg_dl` without `bg.ts`).
    case valueWithoutTimestamp(field: String)
    /// A forecast value is not finite or is outside `ForecastLimits.plausibleZenMgdl` /
    /// `plausibleOrefMgdl`. A model output outside the range is a fault, not a forecast.
    case implausibleForecast(field: String, value: Double)
    /// `bg.mg_dl` is not finite or is outside `ForecastLimits.plausibleFeedGlucose`.
    case implausibleFeedGlucose(value: Double)
    /// A metrics value is not finite or is outside its documented range (see `ForecastLimits`).
    case implausibleMetric(field: String, value: Double)

    public var description: String {
        switch self {
        case .notAJSONObject:
            return "The feed did not return a JSON object."
        case .wrongType(let field):
            return "\(field) has the wrong type."
        case .missingField(let field):
            return "\(field) is missing."
        case .unparseableTimestamp(let field, let text):
            return "\(field) is not a valid timestamp: \(text)"
        case .futureDated(let field):
            return "\(field) is in the future (check the phone's clock)."
        case .laterThanAsOf(let field):
            return "\(field) is later than the document's as_of."
        case .valueWithoutTimestamp(let field):
            return "\(field) has values but no timestamp."
        case .implausibleForecast(let field, let value):
            return "\(field) = \(value) mg/dL is outside the plausible range."
        case .implausibleFeedGlucose(let value):
            return "bg.mg_dl = \(value) is outside the plausible range."
        case .implausibleMetric(let field, let value):
            return "\(field) = \(value) is outside the plausible range."
        }
    }
}
