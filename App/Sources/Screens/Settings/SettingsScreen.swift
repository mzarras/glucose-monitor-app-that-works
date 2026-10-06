// Settings (HANDOFF §4.5, §7.3.4, §8A, §11 step 6; PROGRESS D4/D7/D16/D17/D20). The main page
// shows a status summary per area; editing happens on sub-pages. Secrets are write-only fields: the
// state says whether one is saved, never what it is. Every action goes to `AppServices` through
// `AppModel` (docs/app-wiring.md).

import GlucoseCore
import SwiftUI
import WidgetCore

struct SettingsActions {
    /// Pair a new sensor (new-sensor flow).
    var pair: @MainActor (_ code: String) -> Void
    /// Pair the worn sensor again (G7Kit `pairAgain(code:)`, review M1).
    var pairAgain: @MainActor (_ code: String) -> Void
    /// Deletes the pairing (key and code) and Trio's heartbeat keys.
    var forgetSensor: @MainActor () -> Void = {}
    /// Only offered when the source can stop a session (`SensorSettings.canStopSession`; G7: no).
    var stopSession: @MainActor () -> Void
    var openCalibration: @MainActor () -> Void
    var setTrioEnabled: @MainActor (Bool) -> Void
    /// `token` is nil when the field was left empty (keep the saved one).
    var saveNightscout: @MainActor (_ url: String, _ token: String?) -> Void
    var setNightscoutUpload: @MainActor (Bool) -> Void
    /// "Retry now": flushes both uploaders ignoring backoff.
    var retryUploads: @MainActor () -> Void = {}
    var setShareEnabled: @MainActor (Bool) -> Void
    /// `password` is nil when the field was left empty (keep the saved one).
    var saveShareCredentials: @MainActor (_ username: String, _ password: String?, _ receiverSerialNumber: String) -> Void
    var setShareRegion: @MainActor (ShareRegion) -> Void
    var openSystemSettings: @MainActor () -> Void
    var requestNotifications: @MainActor () -> Void = {}
    var requestUrgentLowAlarm: @MainActor () -> Void = {}
    /// Re-reads permissions, alarm volume and the database summary.
    var refreshStatus: @MainActor () -> Void = {}
    var startImport: @MainActor () -> Void
    var exportCSV: @MainActor () -> Void
    var exportDiagnostics: @MainActor () -> Void
    var setAccent: @MainActor (AccentChoice) -> Void
    var setAppearance: @MainActor (AppearancePreference) -> Void
    var setRetention: @MainActor (DataRetention) -> Void
    /// D45: switch between listening alongside the Dexcom app and pairing this app (after the
    /// page's confirmation).
    var setConnectionMode: @MainActor (SensorConnectionMode) -> Void = { _ in }
    /// D47: record raw glucose packets in the diagnostic log.
    var setPacketRecording: @MainActor (Bool) -> Void = { _ in }
    #if DEBUG
    /// DEBUG builds: replay controls (D11, D20). Not in Release (review m5).
    var startReplay: @MainActor (_ scenario: String, _ speed: Double) -> Void = { _, _ in }
    var stopReplay: @MainActor () -> Void = {}
    var setDeveloperLiveOutputs: @MainActor (Bool) -> Void = { _ in }
    #endif

    static var noop: SettingsActions {
        SettingsActions(pair: { _ in }, pairAgain: { _ in }, stopSession: {}, openCalibration: {}, setTrioEnabled: { _ in }, saveNightscout: { _, _ in },
                        setNightscoutUpload: { _ in }, setShareEnabled: { _ in }, saveShareCredentials: { _, _, _ in }, setShareRegion: { _ in },
                        openSystemSettings: {}, startImport: {}, exportCSV: {}, exportDiagnostics: {}, setAccent: { _ in }, setAppearance: { _ in },
                        setRetention: { _ in })
    }
}

