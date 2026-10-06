// Onboarding / pairing (HANDOFF §4.5, §4.6, §7.3.5, §8A; PROGRESS D7, D26, D35): welcome →
// optional history import (Nightscout or Clarity CSV, with progress) → remove the Dexcom app (and
// other G7 apps; keep Dexcom Follow working with Share upload) → permissions → alarms (iOS 26+) →
// pairing code → warm-up countdown. Actions go to `AppServices` through `AppModel`.

import GlucoseCore
import SwiftUI
import UniformTypeIdentifiers
import WidgetCore

struct OnboardingActions {
    var goTo: @MainActor (OnboardingStep) -> Void
    var startNightscoutImport: @MainActor (_ url: String, _ token: String, _ depth: ImportDepth) -> Void
    var startClarityImport: @MainActor (_ file: URL, _ recordedIn: TimeZone) -> Void
    /// Bluetooth can't be requested on demand (iOS asks when the app first uses it); this opens the
    /// app's page in iOS Settings for a denied permission.
    var requestBluetooth: @MainActor () -> Void
    var requestNotifications: @MainActor () -> Void
    /// D26: AlarmKit authorization (iOS 26+).
    var requestAlarms: @MainActor () -> Void
    /// Saves the Share credentials and turns upload on (or turns it off), then moves to the next
    /// step; a failure stays on the step with `OnboardingState.shareMessage`.
    var setShareUpload: @MainActor (_ enabled: Bool, _ username: String, _ password: String, _ receiverSerialNumber: String, _ region: ShareRegion) -> Void
    var submitPairingCode: @MainActor (String) -> Void
    /// Pair the worn sensor again (G7Kit `pairAgain(code:)`, review M1).
    var pairAgain: @MainActor (String) -> Void
    var finish: @MainActor () -> Void
    var cancelImport: @MainActor () -> Void = {}
    /// "Set up later": leaves onboarding without completing it (review M1).
    var dismiss: @MainActor () -> Void = {}
    /// D45: listen alongside the Dexcom app or pair this app (remembered on the step).
    var chooseConnection: @MainActor (SensorConnectionMode) -> Void = { _ in }
    /// D45: Continue on the connection step: switches the facade to the choice, then moves on.
    var continueConnection: @MainActor () -> Void = {}

    static var noop: OnboardingActions {
        OnboardingActions(goTo: { _ in }, startNightscoutImport: { _, _, _ in }, startClarityImport: { _, _ in }, requestBluetooth: {},
                          requestNotifications: {}, requestAlarms: {}, setShareUpload: { _, _, _, _, _ in }, submitPairingCode: { _ in },
                          pairAgain: { _ in }, finish: {})
    }
}

struct OnboardingFlowView: View {
    let state: OnboardingState
    let actions: OnboardingActions
    /// DEBUG only: the active replay scenario, named in the build banner.
    var replayScenario: String? = nil
    /// Review N2 / N1 item 3: a new pairing; Phase 2 sets `authenticatedInThisPairing` once the
    /// sensor has authenticated in this flow.
    var pairingContext: PairingContext = .newPairing

    /// Drawn on top in every DEBUG build (D19): pairing a real sensor from a DEBUG build must be
    /// unmistakable (review M3). Computed here, not passed in, so no caller can hide it (n3).
    var buildBanner: BuildBanner? { BuildBanner.forThisBuild(replayScenario: replayScenario) }

    var body: some View {
        VStack(spacing: 0) {
            if let buildBanner {
                BuildBannerView(banner: buildBanner)
            }
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                OnboardingContent(state: state, actions: actions, now: timeline.date, pairingContext: pairingContext)
            }
        }
        .editorialScreen()
    }
}

