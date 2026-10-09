// What the Predict tab shows (PROGRESS D57; docs/forecast.md). Built by `PredictMapping` from the
// forecast service's in-memory status, the app's own stored readings and the UI clock, again on
// every UI clock tick, so a run goes "out of date" on time even while every fetch fails.
//
// A forecast is never a reading: no type here is a `GlucoseReading` or a `GlucoseValue`. The
// readings in `PredictChart.readings` are the app's own stored readings (S1/S4, as on Now); the
// forecast points are separate, labelled as predicted, and present only while the run is current
// (≤ 15 min old, `ForecastLimits.staleAfter`). Trio's oref forecast is not shown in v1: the feed
// publishes no time for it (S3).

import ForecastKit
import Foundation
import GlucoseCore
import WidgetCore

struct PredictViewState: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        /// No feed host (Settings › Predictions explains how to set one).
        case notConfigured
        /// A host is set and "Show predictions" is off.
        case turnedOff(host: String)
        /// On, nothing fetched yet (the first fetch is on its way, or the app has not been in the
        /// foreground yet). No numbers.
        case waiting(host: String)
        /// The current run: numbers, the freshness line and the forecast line.
        case forecast(PredictForecast)
        /// The run is more than 15 minutes old, or dated ahead of the phone's clock. No numbers, no line.
        case outOfDate(PredictMessage)
        /// The feed has no Zen run yet.
        case noRunYet(PredictMessage)
        /// Fetching fails and nothing is held. No numbers.
        case unavailable(PredictMessage)
    }

    var content: Content
    /// "COULDN'T REFRESH · RETRYING" while fetches fail and an earlier document is still held.
    var refreshNote: String?
    /// The readings chart (and the forecast line when current); nil when predictions are not set up
    /// or turned off.
    var chart: PredictChart?
    /// "Typical miss over the last 7 days …" from metrics.json; nil until fetched.
    var accuracyNote: String?
    /// "MODEL 20260901T000000-0example" (`model_version`).
    var modelVersion: String?
    /// Just after the shown run turns stale: the screen asks for a re-evaluation then, so the
    /// numbers never outlive the 15-minute rule by up to a tick.
    var redrawAt: Date?

    static let notConfigured = PredictViewState(content: .notConfigured)

    init(content: Content, refreshNote: String? = nil, chart: PredictChart? = nil, accuracyNote: String? = nil,
         modelVersion: String? = nil, redrawAt: Date? = nil) {
        self.content = content
        self.refreshNote = refreshNote
        self.chart = chart
        self.accuracyNote = accuracyNote
        self.modelVersion = modelVersion
        self.redrawAt = redrawAt
    }

    /// The forecast shown now, if any (tests and the screen).
    var forecast: PredictForecast? {
        if case .forecast(let forecast) = content { return forecast }
        return nil
    }
}

/// A title and a sentence (states without numbers).
struct PredictMessage: Equatable, Sendable {
    var title: String
    var detail: String
}

/// A current run, ready to draw.
struct PredictForecast: Equatable, Sendable {
    /// "MODEL RAN 12:32 PM · 3 MIN AGO · FROM 105 AT 12:32 PM": the run's time, its conservative age
    /// on the UI clock, and the stored reading at the run's time if there is one.
    var freshnessLine: String
    /// +30 MIN, +1 HR, +2 HR.
    var columns: [PredictColumn]
}

/// One horizon column.
struct PredictColumn: Equatable, Sendable, Identifiable {
    var horizon: ForecastHorizon
    /// "+30 MIN", "+1 HR", "+2 HR".
    var title: String
    /// "98", "≤40", "≥400", or "—" when the feed published nothing for this horizon.
    var value: String
    /// Colour band of the value (as on Now); nil when there is no value.
    var band: GlucoseBand?
    /// "predicted", or "not published".
    var caption: String
    /// "typical miss ±16" (7-day mean absolute error), nil when not published.
    var typicalMiss: String?
    /// VoiceOver: "Predicted 98 milligrams per deciliter in 30 minutes, typical miss 16".
    var spoken: String

    var id: Int { horizon.minutes }
}

/// The Predict chart: the last 3 hours of real readings, and the forecast while it is current.
struct PredictChart: Equatable, Sendable {
    /// Stored readings from the last 3 hours, any source, none after `now` (as the Now chart:
    /// `ChartSeries` breaks the line at gaps > 15 min and draws LOW/HIGH as edge markers, S1/S4).
    var readings: [ChartPoint]
    /// The dashed forecast line: the stored reading at the run's time (if numeric) then the
    /// predicted points. Empty unless the run is current.
    var forecast: [PredictChartPoint]
    var domain: ClosedRange<Date>
    /// Where the "now" rule is drawn.
    var now: Date
    /// "predicted · model run 12:32 PM" for the legend, nil without a forecast line.
    var forecastLegend: String?
    /// VoiceOver summary, saying which part is predicted.
    var accessibilityLabel: String
}

/// A point of the dashed forecast line. Not a reading (S1): never selectable as one, never drawn
/// in the readings' style.
struct PredictChartPoint: Equatable, Sendable, Hashable {
    var date: Date
    /// mg/dL as plotted: the predicted value (inside 40…400, the model's own clip; a value outside
    /// is drawn at the edge, and its column says "≤40"/"≥400"), or the starting reading's value.
    var mgdl: Double
    /// True for a predicted point (hollow marker); false for the stored reading the line starts at.
    var isPredicted: Bool
}

/// Settings › Predictions and its row on the Settings page.
struct PredictionsSettings: Equatable, Sendable {
    var setup: ForecastStatus.Setup
    /// The build's host (`ZEN_PREDICT_FEED_HOST`), nil when the build has none.
    var buildHost: String?
    var lastSuccessAt: Date?
    /// The last failure's sentence while fetches fail; nil once one succeeds.
    var lastError: String?

    static let notConfigured = PredictionsSettings(setup: .notConfigured, buildHost: nil, lastSuccessAt: nil, lastError: nil)

    /// The Settings row: "on · zen.example.com", "off", "not set up".
    var rowValue: String {
        switch setup {
        case .notConfigured: return "not set up"
        case .off: return "off"
        case .on(let host): return "on · \(host)"
        }
    }
}