struct SettingsScreen: View {
    let state: SettingsViewState
    let calibration: CalibrationViewState
    @Binding var route: SettingsRoute?
    let actions: SettingsActions
    /// G7Kit `hasStoredSensor` (review N2), passed to Settings › Sensor.
    var hasStoredSensor = false
    @State private var path: [SettingsRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                SettingsContent(state: state, now: Date(), actions: actions)
            }
            .editorialScreen()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: SettingsRoute.self) { route in
                Group {
                    switch route {
                    case .sensor: SensorSettingsView(sensor: state.sensor, calibration: calibration, feedback: state.feedback.pairing, actions: actions,
                                                     hasStoredSensor: hasStoredSensor, connection: state.connection,
                                                     connectionSwitchingTo: state.connectionSwitchingTo, connectionFeedback: state.feedback.connection,
                                                     connectionSettingProblem: state.connectionSettingProblem)
                    case .trio: TrioSettingsView(trio: state.trio, setEnabled: actions.setTrioEnabled, listening: state.isListening)
                    case .sharing: SharingSettingsView(nightscout: state.nightscout, share: state.dexcomShare, feedback: state.feedback, actions: actions,
                                                       listening: state.isListening)
                    case .alertDelivery: AlertDeliveryView(delivery: state.delivery, actions: actions)
                    case .about: AboutView(version: state.appVersion)
                    #if DEBUG
                    case .developer: DeveloperSettingsView(debug: state.debug, actions: actions)
                    #endif
                    }
                }
                .editorialScreen()
            }
        }
        .onAppear(perform: followRoute)
        .onChange(of: route) { followRoute() }
        .onAppear { actions.refreshStatus() }
    }

    private func followRoute() {
        guard let route else { return }
        path = [route]
        self.route = nil
    }
}

