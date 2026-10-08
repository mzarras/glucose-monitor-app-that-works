// What the Predict tab and Settings › Predictions read from the forecast service (PROGRESS D57;
// docs/forecast.md). A plain value, held in memory only: nothing here is ever stored, and nothing
// that handles readings (pipeline, store, alerts, Trio, uploads, widget) reads it.
//
// A forecast is never a reading: `latest` and `accuracy` are ForecastKit types, which cannot be
// turned into a `GlucoseReading` (ForecastKit has no dependencies). Whether a run may be shown is
// decided at draw time on the UI clock (`PredictMapping`), never here.

import ForecastKit
import Foundation

struct ForecastStatus: Sendable, Equatable {
    /// Where predictions come from, and whether they are on.
    enum Setup: Sendable, Equatable {
        /// No feed host: the build has none (`ZEN_PREDICT_FEED_HOST` empty) and none was saved in
        /// Settings › Predictions.
        case notConfigured
        /// A feed host, with "Show predictions" turned off.
        case off(host: String)
        /// A feed host, with predictions on: fetched while the app is in the foreground.
        case on(host: String)

        var host: String? {
            switch self {
            case .notConfigured: return nil
            case .off(let host), .on(let host): return host
            }
        }

        var isOn: Bool {
            if case .on = self { return true }
            return false
        }
    }

    var setup: Setup
    /// The build's feed host (Info.plist `ZenPredictFeedHost`), validated; nil when the build has
    /// none (or an invalid one).
    var buildHost: String?
    /// The last latest.json validated by ForecastKit for the current host, nil before the first
    /// successful fetch. Kept while later fetches fail; cleared when the host changes or predictions
    /// are turned off. May be stale: ask `PredictFreshness` (ForecastKit's `zenFreshness(at:)`,
    /// `currentRun(at:)`) at draw time.
    var latest: LatestForecast?
    /// The last metrics.json validated for the current host (the "typical miss"), nil until fetched.
    var accuracy: ForecastAccuracy?
    /// When latest.json was last requested, and when a request last succeeded (a 304 is a success).
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    /// latest.json requests that failed since the last success (0 after a success).
    var consecutiveFailures: Int
    /// The last failure's sentence (`ForecastFeedError.description`), nil after a success.
    var lastError: String?
    /// A latest.json request is on its way.
    var isFetching: Bool

    init(setup: Setup, buildHost: String? = nil) {
        self.setup = setup
        self.buildHost = buildHost
        latest = nil
        accuracy = nil
        lastAttemptAt = nil
        lastSuccessAt = nil
        consecutiveFailures = 0
        lastError = nil
        isFetching = false
    }

    static let notConfigured = ForecastStatus(setup: .notConfigured)

    /// The last fetch failed and none has succeeded since.
    var isFailing: Bool { consecutiveFailures > 0 }
}

/// What the Predict tab and Settings › Predictions say about a failed fetch. Never a value from a
/// rejected document (D57: nothing from a rejected document is shown; a "700.0 mg/dL" would look
/// like glucose): a validation failure names only the field. The full text goes to the diagnostic
/// log (`ForecastService`).
enum ForecastErrorText {
    static func message(for error: ForecastFeedError) -> String {
        switch error {
        case .invalidDocument(let document):
            switch document {
            case .notAJSONObject:
                return "The forecast feed did not return a JSON document."
            case .futureDated(let field):
                return "The forecast feed failed validation (\(field) is in the future: check the phone's date and time)."
            case .wrongType(let field), .missingField(let field), .unparseableTimestamp(let field, _), .laterThanAsOf(let field),
                 .valueWithoutTimestamp(let field), .implausibleForecast(let field, _), .implausibleMetric(let field, _):
                return "The forecast feed failed validation (\(field))."
            case .implausibleFeedGlucose:
                return "The forecast feed failed validation (bg.mg_dl)."
            }
        case .transport, .httpStatus, .notModifiedWithoutCachedValue, .cancelled:
            return error.description
        }
    }
}

/// Why Settings › Predictions refused a feed host: ForecastKit's `ForecastEndpointError` sentence,
/// as an app type, so `AppServices` names no ForecastKit type (D57 import allowlist).
struct ForecastHostRefusal: Error, Sendable, Equatable {
    let message: String
}

/// Which host and switch apply, from the build's host and what Settings › Predictions saved.
/// Pure; unit-tested (PredictSettingsTests).
enum ForecastSetupRules {
    /// - Parameters:
    ///   - buildHost: Info.plist `ZenPredictFeedHost` as built (`$(ZEN_PREDICT_FEED_HOST)`; "" when the
    ///     build setting is empty).
    ///   - savedHost: the host saved in Settings › Predictions (`AppPreferences.forecastFeedHost`).
    ///   - savedEnabled: the "Show predictions" switch as saved; nil = never set, which means on
    ///     (D57: on by default once a host is configured).
    /// - Returns: the setup, and the build host if it is a valid host name.
    static func resolve(buildHost: String?, savedHost: String?, savedEnabled: Bool?) -> (setup: ForecastStatus.Setup, buildHost: String?) {
        let build = validHost(buildHost)
        guard let host = validHost(savedHost) ?? build else { return (.notConfigured, build) }
        return (savedEnabled ?? true ? .on(host: host) : .off(host: host), build)
    }

    /// The host if `text` is a valid feed host (`ForecastFeedEndpoint`), nil when empty or invalid.
    static func validHost(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try? ForecastFeedEndpoint(text).host
    }
}
