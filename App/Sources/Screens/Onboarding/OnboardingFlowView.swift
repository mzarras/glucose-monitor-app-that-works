// Onboarding / pairing (HANDOFF §4.5, §4.6, §7.3.5, §8A; PROGRESS D7): welcome → optional history
// import (Nightscout or Clarity CSV, with progress) → remove the Dexcom app (and keep Dexcom
// Follow working with Share upload) → permissions → pairing code → warm-up countdown.

import GlucoseCore
import SwiftUI
import UniformTypeIdentifiers
import WidgetCore

struct OnboardingActions {
    var goTo: @MainActor (OnboardingStep) -> Void
    var startNightscoutImport: @MainActor (_ url: String, _ token: String, _ depth: ImportDepth) -> Void
    var startClarityImport: @MainActor (_ file: URL, _ recordedIn: TimeZone) -> Void
    var requestBluetooth: @MainActor () -> Void
    var requestNotifications: @MainActor () -> Void
    /// D26: AlarmKit authorization (iOS 26+).
    var requestAlarms: @MainActor () -> Void
    var setShareUpload: @MainActor (_ enabled: Bool, _ username: String, _ password: String, _ region: ShareRegion) -> Void
    var submitPairingCode: @MainActor (String) -> Void
    var finish: @MainActor () -> Void

    static var noop: OnboardingActions {
        OnboardingActions(goTo: { _ in }, startNightscoutImport: { _, _, _ in }, startClarityImport: { _, _ in }, requestBluetooth: {},
                          requestNotifications: {}, requestAlarms: {}, setShareUpload: { _, _, _, _ in }, submitPairingCode: { _ in }, finish: {})
    }
}

struct OnboardingFlowView: View {
    let state: OnboardingState
    let actions: OnboardingActions

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            OnboardingContent(state: state, actions: actions, now: timeline.date)
        }
        .editorialScreen()
    }
}

struct OnboardingContent: View {
    let state: OnboardingState
    let actions: OnboardingActions
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: "STEP \((state.visibleSteps.firstIndex(of: state.step) ?? 0) + 1) OF \(state.visibleSteps.count)")
                    .monoLabel(size: 11)
                    .foregroundStyle(Theme.muted)
                Spacer()
                if let previous = state.step.previous(alarmsAvailable: state.alarmsAvailable), state.step != .warmUp {
                    Button("Back") { actions.goTo(previous) }
                        .buttonStyle(LinkButtonStyle())
                }
            }
            Hairline().padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch state.step {
                    case .welcome: WelcomeStep(next: { actions.goTo(.importHistory) })
                    case .importHistory: ImportStep(state: state, actions: actions)
                    case .removeDexcomApp: RemoveDexcomAppStep(state: state, actions: actions)
                    case .permissions: PermissionsStep(state: state, actions: actions)
                    case .alarms: AlarmsStep(state: state, actions: actions)
                    case .pairing: PairingStep(state: state, actions: actions)
                    case .warmUp: WarmUpStep(state: state, now: now, finish: actions.finish)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 24)
            }
        }
        .padding(.horizontal, Layout.sideMargin)
        .padding(.top, 12)
    }
}

private struct StepTitle: View {
    let title: String
    let lead: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .font(Typography.title(size: 32))
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: lead)
                .font(Typography.body(size: 15))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Steps

struct WelcomeStep: View {
    let next: @MainActor () -> Void

    var body: some View {
        StepTitle(
            title: AppIdentity.displayName,
            lead: "Reads your G7 sensor directly, alerts with sounds you choose, hands readings to Trio, and shares them with followers through Nightscout."
        )
        Text(verbatim: "Keep a fingerstick meter nearby while you get started, and check readings that don't match how you feel.")
            .font(Typography.body(size: 13))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
        Button("Get started", action: next).buttonStyle(PrimaryButtonStyle())
    }
}

struct ImportStep: View {
    let state: OnboardingState
    let actions: OnboardingActions
    @State private var url = ""
    @State private var token = ""
    @State private var depth: ImportDepth = .ninetyDays
    @State private var choosingFile = false
    @State private var timeZone = TimeZone.current