struct SettingsContent: View {
    let state: SettingsViewState
    let now: Date
    let actions: SettingsActions
    var context: DisplayContext = .current

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Settings")
                    .font(Typography.title(size: 36))
                    .accessibilityAddTraits(.isHeader)
                Hairline().padding(.top, 6)
            }
            SettingsGroup("SENSOR") {
                SettingsLinkRow(title: "G7 sensor", value: state.sensor.isWaitingForFirstState ? "checking…"
                                    : SensorStatusText.row(state.sensor.state, session: state.sensor.session, now: now, context: context,
                                                         listening: state.isListening), route: .sensor)
                    .accessibilityIdentifier("settings.sensor")
                if let connection = state.connection {
                    SettingsLinkRow(title: "Connection", value: ConnectionModeText.row(connection.mode), route: .sensor)
                        .accessibilityIdentifier("settings.connection")
                }
            }
            SettingsGroup("TRIO") {
                SettingsLinkRow(title: "Trio handoff",
                                value: ListenModeRules.outputRow(state.trio.isEnabled ? TrioStatusText.row(state.trio.status, context: context) : "off",
                                                                 listening: state.isListening),
                                route: .trio, valueIsAlert: !state.isListening && isFailing(state.trio.status))
                    .accessibilityIdentifier("settings.trio")
            }
            SettingsGroup("SHARING") {
                SettingsLinkRow(title: "Nightscout",
                                value: ListenModeRules.outputRow(state.nightscout.uploadEnabled ? UploadStatusText.row(state.nightscout.status, context: context) : "off",
                                                                 listening: state.isListening),
                                route: .sharing, valueIsAlert: !state.isListening && isFailing(state.nightscout.status))
                    .accessibilityIdentifier("settings.nightscout")
                SettingsLinkRow(title: "Dexcom Share",
                                value: ListenModeRules.outputRow(state.dexcomShare.isEnabled ? UploadStatusText.row(state.dexcomShare.status, context: context) : "off",
                                                                 listening: state.isListening),
                                route: .sharing, valueIsAlert: !state.isListening && isFailing(state.dexcomShare.status))
                    .accessibilityIdentifier("settings.share")
            }
            SettingsGroup("ALERT DELIVERY") {
                SettingsLinkRow(title: "Notifications", value: SettingsText.notifications(state.delivery.notifications).status,
                                route: .alertDelivery, valueIsAlert: state.delivery.notifications == .denied || state.delivery.notifications == .provisional)
                SettingsLinkRow(title: "Urgent low alarm", value: SettingsText.urgentLowAlarm(state.delivery.urgentLowAlarm).status,
                                route: .alertDelivery, valueIsAlert: state.delivery.urgentLowAlarm == .denied)
                SettingsLinkRow(title: "Critical Alerts (optional)", value: SettingsText.criticalAlerts(state.delivery.criticalAlerts).status, route: .alertDelivery)
                SettingsLinkRow(title: "Alarm volume", value: SettingsText.alarmVolume(state.delivery.alarmVolume), route: .alertDelivery, valueIsAlert: isTooLow(state.delivery.alarmVolume))
            }
            dataGroup
            diagnosticsGroup
            appearanceGroup
            SettingsGroup("ABOUT") {
                SettingsLinkRow(title: "About, licenses and credits", value: state.appVersion, route: .about)
            }
            #if DEBUG
            SettingsGroup("DEVELOPER (DEBUG BUILD)") {
                SettingsLinkRow(title: "Replay and live outputs", value: state.debug?.activeScenario.map { "replaying \($0)" } ?? "sensor", route: .developer)
                    .accessibilityIdentifier("settings.developer")
            }
            #endif
        }
        .padding(.horizontal, Layout.sideMargin)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    private var dataGroup: some View {
        SettingsGroup("DATA") {
            SettingsButtonRow(title: "Import history", detail: importDetail, action: actions.startImport)
            SettingsButtonRow(title: "Export all data (CSV)", detail: nil, action: actions.exportCSV)
            SettingsButtonRow(title: "Export diagnostics", detail: SettingsText.diagnosticsContents, action: actions.exportDiagnostics)
            if let message = state.feedback.export {
                FieldMessage(text: message).padding(.vertical, 6)
            }
            AdaptiveRow {
                Text(verbatim: "Keep readings for").font(Typography.body(size: 15))
            } trailing: {
                Picker(selection: Binding(get: { state.retention }, set: { actions.setRetention($0) })) {
                    ForEach(DataRetention.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
                } label: {
                    Text(verbatim: "Keep readings for")
                }
                .pickerStyle(.menu)
            }
            .frame(minHeight: Layout.minTarget)
            Hairline()
            SettingsValueRow(title: "Database size", value: SettingsText.database(bytes: state.databaseSizeBytes, readings: state.readingCount))
            if let problem = SettingsText.storageProblem(state.storageAvailability) {
                FieldMessage(text: problem).padding(.vertical, 6)
            }
        }
    }

    private var importDetail: String {
        if let running = state.runningImport { return OnboardingText.importProgress(running, context: context) }
        guard let last = state.lastImport else { return "From Nightscout or a Clarity CSV export." }
        let source = last.origin == .nightscout ? "Nightscout" : "Clarity CSV"
        return "Last: \(last.readingsImported.formatted()) readings from \(source), \(TimeText.shortDay(last.finishedAt, context))."
    }

    /// D47's packet recording, once the facade offers it (Export diagnostics stays under DATA).
    @ViewBuilder
    private var diagnosticsGroup: some View {
        if let recording = state.packetRecording {
            SettingsGroup("DIAGNOSTICS") {
                VStack(spacing: 0) {
                    Toggle(isOn: Binding(get: { recording.isOn }, set: { actions.setPacketRecording($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: PacketRecordingText.title).font(Typography.body(size: 15))
                            Text(verbatim: PacketRecordingText.explanation).font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            if recording.unresolved {
                                Text(verbatim: PacketRecordingText.unresolvedNote).font(Typography.body(size: 12)).foregroundStyle(Theme.alert)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("settings.packetRecording.unresolved")
                            }
                        }
                    }
                    .frame(minHeight: Layout.minTarget)
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("settings.packetRecording")
                    Hairline()
                }
            }
        }
    }

    private var appearanceGroup: some View {
        SettingsGroup("APPEARANCE") {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "Light or dark").font(Typography.body(size: 15))
                Picker(selection: Binding(get: { state.appearance }, set: { actions.setAppearance($0) })) {
                    ForEach(AppearancePreference.allCases) { Text(verbatim: $0.label).tag($0) }
                } label: {
                    Text(verbatim: "Light or dark")
                }
                .pickerStyle(.segmented)
                Text(verbatim: "Widgets always follow the system setting.")
                    .font(Typography.body(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 8)
            Hairline()
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "Accent colour").font(Typography.body(size: 15))
                HStack(spacing: 12) {
                    ForEach(AccentChoice.allCases) { choice in
                        AccentSwatch(choice: choice, isSelected: choice == state.accent) { actions.setAccent(choice) }
                    }
                }
            }
            .padding(.vertical, 8)
            Hairline()
            VStack(alignment: .leading, spacing: 2) {
                AdaptiveRow {
                    Text(verbatim: "Units").font(Typography.body(size: 15))
                } trailing: {
                    Text(verbatim: GlucoseText.unit).font(Typography.label(size: 12))
                }
                Text(verbatim: "mmol/L is planned for a later version.")
                    .font(Typography.body(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: Layout.minTarget)
        }
    }

    private func isFailing(_ status: TrioStatus) -> Bool {
        if case .failing = status { return true }
        return false
    }

    private func isFailing(_ status: UploadStatus) -> Bool {
        switch status {
        case .failing, .notSetUp: return true
        case .off, .ok: return false
        }
    }

    private func isTooLow(_ status: AlarmVolumeStatus) -> Bool {
        if case .tooLow = status { return true }
        return false
    }
}

// MARK: - Rows

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(title).padding(.bottom, 2)
            content
        }
    }
}

