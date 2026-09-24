// Settings sub-pages: sensor (pair, pairing code, status, calibrate, stop), Trio, sharing
// (Nightscout, Dexcom Share), alert delivery, about.

import GlucoseCore
import SwiftUI
import WidgetCore

// MARK: - Sensor

struct SensorSettingsView: View {
    let sensor: SensorSettings
    let calibration: CalibrationViewState
    /// Why the last pairing request didn't start (`PairingError`), if it didn't.
    var feedback: String? = nil
    let actions: SettingsActions
    /// G7Kit `hasStoredSensor` (review N2). Chooses `pairAgain(code:)` vs `pair(code:)`; false
    /// (the safe fallback: `pair(code:)` always works) until Phase 2 passes the real value.
    var hasStoredSensor = false
    @State private var confirmingStop = false
    @State private var confirmingForget = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                PageTitle("G7 sensor")
                SettingsValueRow(title: "Status", value: SensorStatusText.row(sensor.state, now: Date()))
                if let serial = sensor.serial {
                    SettingsValueRow(title: "Serial", value: serial)
                }
                if let session = sensor.session {
                    SettingsValueRow(title: "Session", value: SensorStatusText.session(session, now: Date()))
                }
                if sensor.bluetooth == .denied || sensor.bluetooth == .restricted {
                    FieldMessage(text: "Bluetooth access isn't allowed for this app, so it can't reach the sensor. Allow it in iOS Settings.")
                    Button("Open iOS Settings", action: actions.openSystemSettings).buttonStyle(SecondaryButtonStyle())
                }
                if sensor.pairingInProgress {
                    HStack(spacing: 10) {
                        ProgressView().accessibilityHidden(true)
                        Text(verbatim: "Waiting for the sensor… It connects about every 5 minutes. Accept the iOS pairing request when it appears.")
                            .font(Typography.body(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let feedback {
                    FieldMessage(text: feedback)
                }
                calibrateRow
                if let offer = PairingGuidance.settingsOffer(for: sensor.state, failureSince: sensor.failureSince,
                                                             hasStoredSensor: hasStoredSensor, now: Date()) {
                    if case .failed(let failure) = sensor.state {
                        FieldMessage(text: failure.message)
                    }
                    PairingOfferView(offer: offer, pair: actions.pair, pairAgain: actions.pairAgain)
                } else if sensor.canStopSession {
                    // G7 sensors can't be stopped from the phone (`AppServices.canStopSession`).
                    Button("Stop sensor session") { confirmingStop = true }
                        .buttonStyle(SecondaryButtonStyle())
                        .confirmationDialog("Stop this sensor session?", isPresented: $confirmingStop, titleVisibility: .visible) {
                            Button("Stop session", role: .destructive, action: actions.stopSession)
                        } message: {
                            Text("The sensor stops sending readings for good. Trio and followers get no new readings until a new sensor is paired.")
                        }
                }
                if sensor.state != .notPaired {
                    Hairline()
                    Button("Forget this sensor") { confirmingForget = true }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("settings.sensor.forget")
                        .confirmationDialog("Forget this sensor?", isPresented: $confirmingForget, titleVisibility: .visible) {
                            Button("Forget sensor", role: .destructive, action: actions.forgetSensor)
                        } message: {
                            Text("Deletes its pairing from this app. Readings stop until a sensor is paired again; Trio stops getting readings from this app.")
                        }
                }
            }
            .padding(.horizontal, Layout.sideMargin)
            .padding(.vertical, 12)
        }
    }

    private var calibrateRow: some View {
        let availability = CalibrationRules.availability(calibration, now: Date())
        return VStack(alignment: .leading, spacing: 6) {
            Button("Calibrate with a fingerstick…", action: actions.openCalibration)
                .buttonStyle(SecondaryButtonStyle())
                .disabled(availability != .available)
            if case .unavailable(let reason) = availability {
                Text(verbatim: reason).font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
            }
            if let submission = calibration.lastSubmission {
                let text = CalibrationRules.outcomeText(submission.outcome, state: calibration, now: Date())
                Text(verbatim: "Last calibration \(submission.request.mgdl) mg/dL at \(TimeText.time(submission.request.takenAt)): \(text.title.lowercased()).")
                    .font(Typography.body(size: 12))
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}

/// The pairing recovery for a failure (PairingGuidance): numbered steps and a code entry wired
/// to the call the recovery names — `pair(code:)` or `pairAgain(code:)` (review N2).
struct PairingOfferView: View {
    let offer: PairingRecovery
    let pair: @MainActor (String) -> Void
    let pairAgain: @MainActor (String) -> Void

    var body: some View {
        switch offer {
        case .enterCode(let steps, let buttonTitle, let action):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if steps.count > 1 {
                            Text(verbatim: "\(index + 1).").font(Typography.label(size: 12, medium: true))
                        }
                        Text(verbatim: step).font(Typography.body(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                PairingCodeEntry(buttonTitle: buttonTitle, showsIntro: steps.isEmpty, pair: action == .pairAgain ? pairAgain : pair)
            }
        case .acceptBluetoothPrompt(let instruction):
            Text(verbatim: instruction)
                .font(Typography.body(size: 14))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 4-digit pairing code entry (HANDOFF §4.6). Also used in onboarding.
struct PairingCodeEntry: View {
    var buttonTitle = "Pair sensor"
    /// The "enter the code / remove the Dexcom app" paragraph; off where steps are listed above.
    var showsIntro = true
    let pair: @MainActor (String) -> Void
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("PAIRING CODE")
            if showsIntro {
                Text(verbatim: "Enter the 4-digit code printed on the sensor applicator. Remove the Dexcom app from this phone first: only one app can be the sensor's primary device.")
                    .font(Typography.body(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(text: Binding(get: { code }, set: { code = PairingCode.sanitize($0) })) {
                Text(verbatim: "0000")
            }
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .font(Typography.figure(size: 36))
            .tracking(8)
            .frame(minHeight: 56)
            .padding(.horizontal, 12)
            .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1))
            .accessibilityLabel(Text("Pairing code, 4 digits"))
            Button(buttonTitle) { pair(code) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!PairingCode.isComplete(code))
        }
    }
}

// MARK: - Trio

struct TrioSettingsView: View {
    let trio: TrioSettings
    let setEnabled: @MainActor (Bool) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                PageTitle("Trio handoff")
                Toggle(isOn: Binding(get: { trio.isEnabled }, set: { setEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "Hand readings to Trio").font(Typography.body(size: 15, weight: .medium))
                        Text(verbatim: "Writes each valid sensor reading to Trio's App Group. In Trio, choose xDrip4iOS as the CGM source.")
                            .font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
                .frame(minHeight: Layout.minTarget)
                .accessibilityIdentifier("settings.trio.toggle")
                Hairline()
                if trio.pausedInDebugBuild {
                    WarningNote(text: SettingsText.pausedInDebugBuild)
                }
                SettingsValueRow(title: "Status", value: TrioStatusText.row(trio.status))
                if case .failing(let since, let message) = trio.status {
                    WarningNote(text: "Failing since \(TimeText.time(since)): \(message)")
                }
                if trio.isEnabled {
                    SettingsValueRow(title: "Last write", value: SettingsText.trioLastWrite(trio))
                    SettingsValueRow(title: "Heartbeat", value: trio.heartbeatPublished ? "published" : "not published")
                    if let error = trio.heartbeatError {
                        WarningNote(text: "Trio's heartbeat couldn't be written: \(error). Trio may not loop in the background.")
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    SettingsValueRow(title: "App Group", value: trio.appGroupID ?? "missing from this build")
                    Text(verbatim: "Must match Trio's Settings › App Info › Group ID. Both apps need the same Team ID.")
                        .font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.trio.appGroup")
                Text(verbatim: "Only live sensor readings are handed over. Imported history never is. LOW is sent as 39 and HIGH as 401, Trio's own LOW/HIGH values.")
                    .font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Layout.sideMargin)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Sharing

struct SharingSettingsView: View {
    let nightscout: NightscoutSettings
    let share: DexcomShareSettings
    var feedback = SettingsFeedback()
    let actions: SettingsActions
    @State private var url = ""
    @State private var token = ""
    @State private var username = ""
    @State private var password = ""
    @State private var receiverSerial = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                PageTitle("Sharing")
                nightscoutSection
                shareSection
                if nightscout.uploadEnabled || share.isEnabled {
                    Button("Retry uploads now", action: actions.retryUploads)
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.horizontal, Layout.sideMargin)
            .padding(.vertical, 12)
        }
        .onAppear {
            url = nightscout.url
            username = share.username
            receiverSerial = share.receiverSerialNumber
        }
    }

    private var nightscoutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("NIGHTSCOUT")
            LabeledField(label: "Site URL") {
                TextField(text: $url) { Text(verbatim: "https://your-site.example.com") }
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            LabeledField(label: "Access token") {
                SecureField(text: $token) { Text(verbatim: nightscout.hasToken ? "Saved — type to replace" : "Token with read and write") }
            }
            Button("Save") { actions.saveNightscout(url, token.isEmpty ? nil : token); token = "" }
                .buttonStyle(SecondaryButtonStyle())
            if let message = feedback.nightscout {
                Text(verbatim: message).font(Typography.body(size: 13)).foregroundStyle(message == "Saved." ? AnyShapeStyle(Theme.muted) : AnyShapeStyle(Theme.alert))
            }
            Toggle(isOn: Binding(get: { nightscout.uploadEnabled }, set: { actions.setNightscoutUpload($0) })) {
                Text(verbatim: "Upload readings").font(Typography.body(size: 15, weight: .medium))
            }
            .frame(minHeight: Layout.minTarget)
            if nightscout.pausedInDebugBuild {
                WarningNote(text: SettingsText.pausedInDebugBuild)
            }
            SettingsValueRow(title: "Status", value: UploadStatusText.row(nightscout.status))
            uploadProblem(nightscout.status)
            if nightscout.queueDepth > 0 {
                SettingsValueRow(title: "Waiting to upload", value: "\(nightscout.queueDepth)")
            }
            Text(verbatim: "Followers use your Nightscout site or a follower app; LoopFollow is the one that alarms on LOW. Turn off Trio's own CGM upload so each reading is uploaded once.")
                .font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shareSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("DEXCOM SHARE")
            Toggle(isOn: Binding(get: { share.isEnabled }, set: { actions.setShareEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Upload to Dexcom Share").font(Typography.body(size: 15, weight: .medium))
                    Text(verbatim: "Keeps Dexcom Follow working after the Dexcom app is removed. Unofficial: it may stop working if Dexcom changes its service.")
                        .font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            .frame(minHeight: Layout.minTarget)
            Picker(selection: Binding(get: { share.region }, set: { actions.setShareRegion($0) })) {
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
                SecureField(text: $password) { Text(verbatim: share.hasPassword ? "Saved — type to replace" : "Password") }
                    .textContentType(.password)
            }
            LabeledField(label: "Receiver serial number") {
                TextField(text: $receiverSerial) { Text(verbatim: "From the Dexcom account, not the sensor code") }
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
            Button("Save") { actions.saveShareCredentials(username, password.isEmpty ? nil : password, receiverSerial); password = "" }
                .buttonStyle(SecondaryButtonStyle())
            if let message = feedback.dexcomShare {
                Text(verbatim: message).font(Typography.body(size: 13)).foregroundStyle(message == "Saved." ? AnyShapeStyle(Theme.muted) : AnyShapeStyle(Theme.alert))
            }
            if share.pausedInDebugBuild {
                WarningNote(text: SettingsText.pausedInDebugBuild)
            }
            SettingsValueRow(title: "Status", value: UploadStatusText.row(share.status))
            uploadProblem(share.status)
            Text(verbatim: "LOW is sent as 39 and HIGH as 401 (not yet confirmed with a Dexcom Follow user). A wrong password is retried only every 30 minutes, so the account isn't locked; saving retries at once.")
                .font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func uploadProblem(_ status: UploadStatus) -> some View {
        switch status {
        case .failing(_, let error, _): WarningNote(text: error)
        case .notSetUp(let missing): WarningNote(text: "Upload is on but not set up. \(missing)")
        case .off, .ok: EmptyView()
        }
    }
}

struct LabeledField<Field: View>: View {
    let label: String
    @ViewBuilder let field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: label.uppercased()).monoLabel(size: 10).foregroundStyle(Theme.muted)
            field
                .font(Typography.body(size: 15))
                .frame(minHeight: Layout.minTarget)
                .padding(.horizontal, 10)
                .overlay(Rectangle().stroke(Theme.rule, lineWidth: 1))
        }
    }
}

// MARK: - Alert delivery

struct AlertDeliveryView: View {
    let delivery: AlertDeliveryStatus
    let actions: SettingsActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                PageTitle("Alert delivery")
                let notifications = SettingsText.notifications(delivery.notifications)
                statusBlock(title: "Notifications", status: notifications.status, note: notifications.note,
                            isProblem: delivery.notifications != .authorized)
                switch delivery.notifications {
                case .notDetermined:
                    Button("Allow notifications", action: actions.requestNotifications).buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("settings.delivery.allowNotifications")
                case .denied, .provisional:
                    Button("Open iOS Settings", action: actions.openSystemSettings).buttonStyle(SecondaryButtonStyle())
                case .authorized:
                    EmptyView()
                }
                ForEach(Array(delivery.issues.enumerated()), id: \.offset) { _, issue in
                    if let text = SettingsText.deliveryIssue(issue) { WarningNote(text: text) }
                }
                Hairline()
                let alarm = SettingsText.urgentLowAlarm(delivery.urgentLowAlarm)
                statusBlock(title: "Urgent low alarm", status: alarm.status, note: alarm.note, isProblem: delivery.urgentLowAlarm == .denied)
                switch delivery.urgentLowAlarm {
                case .notDetermined:
                    Button("Allow alarms", action: actions.requestUrgentLowAlarm).buttonStyle(PrimaryButtonStyle())
                case .denied:
                    Button("Open iOS Settings", action: actions.openSystemSettings).buttonStyle(SecondaryButtonStyle())
                case .authorized, .unavailable:
                    EmptyView()
                }
                Hairline()
                statusBlock(title: "Alarm volume", status: SettingsText.alarmVolume(delivery.alarmVolume),
                            note: "Alarms play at the phone's volume while the app is running, even on silent.",
                            isProblem: { if case .tooLow = delivery.alarmVolume { return true } else { return false } }())
                Hairline()
                let critical = SettingsText.criticalAlerts(delivery.criticalAlerts)
                statusBlock(title: "Critical Alerts", status: critical.status, note: critical.note, isProblem: false)
            }
            .padding(.horizontal, Layout.sideMargin)
            .padding(.vertical, 12)
        }
        .onAppear { actions.refreshStatus() }
    }

    private func statusBlock(title: String, status: String, note: String?, isProblem: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AdaptiveRow {
                Text(verbatim: title).font(Typography.body(size: 15, weight: .medium))
            } trailing: {
                Text(verbatim: status)
                    .font(Typography.label(size: 12, medium: true))
                    .foregroundStyle(isProblem ? AnyShapeStyle(Theme.alert) : AnyShapeStyle(Theme.ink))
            }
            if let note {
                Text(verbatim: note)
                    .font(Typography.body(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - About

struct AboutView: View {
    let version: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                PageTitle(AppIdentity.displayName)
                Text(verbatim: "Version \(version). Free software under the GNU General Public License v3.0. Build-from-source only. Not for treatment decisions without a fingerstick check when readings don't match symptoms.")
                    .font(Typography.body(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                SectionLabel("CODE INCLUDED IN THIS APP")
                credits(Credits.included)
                SectionLabel("REFERENCES (NO CODE INCLUDED)")
                credits(Credits.references)
                SectionLabel("FONT LICENSES")
                Text(verbatim: "Newsreader (Production Type), IBM Plex Sans and IBM Plex Mono (IBM; Reserved Font Name \"Plex\"), SIL Open Font License 1.1.")
                    .font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                LicenseText(fileName: "Newsreader-OFL")
                LicenseText(fileName: "IBMPlex-OFL")
                Text(verbatim: Credits.sounds)
                    .font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "Trio is integrated through its App Group contract only; no Trio code is included. \"Dexcom\" and \"G7\" are trademarks of Dexcom, Inc. This project is not affiliated with or endorsed by Dexcom.")
                    .font(Typography.body(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Layout.sideMargin)
            .padding(.vertical, 12)
        }
    }

    private func credits(_ list: [Credits.Entry]) -> some View {
        ForEach(list, id: \.name) { entry in
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: entry.name).font(Typography.body(size: 14, weight: .medium))
                    Spacer()
                    Text(verbatim: entry.license).font(Typography.label(size: 10)).foregroundStyle(Theme.muted)
                }
                Text(verbatim: entry.use).font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Hairline()
        }
    }
}

/// NOTICE.md in the app (HANDOFF §3): every project named there, with its licence and what it is
/// used for. `AboutCreditsTests` checks this list against NOTICE.md.
enum Credits {
    struct Entry: Equatable, Sendable {
        let name: String
        let license: String
        let use: String
    }

    static let included: [Entry] = [
        Entry(name: "xDrip4iOS", license: "GPL-3.0", use: "Release 7.1.0: G7 primary mode (pairing, J-PAKE authentication, bonding, messages, backfill, calibration, Bluetooth connection) and the Dexcom Share uploader."),
        Entry(name: "micro-ecc", license: "BSD-2-Clause", use: "P-256 arithmetic for G7 J-PAKE, vendored via xDrip4iOS."),
        Entry(name: "GRDB.swift", license: "MIT", use: "SQLite persistence."),
    ]

    static let references: [Entry] = [
        Entry(name: "LoopKit G7SensorKit", license: "MIT", use: "G7 message formats, glucose limits, captured packets used as test vectors."),
        Entry(name: "LoopKit CGMBLEKit", license: "MIT", use: "One AES challenge-hash test vector."),
        Entry(name: "Juggluco", license: "GPL-3.0", use: "G7 authentication research and client certificate constants, via xDrip4iOS."),
        Entry(name: "xDrip+", license: "GPL-3.0", use: "G7 protocol research (Android)."),
        Entry(name: "Mbed TLS", license: "Apache-2.0 OR GPL-2.0-or-later", use: "EC J-PAKE self-test vectors used as test data."),
        Entry(name: "Loop", license: "MIT", use: "Alert delivery approach: ringer-off playback, AlarmKit system alarms, stale/backfill guards."),
        Entry(name: "Nightscout cgm-remote-monitor", license: "AGPL-3.0", use: "REST API contract, authorization, entry dedupe, LOW/HIGH (39/401) conventions."),
        Entry(name: "share2nightscout-bridge", license: "GPL-3.0-only", use: "Dexcom trend-code numbering."),
        Entry(name: "LoopKit dexcom-share-client-swift", license: "MIT", use: "Dexcom Share LOW/HIGH reading convention."),
        Entry(name: "Trio", license: "AGPL-3.0", use: "App Group CGM contract and Nightscout upload settings; integrated through its App Group contract only."),
    ]

    static let sounds = "Alert sounds: original, generated by tools/sounds/generate_sounds.py (GPL-3.0); the IMA ADPCM step and index tables are from the public IMA recommended practices (1992)."
}

struct LicenseText: View {
    let fileName: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(verbatim: text)
                .font(Typography.label(size: 10))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } label: {
            Text(verbatim: fileName + ".txt").font(Typography.body(size: 14))
        }
        .frame(minHeight: Layout.minTarget)
    }

    private var text: String {
        guard let url = Bundle.main.url(forResource: fileName, withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "License file \(fileName).txt is missing from the app bundle."
        }
        return contents
    }
}

struct PageTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: text)
                .font(Typography.title(size: 30))
                .accessibilityAddTraits(.isHeader)
            Hairline()
        }
    }
}
