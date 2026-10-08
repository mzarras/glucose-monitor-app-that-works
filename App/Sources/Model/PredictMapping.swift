// Forecast status + stored readings + the UI clock → what the Predict tab shows (PROGRESS D57).
// Pure: no clock of its own, no I/O; unit-tested in PredictMappingTests. `AppModel` calls it after
// every `.forecast` change, every readings reload and every UI clock tick.
//
// Rules (docs/forecast.md "What the app must never do with a forecast"):
// - Numbers and the forecast line only while the run is current at the UI instant
//   (`PredictFreshness`: ≤ 15 min old by the wall and the monotonic clock, not ahead of the phone's
//   clock). Otherwise a message.
// - Always labelled as predicted, with the model run's time.
// - Never oref (no published time, S3), never the feed's `bg` as a reading.
// - The chart's readings are the app's own stored readings, as on Now (S1, S4).

import ForecastKit
import Foundation
import GlucoseCore
import WidgetCore

enum PredictMapping {
    /// The chart shows this much of the past (the brief's "last 3 h").
    static let chartHistory: TimeInterval = 3 * 3_600
    /// How far from the run's time a stored live reading may be to count as the one the model ran
    /// on: half the G7's 5-minute cadence (the same tolerance as `ChartScrub.snapTolerance`).
    static let baseReadingTolerance: TimeInterval = 150
    /// The three columns; +5 min is drawn on the chart only.
    static let columnHorizons: [ForecastHorizon] = [.thirtyMinutes, .oneHour, .twoHours]
    /// Space on the chart after the +2 h point (one CGM interval), so its marker isn't cut in half.
    static let chartEndMargin: TimeInterval = 5 * 60
    /// The model clips every output to 40…400 mg/dL (zen-predict @ 0d13ce3 zen_predict/model.py:34-35,
    /// `BG_FLOOR`/`BG_CEIL`). A value at (or past) an edge reads "≤40"/"≥400", never a bare 40/400
    /// that looks like a sensor value.
    static let modelClip: ClosedRange<Int> = 40...400

    static let headerLabel = "ZEN PREDICT · YOUR MODEL"
    static let disclaimer = "A forecast from your Zen Predict model, not a reading. Never used for alerts, Trio or sharing."
    static let refreshNote = "COULDN'T REFRESH · RETRYING"

    // MARK: - The tab

