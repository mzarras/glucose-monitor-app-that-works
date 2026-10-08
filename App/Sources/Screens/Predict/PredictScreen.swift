// Predict tab (PROGRESS D56, D57; docs/forecast.md): forecasts from Michael's Zen Predict model.
// Layout top to bottom: header, the run's freshness line, three horizon columns (+30 MIN, +1 HR,
// +2 HR), the chart (last 3 h of readings and the dashed forecast), accuracy, disclaimer.
//
// A forecast is never a reading (D57): it is drawn only here, always labelled "predicted" with the
// model run's time, and only while the run is current. `PredictViewState` is rebuilt on the UI clock
// (RootView's 15 s tick → `AppModel.tick()`); this screen also asks for a rebuild exactly when the
// shown run turns stale (`redrawAt`), so the numbers never outlive the 15-minute rule.

import ForecastKit
import GlucoseCore
import SwiftUI
import WidgetCore

struct PredictActions {
    /// Settings › Predictions ("Set up in Settings").
    var openSettings: @MainActor () -> Void
    /// The tab appeared (fetch at once if the last attempt is > 30 s old).
    var appeared: @MainActor () -> Void
    /// Re-evaluate on the clock now (`AppModel.tick()`).
    var refresh: @MainActor () -> Void

    static var noop: PredictActions {
        PredictActions(openSettings: {}, appeared: {}, refresh: {})
    }
}

struct PredictScreen: View {
    let state: PredictViewState
    let actions: PredictActions

    var body: some View {
        ScrollView {
            PredictContent(state: state, actions: actions)
        }
        .editorialScreen()
        .onAppear { actions.appeared() }
        // Re-evaluate just after the shown run turns stale; RootView's 15 s tick covers the rest.
        .task(id: state.redrawAt) {
            guard let redrawAt = state.redrawAt else { return }
            let delay = redrawAt.timeIntervalSinceNow
            if delay > 0 {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
            actions.refresh()
        }
    }
}

struct PredictContent: View {
    let state: PredictViewState
    let actions: PredictActions

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            header
            content
            if let chart = state.chart {
                PredictChartSection(chart: chart)
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Layout.sideMargin)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "Predict")
                .font(Typography.title(size: 36))
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: PredictMapping.headerLabel)
                .monoLabel(size: 11)
                .foregroundStyle(Theme.muted)
            Hairline().padding(.top, 6)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch state.content {
        case .notConfigured:
            PredictMessageView(message: PredictMessage(
                title: "Predictions aren't set up",
                detail: "This tab shows forecasts from your Zen Predict model. Add its feed host in Settings › Predictions."),
                emphasis: .calm)
            setUpButton
        case .turnedOff(let host):
            PredictMessageView(message: PredictMessage(
                title: "Predictions are off",
                detail: "Forecasts from your Zen Predict model (\(host)) are turned off. Turn them on in Settings › Predictions."),
                emphasis: .calm)
            setUpButton
        case .waiting(let host):
            HStack(spacing: 10) {
                ProgressView().accessibilityHidden(true)
                Text(verbatim: "Getting the latest forecast from \(host)…")
                    .font(Typography.body(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("predict.waiting")
        case .forecast(let forecast):
            forecastView(forecast)
        case .outOfDate(let message):
            PredictMessageView(message: message, emphasis: .warning)
            refreshNoteView
        case .noRunYet(let message):
            PredictMessageView(message: message, emphasis: .calm)
            refreshNoteView
        case .unavailable(let message):
            PredictMessageView(message: message, emphasis: .warning)
        }
    }

    private var setUpButton: some View {
        Button("Set up in Settings", action: actions.openSettings)
            .buttonStyle(SecondaryButtonStyle())
            .frame(maxWidth: 240)
            .accessibilityIdentifier("predict.setUp")
    }

    @ViewBuilder
    private var refreshNoteView: some View {
        if let note = state.refreshNote {
            Text(verbatim: note)
                .monoLabel(size: 10)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("predict.refreshNote")
        }
    }

    private func forecastView(_ forecast: PredictForecast) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: forecast.freshnessLine)
                    .monoLabel(size: 11)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("predict.freshness")
                refreshNoteView
            }
            PredictColumnsView(columns: forecast.columns)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Hairline()
            if let accuracy = state.accuracyNote {
                Text(verbatim: accuracy)
                    .font(Typography.body(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("predict.accuracy")
            }
            if let version = state.modelVersion {
                Text(verbatim: version)
                    .monoLabel(size: 10)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: PredictMapping.disclaimer)
                .font(Typography.body(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("predict.disclaimer")
        }
    }
}

// MARK: - Messages

/// A title and a sentence with a bar on the left: the alert colour when a forecast exists but can't
/// be shown (out of date, unavailable), muted otherwise.
struct PredictMessageView: View {
    enum Emphasis { case calm, warning }

    let message: PredictMessage
    let emphasis: Emphasis

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: message.title)
                .font(Typography.title(size: 26))
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: message.detail)
                .font(Typography.body(size: 14))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(emphasis == .warning ? AnyShapeStyle(Theme.alert) : AnyShapeStyle(Theme.muted))
                .frame(width: 3)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("predict.message")
    }
}

// MARK: - Columns

/// +30 MIN · +1 HR · +2 HR side by side; one per row at accessibility text sizes.
struct PredictColumnsView: View {
    let columns: [PredictColumn]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Clearly smaller than Now's 132 pt hero: a forecast is never the current value.
    static let valueSize: CGFloat = 46
    /// One column per row at accessibility text sizes: room for larger (still fixed-size) numbers.
    static let accessibilityValueSize: CGFloat = 64

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(columns) { column($0).frame(maxWidth: .infinity, alignment: .leading) }
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                ForEach(columns) { column($0).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
    }

    private func column(_ column: PredictColumn) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: column.title)
                .monoLabel(size: 11, medium: true)
                .foregroundStyle(Theme.muted)
            Text(verbatim: column.value)
                .font(Typography.statHero(size: dynamicTypeSize.isAccessibilitySize ? Self.accessibilityValueSize : Self.valueSize))
                .foregroundStyle(valueStyle(column.band))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 2)
                .padding(.bottom, -4)
            Text(verbatim: column.caption)
                .monoLabel(size: 10)
                .foregroundStyle(Theme.muted)
            if let miss = column.typicalMiss {
                Text(verbatim: miss)
                    .font(Typography.body(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: column.spoken))
        .accessibilityIdentifier("predict.column.\(column.horizon.minutes)")
    }

    /// Ink in range, the band colour otherwise (as Now's hero, `WidgetStyle.heroStyle`).
    private func valueStyle(_ band: GlucoseBand?) -> AnyShapeStyle {
        guard let band else { return AnyShapeStyle(Theme.muted) }
        return band == .inRange ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.band(band))
    }
}