    var body: some View {
        StepTitle(title: "Bring your history", lead: "Import past readings so Trends has 90 days of patterns from day one. Imported history is used for charts and statistics only — never for alerts or Trio.")
        if let progress = state.importProgress {
            ImportProgressView(progress: progress)
            if progress.isFinished || progress.errorMessage != nil {
                Button("Continue") { actions.goTo(.removeDexcomApp) }.buttonStyle(PrimaryButtonStyle())
            }
        } else {
            SectionLabel("FROM NIGHTSCOUT")
            LabeledField(label: "Site URL") {
                TextField(text: $url) { Text(verbatim: "https://your-site.example.com") }
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            LabeledField(label: "Access token (read)") {
                SecureField(text: $token) { Text(verbatim: "Token") }
            }
            Picker(selection: $depth) {
                ForEach(ImportDepth.allCases) { Text(verbatim: $0.label).tag($0) }
            } label: {
                Text(verbatim: "How much")
            }
            .pickerStyle(.segmented)
            Button("Import from Nightscout") { actions.startNightscoutImport(url, token, depth) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(url.isEmpty || token.isEmpty)
            Hairline()
            SectionLabel("FROM A DEXCOM CLARITY EXPORT")
            Text(verbatim: "Clarity CSV times have no time zone. Choose the zone the data was recorded in.")
                .font(Typography.body(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Picker(selection: $timeZone) {
                ForEach(Self.timeZoneChoices, id: \.identifier) { zone in
                    Text(verbatim: zone.identifier).tag(zone)
                }
            } label: {
                Text(verbatim: "Recorded in")
            }
            .pickerStyle(.menu)
            Button("Choose CSV file…") { choosingFile = true }
                .buttonStyle(SecondaryButtonStyle())
                .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
                    if case .success(let file) = result { actions.startClarityImport(file, timeZone) }
                }
            Hairline()
            Button("Skip — start without history") { actions.goTo(.removeDexcomApp) }
                .buttonStyle(LinkButtonStyle())
        }
    }

    /// Current zone first, then every known zone.
    static var timeZoneChoices: [TimeZone] {
        let current = TimeZone.current
        let others = TimeZone.knownTimeZoneIdentifiers.filter { $0 != current.identifier }.compactMap(TimeZone.init(identifier:))
        return [current] + others
    }
}

struct ImportProgressView: View {
    let progress: ImportProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if !progress.isFinished && progress.errorMessage == nil {
                    ProgressView().accessibilityHidden(true)
                }
                Text(verbatim: progress.isFinished ? "Import finished" : progress.errorMessage == nil ? "Importing…" : "Import stopped")
                    .font(Typography.body(size: 15, weight: .semibold))
            }
            Text(verbatim: OnboardingText.importProgress(progress))
                .font(Typography.label(size: 12))
            if let error = progress.errorMessage {
                FieldMessage(text: "\(error) Already-imported readings are kept; running the import again continues where it stopped.")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(Theme.rule, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

struct RemoveDexcomAppStep: View {
    let state: OnboardingState
    let actions: OnboardingActions
    @State private var shareEnabled = true
    @State private var username = ""
    @State private var password = ""
    @State private var region: ShareRegion = .default

    var body: some View {
        StepTitle(title: "Remove the Dexcom app", lead: "Only one app can be the sensor's primary device. Delete the Dexcom G7 app from this phone before pairing. A Dexcom receiver can stay paired.")
        WarningNote(text: "Dexcom Follow stops when the Dexcom app is gone: it was the app uploading to Dexcom Share. People following you in Dexcom Follow stop getting readings unless this app uploads to Share instead.")
        Toggle(isOn: $shareEnabled) {
            Text(verbatim: "Upload to Dexcom Share").font(Typography.body(size: 15, weight: .medium))
        }
        .frame(minHeight: Layout.minTarget)
        if shareEnabled {
            Picker(selection: $region) {
                ForEach(ShareRegion.allCases) { Text(verbatim: $0.label).tag($0) }
            } label: {
                Text(verbatim: "Region")
            }
            .pickerStyle(.segmented)
            LabeledField(label: "Dexcom username") {
                TextField(text: $username) { Text(verbatim: "Username") }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
            }
            LabeledField(label: "Password") {
                SecureField(text: $password) { Text(verbatim: "Password") }.textContentType(.password)
            }
        }
        Button("I've removed the Dexcom app") {
            actions.setShareUpload(shareEnabled, username, password, region)
            actions.goTo(.permissions)
        }
        .buttonStyle(PrimaryButtonStyle())
        .onAppear {
            shareEnabled = state.shareUploadEnabled
            region = state.shareRegion
        }
    }
}

struct PermissionsStep: View {
    let state: OnboardingState
    let actions: OnboardingActions

    var body: some View {
        StepTitle(title: "Permissions", lead: "Bluetooth to hear the sensor, including while the phone is locked. Notifications so alerts reach you.")
        permissionRow(title: "Bluetooth", state: state.bluetooth, allow: actions.requestBluetooth)
        permissionRow(title: "Notifications", state: notificationState, allow: actions.requestNotifications)
        let critical = SettingsText.criticalAlerts(state.criticalAlerts)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: "Critical Alerts").font(Typography.body(size: 15, weight: .medium))
                Spacer()
                Text(verbatim: critical.status).font(Typography.label(size: 12))
            }
            Text(verbatim: critical.note).font(Typography.body(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        Button("Continue") { actions.goTo(state.step.next(alarmsAvailable: state.alarmsAvailable) ?? .pairing) }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(state.bluetooth != .granted)
        if state.bluetooth == .denied {
            FieldMessage(text: "Bluetooth is required. Allow it in iOS Settings to continue.")
        }
    }

    private var notificationState: PermissionState {
        switch state.notifications {
        case .authorized: return .granted
        case .denied, .provisional: return .denied
        case .notDetermined: return .notDetermined
        }
    }

    private func permissionRow(title: String, state: PermissionState, allow: @escaping @MainActor () -> Void) -> some View {
        HStack {
            Text(verbatim: title).font(Typography.body(size: 15, weight: .medium))
            Spacer()
            switch state {
            case .granted:
                Text(verbatim: "ALLOWED").monoLabel(size: 11, medium: true).foregroundStyle(Theme.accent)
            case .denied:
                Button("Open Settings", action: SystemSettings.openAppSettings).buttonStyle(LinkButtonStyle())
            case .notDetermined:
                Button("Allow", action: allow).buttonStyle(LinkButtonStyle())
            }
        }
        .frame(minHeight: Layout.minTarget)
    }
}

/// D26: urgent low as a system alarm (iOS 26+ only; the step is skipped elsewhere).
struct AlarmsStep: View {
    let state: OnboardingState
    let actions: OnboardingActions

    var body: some View {
        StepTitle(title: "Urgent low alarm", lead: "Urgent low rings as a system alarm, like a clock alarm: even on silent, in Focus, and while the app is in the background. Other alerts stay notifications.")
        let text = SettingsText.urgentLowAlarm(state.urgentLowAlarm)
        HStack {
            Text(verbatim: "Alarms").font(Typography.body(size: 15, weight: .medium))
            Spacer()
            switch state.urgentLowAlarm {
            case .authorized:
                Text(verbatim: "ALLOWED").monoLabel(size: 11, medium: true).foregroundStyle(Theme.accent)
            case .denied:
                Button("Open Settings", action: SystemSettings.openAppSettings).buttonStyle(LinkButtonStyle())
            case .notDetermined:
                Button("Allow", action: actions.requestAlarms).buttonStyle(LinkButtonStyle())
            case .unavailable:
                Text(verbatim: "NOT AVAILABLE").monoLabel(size: 11).foregroundStyle(Theme.muted)
            }
        }
        .frame(minHeight: Layout.minTarget)
        if state.urgentLowAlarm == .denied {
            FieldMessage(text: text.note)
        }
        Button("Continue") { actions.goTo(.pairing) }
            .buttonStyle(PrimaryButtonStyle())
    }
}

struct PairingStep: View {
    let state: OnboardingState
    let actions: OnboardingActions

    var body: some View {
        StepTitle(title: "Pair your sensor", lead: "Apply the sensor first. iOS will ask to pair with it; tap Pair.")
        switch state.pairing {
        case .idle:
            PairingCodeEntry(pair: actions.submitPairingCode)
        case .inProgress:
            HStack(spacing: 10) {
                ProgressView().accessibilityHidden(true)
                Text(verbatim: "Waiting for the sensor… It connects about every 5 minutes. Accept the iOS pairing prompt when it appears.")
                    .font(Typography.body(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let message):
            FieldMessage(text: message)
            PairingCodeEntry(pair: actions.submitPairingCode)
        case .paired:
            Text(verbatim: "Paired.").font(Typography.body(size: 15, weight: .semibold))
            Button("Continue") { actions.goTo(.warmUp) }.buttonStyle(PrimaryButtonStyle())
        }
    }
}

struct WarmUpStep: View {
    let state: OnboardingState
    let now: Date
    let finish: @MainActor () -> Void

    var body: some View {
        StepTitle(title: "Warming up", lead: "The sensor needs time before its first reading. You can leave this screen; the app keeps listening in the background.")
        if case .warmingUp(let endsAt) = state.sensorState, now < endsAt {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: TimeText.duration(endsAt.timeIntervalSince(now)))
                    .font(Typography.statHero(size: 96))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(verbatim: "LEFT · FIRST READING AROUND \(TimeText.time(endsAt).uppercased())")
                    .monoLabel(size: 11)
                    .foregroundStyle(Theme.muted)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(verbatim: "Waiting for the first reading.").font(Typography.body(size: 15))
        }
        Text(verbatim: "Don't force-quit the app (swiping it away): iOS won't restart it, and readings stop until you open it again.")
            .font(Typography.body(size: 13))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
        Button("Done", action: finish).buttonStyle(PrimaryButtonStyle())
    }
}