    /// - Parameters:
    ///   - readings: stored readings around the last 3 hours (any source; `chartReadings`).
    ///   - instant: the UI clock (`AppModel.forecastClock`). Every freshness question goes through
    ///     `PredictFreshness` at this one instant.
    static func make(status: ForecastStatus, readings: [GlucoseReading], at instant: ForecastInstant,
                     context: DisplayContext = .current) -> PredictViewState {
        let host: String
        switch status.setup {
        case .notConfigured: return .notConfigured
        case .off(let offHost): return PredictViewState(content: .turnedOff(host: offHost))
        case .on(let onHost): host = onHost
        }

        let now = instant.wall
        let accuracyNote = status.accuracy.flatMap { accuracyText($0, context: context) }
        let modelVersion = (status.latest?.modelVersion ?? status.accuracy?.modelVersion).map { "MODEL \($0)" }
        let refreshNote = status.isFailing && status.latest != nil ? Self.refreshNote : nil
        var state = PredictViewState(content: .waiting(host: host), refreshNote: refreshNote,
                                     chart: chart(readings: readings, run: nil, base: nil, now: now, context: context),
                                     accuracyNote: accuracyNote, modelVersion: modelVersion)

        guard let latest = status.latest else {
            if status.isFailing {
                state.content = .unavailable(PredictMessage(title: "Forecast unavailable",
                                                            detail: "\(status.lastError ?? "The forecast feed could not be read.") Retrying."))
            }
            return state
        }
        guard let freshness = PredictFreshness.freshness(latest, at: instant), let runTime = PredictFreshness.runTime(latest) else {
            state.content = .noRunYet(PredictMessage(
                title: "No forecast yet",
                detail: "The feed has no Zen Predict run yet. The model runs on readings that reach Nightscout."))
            return state
        }
        switch freshness {
        case .current:
            // `currentRun(at:)` is the only source of points; it agrees with `freshness` at the same
            // instant, and if it ever did not, nothing is shown.
            guard let run = PredictFreshness.currentRun(latest, at: instant) else {
                state.content = .outOfDate(staleMessage(runTime: runTime, age: PredictFreshness.runAge(latest, at: instant) ?? 0, context: context))
                return state
            }
            let base = baseReading(at: run.generatedAt, in: readings)
            state.content = .forecast(PredictForecast(
                freshnessLine: freshnessLine(runTime: run.generatedAt, age: PredictFreshness.runAge(latest, at: instant) ?? 0, base: base, context: context),
                columns: columnHorizons.map { column($0, run: run, accuracy: status.accuracy) }
            ))
            state.chart = chart(readings: readings, run: run, base: base, now: now, context: context)
            state.redrawAt = PredictFreshness.redrawDate(latest, at: instant)
        case .stale:
            state.content = .outOfDate(staleMessage(runTime: runTime, age: PredictFreshness.runAge(latest, at: instant) ?? 0, context: context))
        case .aheadOfClock(let ahead):
            let minutes = max(1, Int((ahead / 60).rounded(.up)))
            state.content = .outOfDate(PredictMessage(
                title: "Forecast out of date",
                detail: "The last model run is dated \(TimeText.minutesPhrase(minutes)) ahead of this phone's clock, so it can't be shown. "
                    + "Check the phone's date and time."))
        }
        return state
    }

    /// "Last model run 32 min ago, at 12:03 PM. Zen Predict runs on readings that reach Nightscout; …"
    static func staleMessage(runTime: Date, age: TimeInterval, context: DisplayContext) -> PredictMessage {
        PredictMessage(
            title: "Forecast out of date",
            detail: "Last model run \(AgeText.long(minutes: Int(age / 60))), at \(TimeText.time(runTime, context)). "
                + "Zen Predict runs on readings that reach Nightscout; a new forecast appears after the next one does.")
    }

    // MARK: - Columns

    static func column(_ horizon: ForecastHorizon, run: ForecastRun, accuracy: ForecastAccuracy?) -> PredictColumn {
        let title = horizonTitle(horizon)
        guard let point = run.point(at: horizon) else {
            return PredictColumn(horizon: horizon, title: title, value: "—", band: nil, caption: "not published", typicalMiss: nil,
                                 spoken: "No prediction published for \(horizonSpoken(horizon))")
        }
        let miss = accuracy?.typicalMiss(at: horizon).map { Int($0.rounded()) }
        let edge = clipEdge(point.predictedMgdl, bound: point.modelBound)
        var spoken = "Predicted \(spokenValue(point.predictedMgdl, edge: edge)) \(inHorizonSpoken(horizon))"
        if let miss { spoken += ", typical miss \(miss)" }
        return PredictColumn(horizon: horizon, title: title, value: valueText(point.predictedMgdl, edge: edge), band: band(point.predictedMgdl, edge: edge),
                             caption: "predicted", typicalMiss: miss.map { "typical miss ±\($0)" }, spoken: spoken)
    }

    /// Which clip edge a predicted value shows as, if any: ForecastKit's `modelBound` (≤ 40 / ≥ 400
    /// as published), and also a value that rounds to 40 or 400, so a bare "40"/"400" that looks
    /// like a sensor value is never shown.
    static func clipEdge(_ mgdl: Double, bound: ForecastModelBound) -> ForecastModelBound {
        if bound != .within { return bound }
        let rounded = Int(mgdl.rounded())
        if rounded <= modelClip.lowerBound { return .atOrBelowFloor }
        if rounded >= modelClip.upperBound { return .atOrAboveCeiling }
        return .within
    }

