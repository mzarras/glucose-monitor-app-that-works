// Settings › Predictions (PROGRESS D57): the Zen Predict feed host and "Show predictions". The host
// is validated with ForecastKit's `ForecastFeedEndpoint` when saved; its refusal is shown under the
// field. The feed is public, so nothing here is a secret.

import SwiftUI
import WidgetCore

struct PredictionsSettingsView: View {
    let predictions: PredictionsSettings
    /// Why the last Save was refused, or "Saved.".
    var feedback: String?
    let setEnabled: @MainActor (Bool) -> Void
    let saveHost: @MainActor (String) -> Void
    @State private var host = ""

    static let explanation = "Shows your own Zen Predict model's forecast on the Predict tab, read from the feed host below "
        + "(https://<host>/latest.json) while the app is open. A forecast is not a reading: it is never saved, "
        + "and never used for alerts, Trio or sharing."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                PageTitle("Predictions")
                    .accessibilityIdentifier("settings.predictions.page")
                Text(verbatim: Self.explanation)
                    .font(Typography.body(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: Binding(get: { predictions.setup.isOn }, set: { setEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "Show predictions").font(Typography.body(size: 15, weight: .medium))
                        if predictions.setup.host == nil {
                            Text(verbatim: "Add the feed host first.")
                                .font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                }
                .frame(minHeight: Layout.minTarget)
                .disabled(predictions.setup.host == nil)
                .accessibilityIdentifier("settings.predictions.toggle")
                Hairline()
                hostSection
                statusSection
            }
            .padding(.horizontal, Layout.sideMargin)
            .padding(.vertical, 12)
        }
        .onAppear { host = predictions.setup.host ?? "" }
    }

    private var hostSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledField(label: "Feed host") {
                TextField(text: $host) { Text(verbatim: "zen.example.com") }
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { saveHost(host) } // Return saves too (and puts the keyboard away)
                    .accessibilityIdentifier("settings.predictions.host")
            }
            Button("Save") { saveHost(host) }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("settings.predictions.save")
            if let feedback {
                Text(verbatim: feedback)
                    .font(Typography.body(size: 13))
                    .foregroundStyle(feedback == AppModel.predictionsSaved ? AnyShapeStyle(Theme.muted) : AnyShapeStyle(Theme.alert))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.predictions.feedback")
            }
            if let buildHost = predictions.buildHost {
                Text(verbatim: "This build's host: \(buildHost).")
                    .font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if predictions.setup.isOn {
            // Re-read every 15 s so "Last updated" keeps counting while the page is open.
            TimelineView(.periodic(from: .now, by: 15)) { timeline in
                SettingsValueRow(title: "Status", value: PredictMapping.lastUpdatedText(predictions.lastSuccessAt, now: timeline.date))
                    .accessibilityIdentifier("settings.predictions.status")
            }
            if let error = predictions.lastError {
                WarningNote(text: "\(error) Retrying.")
                    .accessibilityIdentifier("settings.predictions.error")
            }
        }
    }
}