struct OnboardingContent: View {
    let state: OnboardingState
    let actions: OnboardingActions
    let now: Date
    var pairingContext: PairingContext = .newPairing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: "STEP \((state.visibleSteps.firstIndex(of: state.step) ?? 0) + 1) OF \(state.visibleSteps.count)")
                    .monoLabel(size: 11)
                    .foregroundStyle(Theme.muted)
                    .accessibilityIdentifier("onboarding.step")
                Spacer()
                if let previous = state.step(before: state.step), state.step != .warmUp {
                    Button("Back") { actions.goTo(previous) }
                        .buttonStyle(LinkButtonStyle())
                }
                if state.isDismissible, state.step != .warmUp {
                    // Review M1: never a trap. (Warm-up has its own Done.)
                    Button("Set up later", action: actions.dismiss)
                        .buttonStyle(LinkButtonStyle())
                        .accessibilityIdentifier("onboarding.dismiss")
                }
            }
            Hairline().padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch state.step {
                    case .welcome: WelcomeStep(next: { actions.goTo(state.step(after: .welcome) ?? .importHistory) })
                    case .connection: ConnectionStep(state: state, actions: actions)
                    case .importHistory: ImportStep(state: state, actions: actions, next: { actions.goTo(state.step(after: .importHistory) ?? .removeDexcomApp) })
                    case .removeDexcomApp: RemoveDexcomAppStep(state: state, actions: actions)
                    case .permissions: PermissionsStep(state: state, actions: actions)
                    case .alarms: AlarmsStep(state: state, actions: actions)
                    case .pairing: PairingStep(state: state, actions: actions, context: pairingContext)
                    case .listen: ListenStep(state: state, actions: actions)
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
            .accessibilityIdentifier("onboarding.welcome.start")
    }
}

struct ImportStep: View {
    let state: OnboardingState
    let actions: OnboardingActions
    /// Where "Continue"/"Skip" goes: the next onboarding step, or closing Settings' import sheet.
    let next: @MainActor () -> Void
    var skipTitle = "Skip — start without history"
    @State private var url = ""
    @State private var token = ""
    @State private var depth: ImportDepth = .ninetyDays
    @State private var choosingFile = false
    @State private var timeZone = TimeZone.current

    var body: some View {
        StepTitle(title: "Bring your history", lead: "Import past readings so Trends has 90 days of patterns from day one. Imported history is used for charts and statistics only — never for alerts, Trio or uploads.")
        if let progress = state.importProgress {
            ImportProgressView(progress: progress)
            if progress.isRunning {
                Button("Stop import", action: actions.cancelImport).buttonStyle(SecondaryButtonStyle())
            } else {
                Button("Continue", action: next).buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("onboarding.import.continue")
            }
        }
        if state.importProgress?.isRunning != true {
            sources
        }
    }

