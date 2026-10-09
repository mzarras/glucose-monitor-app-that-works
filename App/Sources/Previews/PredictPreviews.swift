// SwiftUI previews for every Predict tab state and Settings › Predictions, light and dark
// (PROGRESS D57). DEBUG only: they use PredictFixtures (made-up values, decoded by ForecastKit).

#if DEBUG
import SwiftUI
import WidgetCore

/// Screen background, scrolling and a fixed colour scheme, with the tab bar under it.
private struct PredictPreview: View {
    let scenario: PredictFixtures.Scenario
    let scheme: ColorScheme
    private let now = Date()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                PredictContent(state: PredictFixtures.state(scenario, at: now), actions: .noop)
            }
            SensorTabBar(selected: .predict, attention: [], select: { _ in })
        }
        .editorialScreen()
        .environment(\.colorScheme, scheme)
        .preferredColorScheme(scheme)
    }
}

#Preview("Predict · current · light") { PredictPreview(scenario: .current, scheme: .light) }
#Preview("Predict · current · dark") { PredictPreview(scenario: .current, scheme: .dark) }
#Preview("Predict · current without reading · light") { PredictPreview(scenario: .currentWithoutReading, scheme: .light) }
#Preview("Predict · current without reading · dark") { PredictPreview(scenario: .currentWithoutReading, scheme: .dark) }
#Preview("Predict · clipped low · light") { PredictPreview(scenario: .clippedLow, scheme: .light) }
#Preview("Predict · clipped low · dark") { PredictPreview(scenario: .clippedLow, scheme: .dark) }
#Preview("Predict · clipped high · light") { PredictPreview(scenario: .clippedHigh, scheme: .light) }
#Preview("Predict · clipped high · dark") { PredictPreview(scenario: .clippedHigh, scheme: .dark) }
#Preview("Predict · stale · light") { PredictPreview(scenario: .stale, scheme: .light) }
#Preview("Predict · stale · dark") { PredictPreview(scenario: .stale, scheme: .dark) }
#Preview("Predict · ahead of clock · light") { PredictPreview(scenario: .aheadOfClock, scheme: .light) }
#Preview("Predict · ahead of clock · dark") { PredictPreview(scenario: .aheadOfClock, scheme: .dark) }
#Preview("Predict · no run yet · light") { PredictPreview(scenario: .noRunYet, scheme: .light) }
#Preview("Predict · no run yet · dark") { PredictPreview(scenario: .noRunYet, scheme: .dark) }
#Preview("Predict · waiting · light") { PredictPreview(scenario: .waiting, scheme: .light) }
#Preview("Predict · waiting · dark") { PredictPreview(scenario: .waiting, scheme: .dark) }
#Preview("Predict · failing, run held · light") { PredictPreview(scenario: .failingWithRun, scheme: .light) }
#Preview("Predict · failing, run held · dark") { PredictPreview(scenario: .failingWithRun, scheme: .dark) }
#Preview("Predict · failing, nothing held · light") { PredictPreview(scenario: .failingNothingHeld, scheme: .light) }
#Preview("Predict · failing, nothing held · dark") { PredictPreview(scenario: .failingNothingHeld, scheme: .dark) }
#Preview("Predict · not configured · light") { PredictPreview(scenario: .notConfigured, scheme: .light) }
#Preview("Predict · not configured · dark") { PredictPreview(scenario: .notConfigured, scheme: .dark) }
#Preview("Predict · turned off · light") { PredictPreview(scenario: .turnedOff, scheme: .light) }
#Preview("Predict · turned off · dark") { PredictPreview(scenario: .turnedOff, scheme: .dark) }

#Preview("Settings › Predictions · on · light") {
    NavigationStack {
        PredictionsSettingsView(predictions: PredictFixtures.settings(.current, at: Date()), setEnabled: { _ in }, saveHost: { _ in })
            .editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light)
    }
}
#Preview("Settings › Predictions · on · dark") {
    NavigationStack {
        PredictionsSettingsView(predictions: PredictFixtures.settings(.current, at: Date()), setEnabled: { _ in }, saveHost: { _ in })
            .editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark)
    }
}
#Preview("Settings › Predictions · failing, host refused · light") {
    NavigationStack {
        PredictionsSettingsView(predictions: PredictFixtures.settings(.failingWithRun, at: Date()), feedback: "Only https:// is supported.",
                                setEnabled: { _ in }, saveHost: { _ in })
            .editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light)
    }
}
#Preview("Settings › Predictions · not set up · dark") {
    NavigationStack {
        PredictionsSettingsView(predictions: PredictFixtures.settings(.notConfigured, at: Date()), setEnabled: { _ in }, saveHost: { _ in })
            .editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark)
    }
}
#endif
