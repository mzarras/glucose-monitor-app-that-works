// DEBUG builds only: replay a ReplayKit scenario in the running app, and the D20 developer switch
// that lets the Trio bridge and uploaders run in a DEBUG build (PROGRESS D11, D19, D20). Nothing
// here exists in Release.

#if DEBUG
import SwiftUI
import WidgetCore

struct DeveloperSettingsView: View {
    let debug: DebugSettings?
    let actions: SettingsActions
    @State private var scenario = ""
    @State private var speed: Double = 60

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                PageTitle("Developer")
                WarningNote(text: "DEBUG build: replayed data is not a sensor and is never handed to Trio or uploaded (S6). Test a live sensor with a Release build (D19).")
                SectionLabel("REPLAY")
                if let active = debug?.activeScenario {
                    SettingsValueRow(title: "Replaying", value: "\(active) at \(TrendsText.mgdl(debug?.speed ?? 1))×")
                    Button("Stop replay", action: actions.stopReplay)
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("developer.stopReplay")
                } else {
                    Picker(selection: $scenario) {
                        ForEach(debug?.availableScenarios ?? [], id: \.self) { Text(verbatim: $0).tag($0) }
                    } label: {
                        Text(verbatim: "Scenario")
                    }
                    .pickerStyle(.menu)
                    Picker(selection: $speed) {
                        ForEach(DebugSettings.speeds, id: \.self) { Text(verbatim: "\(Int($0))×").tag($0) }
                    } label: {
                        Text(verbatim: "Speed")
                    }
                    .pickerStyle(.segmented)
                    Text(verbatim: "Scenario seconds per real second. Above 1× the scenario runs ahead of the phone clock; alerts and the Now screen follow the replay clock.")
                        .font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Start replay") { actions.startReplay(scenario, speed) }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(scenario.isEmpty)
                        .accessibilityIdentifier("developer.startReplay")
                }
                Hairline()
                SectionLabel("LIVE OUTPUTS (D20)")
                Toggle(isOn: Binding(get: { debug?.developerLiveOutputsEnabled ?? false }, set: { actions.setDeveloperLiveOutputs($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "Let this DEBUG build hand readings to Trio and upload").font(Typography.body(size: 15, weight: .medium))
                        Text(verbatim: "Off by default. Even on, the bridge and uploaders accept only live sensor readings — never replay or imported data.")
                            .font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minHeight: Layout.minTarget)
            }
            .padding(.horizontal, Layout.sideMargin)
            .padding(.vertical, 12)
        }
        .onAppear {
            if scenario.isEmpty { scenario = debug?.availableScenarios.first ?? "" }
        }
    }
}
#endif