    @ViewBuilder
    private var sources: some View {
        SectionLabel("FROM NIGHTSCOUT")
        if let site = state.nightscoutSiteURL, state.nightscoutHasToken {
            Text(verbatim: "Saved site: \(site)")
                .font(Typography.body(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            LabeledField(label: "Site URL") {
                TextField(text: $url) { Text(verbatim: "https://your-site.example.com") }
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            LabeledField(label: "Access token (read and write)") {
                SecureField(text: $token) { Text(verbatim: "Token") }
            }
        }
        Picker(selection: $depth) {
            ForEach(ImportDepth.allCases) { Text(verbatim: $0.label).tag($0) }
        } label: {
            Text(verbatim: "How much")
        }
        .pickerStyle(.segmented)
        Button("Import from Nightscout") { actions.startNightscoutImport(url, token, depth) }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!hasSavedSite && (url.isEmpty || token.isEmpty))
        if let message = state.nightscoutMessage {
            FieldMessage(text: message)
        }
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
        Button(skipTitle, action: next)
            .buttonStyle(LinkButtonStyle())
            .accessibilityIdentifier("onboarding.import.skip")
    }

    private var hasSavedSite: Bool { state.nightscoutSiteURL != nil && state.nightscoutHasToken }

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
                if progress.isRunning {
                    ProgressView().accessibilityHidden(true)
                }
                Text(verbatim: title)
                    .font(Typography.body(size: 15, weight: .semibold))
            }
            Text(verbatim: OnboardingText.importProgress(progress))
                .font(Typography.label(size: 12))
            if let note = progress.skippedNote {
                Text(verbatim: note).font(Typography.label(size: 11)).foregroundStyle(Theme.muted)
            }
            if let note = OnboardingText.futureDatedNote(progress.rejectedFutureDated) {
                // A wrong time zone or a clock fault: never stored as readings (PROGRESS D33).
                FieldMessage(text: note)
            }
            if let error = progress.errorMessage {
                FieldMessage(text: OnboardingText.importFailure(error))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(Theme.rule, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("import.progress")
    }

    private var title: String {
        if progress.isFinished { return "Import finished" }
        if progress.isCancelled { return "Import stopped" }
        if progress.errorMessage != nil { return "Import stopped" }
        return "Importing…"
    }
}

struct RemoveDexcomAppStep: View {
    let state: OnboardingState
    let actions: OnboardingActions
    @State private var shareEnabled = true
    @State private var username = ""
    @State private var password = ""
    @State private var receiverSerial = ""
    @State private var region: ShareRegion = .default

    var body: some View {
        StepTitle(title: "Remove the Dexcom app", lead: "Only one app can be the sensor's primary device. Delete the Dexcom G7 app from this phone before pairing. A Dexcom receiver can stay paired.")
        WarningNote(text: OnboardingState.otherG7AppsWarning)
        WarningNote(text: "Dexcom Follow stops when the Dexcom app is gone: it was the app uploading to Dexcom Share. People following you in Dexcom Follow stop getting readings unless this app uploads to Share instead. Invite anyone new in the Dexcom app before you delete it.")
        Toggle(isOn: $shareEnabled) {
            Text(verbatim: "Upload to Dexcom Share").font(Typography.body(size: 15, weight: .medium))
        }
        .frame(minHeight: Layout.minTarget)
        if shareEnabled {
            Picker(selection: $region) {
                ForEach(ShareRegion.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
            } label: {
                Text(verbatim: "Region")
            }
            .pickerStyle(.segmented)
            LabeledField(label: "Dexcom account name") {
                TextField(text: $username) { Text(verbatim: "Username") }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
            }
            LabeledField(label: "Password") {
                SecureField(text: $password) { Text(verbatim: "Password") }.textContentType(.password)
            }
            LabeledField(label: "Receiver serial number") {
                TextField(text: $receiverSerial) { Text(verbatim: "From the Dexcom account, not the sensor code") }
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
        }
        if let message = state.shareMessage {
            FieldMessage(text: message)
        }
        Button("I've removed the Dexcom app") {
            actions.setShareUpload(shareEnabled, username, password, receiverSerial, region)
        }
        .buttonStyle(PrimaryButtonStyle())
        .accessibilityIdentifier("onboarding.removeDexcom.continue")
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
        HStack {
            Text(verbatim: "Bluetooth").font(Typography.body(size: 15, weight: .medium))
            Spacer()
            switch state.bluetooth {
            case .granted:
                Text(verbatim: "ALLOWED").monoLabel(size: 11, medium: true).foregroundStyle(Theme.accent)
            case .denied:
                Button("Open Settings", action: actions.requestBluetooth).buttonStyle(LinkButtonStyle())
            case .notDetermined:
                Text(verbatim: "IOS WILL ASK").monoLabel(size: 11).foregroundStyle(Theme.muted)
            }
        }
        .frame(minHeight: Layout.minTarget)
        if state.bluetooth == .notDetermined {
            Text(verbatim: "iOS asks the first time the app looks for the sensor. Tap Allow.")
                .font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        Button("Continue") { actions.goTo(state.step(after: .permissions) ?? .pairing) }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(state.bluetooth == .denied)
            .accessibilityIdentifier("onboarding.permissions.continue")
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
        Button("Continue") { actions.goTo(state.step(after: .alarms) ?? .pairing) }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("onboarding.alarms.continue")
    }
}

/// D45: how this app reaches the sensor. Listening keeps the Dexcom app (no removal step, no
/// pairing); pairing is the original flow.
struct ConnectionStep: View {
    let state: OnboardingState
    let actions: OnboardingActions
    @State private var confirming = false

    var body: some View {
        StepTitle(title: "How to connect", lead: "Choose how this app reaches your sensor. You can change it later in Settings › Sensor.")
        ConnectionModeChoices(selected: state.connection?.mode, select: actions.chooseConnection)
            .disabled(state.connectionSwitching)
        if let message = state.connectionMessage {
            FieldMessage(text: message)
                .accessibilityIdentifier("onboarding.connection.message")
        }
        if state.connectionSwitching {
            HStack(spacing: 10) {
                ProgressView().accessibilityHidden(true)
                Text(verbatim: ConnectionModeText.switching).font(Typography.body(size: 14))
            }
            .accessibilityElement(children: .combine)
        } else if let mode = state.connection?.mode {
            Button("Continue") {
                // Switching replaces a stored sensor's pairing: ask first (as in Settings › Sensor).
                if mode != state.currentConnectionMode, state.connectionSwitchNeedsConfirmation {
                    confirming = true
                } else {
                    actions.continueConnection()
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("onboarding.connection.continue")
            .accessibilityHint(Text(verbatim: ConnectionModeText.title(mode)))
            .confirmationDialog(ConnectionModeText.switchTitle(to: mode), isPresented: $confirming, titleVisibility: .visible) {
                Button(ConnectionModeText.switchButton(to: mode), action: actions.continueConnection)
            } message: {
                Text(verbatim: ConnectionModeText.switchMessage(to: mode))
            }
        }
    }
}

/// D45: listening alongside the Dexcom app. Nothing to pair: wait until the Dexcom app's connection
/// brings a sensor state, then continue.
struct ListenStep: View {
    let state: OnboardingState
    let actions: OnboardingActions

    /// The sensor reported a session state through the Dexcom app's connection.
    private var isListening: Bool {
        switch state.sensorState {
        case .active, .warmingUp, .gracePeriod, .calibrationNeeded, .calibrationError, .expired: return true
        case .notPaired, .searching, .connecting, .authenticating, .bluetoothUnavailable, .error, .failed: return false
        }
    }

    /// What stops readings right now, in words for listening (S5).
    private var problem: String? {
        switch state.sensorState {
        case .failed(let failure): return ListenModeRules.failure(failure, listening: true)?.detail ?? failure.message
        case .error(_, let description): return description
        case .bluetoothUnavailable(.poweredOff): return "Bluetooth is off, so this app can't hear the sensor. Turn it on in Control Center or Settings."
        case .bluetoothUnavailable(.unauthorized): return "Bluetooth isn't allowed for this app, so it can't hear the sensor. Allow it in iOS Settings."
        case .bluetoothUnavailable(.unsupported): return "This device doesn't support Bluetooth Low Energy, so it can't hear the sensor."
        case .bluetoothUnavailable(.resetting): return "Bluetooth is restarting; listening resumes when it's back."
        default: return nil
        }
    }

    var body: some View {
        StepTitle(title: "Listening", lead: "Keep the Dexcom app installed: it stays the sensor's connection, and this app reads along.")
        ListeningStatusLine()
        if isListening {
            Text(verbatim: ConnectionModeText.onboardingListening).font(Typography.body(size: 14)).fixedSize(horizontal: false, vertical: true)
        } else {
            if let problem {
                FieldMessage(text: problem)
                    .accessibilityIdentifier("onboarding.listen.problem")
            }
            HStack(spacing: 10) {
                ProgressView().accessibilityHidden(true)
                Text(verbatim: ConnectionModeText.onboardingWaiting)
                    .font(Typography.body(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
        ExplanationNote(text: ConnectionModeText.outputsOffWhileListening + ": Trio handoff, Nightscout and Dexcom Share upload. The Dexcom app keeps its own sharing.")
        // Nothing to do here but wait, and the app keeps listening in the background: Continue is
        // always offered (the primary action once the sensor is heard).
        if isListening {
            Button("Continue", action: next).buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("onboarding.listen.continue")
        } else {
            Button("Continue", action: next).buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("onboarding.listen.continue")
        }
    }

    private func next() {
        actions.goTo(state.step(after: .listen) ?? .warmUp)
    }
}

struct PairingStep: View {
    let state: OnboardingState
    let actions: OnboardingActions
    var context: PairingContext = .newPairing

    var body: some View {
        StepTitle(title: "Pair your sensor", lead: "Apply the sensor first. iOS will ask to pair with it; tap Pair.")
        Text(verbatim: OnboardingState.otherG7AppsWarning)
            .font(Typography.body(size: 12))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
        switch state.pairing {
        case .idle:
            PairingCodeEntry(pair: actions.submitPairingCode)
        case .couldNotStart(let message):
            FieldMessage(text: message)
            PairingCodeEntry(pair: actions.submitPairingCode)
        case .inProgress:
            HStack(spacing: 10) {
                ProgressView().accessibilityHidden(true)
                Text(verbatim: "Waiting for the sensor… It connects about every 5 minutes. Accept the iOS pairing prompt when it appears.")
                    .font(Typography.body(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: OnboardingText.pairingFailureTitle(failure))
                    .font(Typography.body(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.alert)
                FieldMessage(text: failure.message)
            }
            .accessibilityElement(children: .combine)
            // Review M1 / minor 6: the recovery depends on the kind — pair the worn sensor again,
            // accept the iOS prompt, or pair a new sensor. Never a dead end.
            PairingOfferView(offer: PairingGuidance.recovery(for: failure, context: context),
                             pair: actions.submitPairingCode, pairAgain: actions.pairAgain)
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
            .accessibilityIdentifier("onboarding.done")
    }
}