    /// "98"; "≤40" / "≥400" at the model's clip edges.
    static func valueText(_ mgdl: Double, edge: ForecastModelBound) -> String {
        switch edge {
        case .atOrBelowFloor: return "≤\(modelClip.lowerBound)"
        case .atOrAboveCeiling: return "≥\(modelClip.upperBound)"
        case .within: return String(Int(mgdl.rounded()))
        }
    }

    static func spokenValue(_ mgdl: Double, edge: ForecastModelBound) -> String {
        switch edge {
        case .atOrBelowFloor: return "\(modelClip.lowerBound) or below"
        case .atOrAboveCeiling: return "\(modelClip.upperBound) or above"
        case .within: return "\(Int(mgdl.rounded())) milligrams per deciliter"
        }
    }

    /// The consensus band, for the colour (as on Now): very low / very high at the clip edges.
    static func band(_ mgdl: Double, edge: ForecastModelBound) -> GlucoseBand {
        switch edge {
        case .atOrBelowFloor: return .veryLow
        case .atOrAboveCeiling: return .veryHigh
        case .within: return GlucoseBand(mgdl: Int(mgdl.rounded()))
        }
    }

    static func horizonTitle(_ horizon: ForecastHorizon) -> String {
        switch horizon {
        case .fiveMinutes: return "+5 MIN"
        case .thirtyMinutes: return "+30 MIN"
        case .oneHour: return "+1 HR"
        case .twoHours: return "+2 HR"
        }
    }

    static func horizonSpoken(_ horizon: ForecastHorizon) -> String {
        switch horizon {
        case .fiveMinutes: return "5 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .twoHours: return "2 hours"
        }
    }

    static func inHorizonSpoken(_ horizon: ForecastHorizon) -> String {
        "in \(horizonSpoken(horizon))"
    }

    // MARK: - Freshness line

    /// The app's own stored live reading the model ran on: the live reading closest to the run's
    /// time, within `baseReadingTolerance`. Imported history never counts (S6); the feed's `bg` is
    /// never used as a reading.
    static func baseReading(at generatedAt: Date, in readings: [GlucoseReading]) -> GlucoseReading? {
        readings
            .filter { NowMapping.isLive($0.source) && abs($0.date.timeIntervalSince(generatedAt)) <= baseReadingTolerance }
            .min { abs($0.date.timeIntervalSince(generatedAt)) < abs($1.date.timeIntervalSince(generatedAt)) }
    }

    /// "MODEL RAN 3 MIN AGO · FROM 105 AT 12:32 PM", or "… · FROM YOUR 12:32 PM READING" when this
    /// phone has no stored reading at that time.
    static func freshnessLine(runTime: Date, age: TimeInterval, base: GlucoseReading?, context: DisplayContext) -> String {
        let ran = "MODEL RAN \(AgeText.upper(minutes: Int(age / 60)))"
        let time = TimeText.time(runTime, context).uppercased()
        guard let base else { return "\(ran) · FROM YOUR \(time) READING" }
        return "\(ran) · FROM \(GlucoseText.value(base.value)) AT \(TimeText.time(base.date, context).uppercased())"
    }

    // MARK: - Chart

    /// What AppModel keeps for the chart: stored readings from the last 3 hours (plus the gate's
    /// future tolerance), any source, ascending.
    static func chartReadings(_ readings: [GlucoseReading], now: Date) -> [GlucoseReading] {
        let start = now.addingTimeInterval(-chartHistory)
        let end = now.addingTimeInterval(LiveReadingGate.futureTolerance)
        return readings.filter { $0.date >= start && $0.date <= end }.sorted { $0.date < $1.date }
    }