struct SettingsLinkRow: View {
    let title: String
    let value: String
    let route: SettingsRoute
    var valueIsAlert = false

    private var titleText: some View {
        Text(verbatim: title).font(Typography.body(size: 15))
    }

    private var valueText: some View {
        Text(verbatim: value)
            .font(Typography.label(size: 11))
            .foregroundStyle(valueIsAlert ? AnyShapeStyle(Theme.alert) : AnyShapeStyle(Theme.muted))
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(Theme.muted)
            .accessibilityHidden(true)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink(value: route) {
                // One line when it fits; value under the title at large text sizes, so nothing
                // breaks mid-word.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        titleText.fixedSize()
                        Spacer(minLength: 8)
                        valueText.fixedSize()
                        chevron
                    }
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            titleText
                            valueText
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        chevron
                    }
                }
                .padding(.vertical, 4)
                .frame(minHeight: Layout.minTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Hairline()
        }
    }
}

struct SettingsValueRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 0) {
            AdaptiveRow {
                Text(verbatim: title).font(Typography.body(size: 15))
            } trailing: {
                Text(verbatim: value).font(Typography.label(size: 12))
            }
            .frame(minHeight: Layout.minTarget)
            .accessibilityElement(children: .combine)
            Hairline()
        }
    }
}

/// Leading and trailing content on one line when both fit at their natural width; otherwise the
/// trailing content goes under the leading content (large text sizes), so neither breaks mid-word.
struct AdaptiveRow<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                leading.fixedSize()
                Spacer(minLength: 8)
                trailing.fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                leading.fixedSize(horizontal: false, vertical: true)
                trailing.fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

struct SettingsButtonRow: View {
    let title: String
    let detail: String?
    let action: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(Typography.body(size: 15)).foregroundStyle(Theme.accent)
                    if let detail {
                        Text(verbatim: detail).font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Layout.minTarget, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Hairline()
        }
    }
}

struct AccentSwatch: View {
    let choice: AccentChoice
    let isSelected: Bool
    let select: @MainActor () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: select) {
            Circle()
                .fill(Color(rgb: colorScheme == .dark ? choice.dark : choice.light))
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(Theme.ink, lineWidth: isSelected ? 2 : 0).padding(-5))
                .frame(width: Layout.minTarget, height: Layout.minTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: choice.displayName))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