    /// Readings from `now − 3 h` to `now` (none after `now`, as on Now). With a current `run`: the
    /// forecast line from the stored reading at the run's time (if numeric; a LOW/HIGH flag has no
    /// number to start from, S4) through the predicted points, and the x axis to the run's +2 h.
    static func chart(readings: [GlucoseReading], run: ForecastRun?, base: GlucoseReading?, now: Date, context: DisplayContext) -> PredictChart {
        let start = now.addingTimeInterval(-chartHistory)
        let points = readings
            .filter { $0.date >= start && $0.date <= now }
            .sorted { $0.date < $1.date }
            .map(ChartPoint.init)
        let summary = ChartSummary.text(title: "Last 3 hours", points: points)
        guard let run else {
            return PredictChart(readings: points, forecast: [], domain: start...now, now: now, forecastLegend: nil,
                                accessibilityLabel: summary + " No forecast shown.")
        }
        var line: [PredictChartPoint] = []
        if let base, let mgdl = base.value.numericMgdl {
            line.append(PredictChartPoint(date: base.date, mgdl: Double(mgdl), isPredicted: false))
        }
        for point in run.points {
            let plotted = min(max(point.predictedMgdl, Double(modelClip.lowerBound)), Double(modelClip.upperBound))
            line.append(PredictChartPoint(date: run.targetDate(for: point.horizon), mgdl: plotted, isPredicted: true))
        }
        // A little room after +2 h so its marker is drawn whole.
        let end = max(now, run.targetDate(for: .twoHours)).addingTimeInterval(chartEndMargin)
        let runTime = TimeText.time(run.generatedAt, context)
        let spokenPoints = columnHorizons.compactMap { horizon in
            run.point(at: horizon).map { "\(spokenNumber($0)) \(inHorizonSpoken(horizon))" }
        }
        let forecastSummary = "Dashed line: predicted by your Zen Predict model from the \(runTime) run"
            + (spokenPoints.isEmpty ? "." : ": " + spokenPoints.joined(separator: ", ") + ".")
            + " The predicted part is not readings."
        return PredictChart(readings: points, forecast: line, domain: start...end, now: now,
                            forecastLegend: "predicted · model run \(runTime)", accessibilityLabel: summary + " " + forecastSummary)
    }

    /// "98", "40 or below", "400 or above" (chart summary).
    private static func spokenNumber(_ point: ForecastPoint) -> String {
        switch clipEdge(point.predictedMgdl, bound: point.modelBound) {
        case .atOrBelowFloor: return "\(modelClip.lowerBound) or below"
        case .atOrAboveCeiling: return "\(modelClip.upperBound) or above"
        case .within: return String(Int(point.predictedMgdl.rounded()))
        }
    }

    // MARK: - Accuracy

    /// "Typical miss over the last 7 days (mean absolute error, 1,991 model runs): ±16 at 30 min,
    /// ±23 at 1 hr, ±29 at 2 hr." Nil when no 7-day error is published.
    static func accuracyText(_ accuracy: ForecastAccuracy, context: DisplayContext) -> String? {
        let parts = columnHorizons.compactMap { horizon in
            accuracy.typicalMiss(at: horizon).map { "±\(Int($0.rounded())) at \(horizonTitle(horizon).dropFirst().lowercased())" }
        }
        guard !parts.isEmpty else { return nil }
        let runs = accuracy.sevenDays?.sampleCount.map { ", \($0.formatted(.number.locale(context.locale))) model runs" } ?? ""
        return "Typical miss over the last 7 days (mean absolute error\(runs)): \(parts.joined(separator: ", "))."
    }

    // MARK: - Settings › Predictions

    static func settings(_ status: ForecastStatus) -> PredictionsSettings {
        PredictionsSettings(setup: status.setup, buildHost: status.buildHost, lastSuccessAt: status.lastSuccessAt,
                            lastError: status.isFailing ? status.lastError : nil)
    }

    /// "Last updated 2 min ago", "Last updated just now", "Not updated yet".
    static func lastUpdatedText(_ lastSuccessAt: Date?, now: Date) -> String {
        guard let lastSuccessAt else { return "Not updated yet" }
        return "Last updated \(AgeText.long(minutes: AgeText.wholeMinutes(from: lastSuccessAt, to: now)))"
    }
}
