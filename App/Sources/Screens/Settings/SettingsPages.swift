// Settings sub-pages: sensor (pair, pairing code, status, calibrate, stop), Trio, sharing
// (Nightscout, Dexcom Share), alert delivery, about.

import GlucoseCore
import SwiftUI
import WidgetCore

// MARK: - Sensor

struct SensorSettingsView: View {
    let sensor: SensorSettings
    let calibration: CalibrationViewState
    let actions: SettingsActions
    @State private var confirmingStop = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                PageTitle("G7 sensor")
                SettingsValueRow(title: "Status", value: SensorStatusText.row(sensor.state, now: Date()))
                if let serial = sensor.serial {
                    SettingsValueRow(title: "Serial", value: serial)
                }
                calibrateRow
                if let offer = PairingGuidance.settingsOffer(for: sensor.state, failureSince: sensor.failureSince, now: Date()) {
                    if case .failed(let failure) = sensor.state {
                        FieldMessage(text: failure.message)
                    }
                    PairingOfferView(offer: offer, pairNew: actions.pair, pairAgain: actions.pairAgain)
                } else {
                    Button("Stop sensor session") { confirmingStop = true }
                        .buttonStyle(SecondaryButtonStyle())
                        .confirmationDialog("Stop this sensor session?", isPresented: $confirmingStop, titleVisibility: .visible) {
                            Button("Stop session", role: .destructive, action: actions.stopSession)
                        } message: {
                            Text("The sensor stops sending readings for good. Trio and followers get no new readings until a new sensor is paired.")
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
                let text = CalibrationRules.outcomeText(submission.outcome)
                Text(verbatim: "Last calibration \(submission.request.mgdl) mg/dL at \(TimeText.time(submission.request.takenAt)): \(text.title.lowercased()).")
                    .font(Typography.body(size: 12))
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}

/// The pairing recovery for a failure (PairingGuidance): numbered steps and the right code entry.
struct PairingOfferView: View {
    let offer: PairingRecovery
    let pairNew: @MainActor (String) -> Void
    let pairAgain: @MainActor (String) -> Void

    var body: some View {
        switch offer {
        case .pairAgain(let steps):
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("PAIR AGAIN")
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "\(index + 1).").font(Typography.label(size: 12, medium: true))
                        Text(verbatim: step).font(Typography.body(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                PairingCodeEntry(buttonTitle: "Pair again", showsIntro: false, pair: pairAgain)
            }
        case .acceptBluetoothPrompt(let instruction):
            Text(verbatim: instruction)
                .font(Typography.body(size: 14))
                .fixedSize(horizontal: false, vertical: true)
        case .pairNewSensor(let instruction):
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: instruction)
                    .font(Typography.body(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                PairingCodeEntry(buttonTitle: "Pair a new sensor", pair: pairNew)
            }
        case .retryCode:
            PairingCodeEntry(pair: pairNew)
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
                        Text(verbatim: "Writes each valid sensor reading to Trio's App Group. In Trio, choose this app as the CGM source.")
                            .font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
                .frame(minHeight: Layout.minTarget)
                Hairline()
                SettingsValueRow(title: "Status", value: TrioStatusText.row(trio.status))
                if case .failing(let since, let message) = trio.status {
                    WarningNote(text: "Failing since \(TimeText.time(since)): \(message)")
                }
                Text(verbatim: "Only live sensor readings are handed over. Imported history never is.")
                    .font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
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
    let actions: SettingsActions
    @State private var url = ""
    @State private var token = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                PageTitle("Sharing")
                nightscoutSection
                shareSection
            }
            .padding(.horizontal, Layout.sideMargin)
            .padding(.vertical, 12)
        }
        .onAppear {
            url = nightscout.url
            username = share.username
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
            Toggle(isOn: Binding(get: { nightscout.uploadEnabled }, set: { actions.setNightscoutUpload($0) })) {
                Text(verbatim: "Upload readings").font(Typography.body(size: 15, weight: .medium))
            }
            .frame(minHeight: Layout.minTarget)
            SettingsValueRow(title: "Status", value: UploadStatusText.row(nightscout.status))
            if case .failing(_, let error, _) = nightscout.status {
                WarningNote(text: error)
            }
            Text(verbatim: "Followers use your Nightscout site or a follower app. Turn off Trio's own CGM upload so each reading is uploaded once.")
                .font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
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
                SecureField(text: $password) { Text(verbatim: share.hasPassword ? "Saved — type to replace" : "Password") }
                    .textContentType(.password)
            }
            Button("Save") { actions.saveShareCredentials(username, password.isEmpty ? nil : password); password = "" }
                .buttonStyle(SecondaryButtonStyle())
            SettingsValueRow(title: "Status", value: UploadStatusText.row(share.status))
            if case .failing(_, let error, _) = share.status {
                WarningNote(text: error)
            }
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
    let openSystemSettings: @MainActor () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                PageTitle("Alert delivery")
                let notifications = SettingsText.notifications(delivery.notifications)
                statusBlock(title: "Notifications", status: notifications.status, note: notifications.note,
                            isProblem: delivery.notifications == .denied || delivery.notifications == .provisional)
                if delivery.notifications == .denied || delivery.notifications == .provisional {
                    Button("Open iOS Settings", action: openSystemSettings).buttonStyle(SecondaryButtonStyle())
                }
                Hairline()
                let alarm = SettingsText.urgentLowAlarm(delivery.urgentLowAlarm)
                statusBlock(title: "Urgent low alarm", status: alarm.status, note: alarm.note, isProblem: delivery.urgentLowAlarm == .denied)
                if delivery.urgentLowAlarm == .denied {
                    Button("Open iOS Settings", action: openSystemSettings).buttonStyle(SecondaryButtonStyle())
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

    /// Mirrors NOTICE.md (projects actually used).
    private let credits: [(String, String, String)] = [
        ("xDrip4iOS", "GPL-3.0", "G7 primary-mode Bluetooth: pairing, authentication, backfill; Dexcom Share upload"),
        ("LoopKit G7SensorKit", "MIT", "G7 message formats (reference)"),
        ("xDrip+ (Android)", "GPL-3.0", "G7 protocol research (reference)"),
        ("DiaBLE", "GPL-3.0", "G7 protocol research (reference)"),
        ("GRDB.swift", "MIT", "SQLite persistence"),
        ("Newsreader", "SIL OFL 1.1", "Display type (Production Type)"),
        ("IBM Plex Sans and Mono", "SIL OFL 1.1", "Text and label type (IBM)"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                PageTitle(AppIdentity.displayName)
                Text(verbatim: "Version \(version). Free software under the GNU General Public License v3.0. Build-from-source only. Not for treatment decisions without a fingerstick check when readings don't match symptoms.")
                    .font(Typography.body(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                SectionLabel("OPEN-SOURCE CREDITS")
                ForEach(credits, id: \.0) { name, license, use in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: name).font(Typography.body(size: 14, weight: .medium))
                            Spacer()
                            Text(verbatim: license).font(Typography.label(size: 10)).foregroundStyle(Theme.muted)
                        }
                        Text(verbatim: use).font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Hairline()
                }
                SectionLabel("FONT LICENSES")
                LicenseText(fileName: "Newsreader-OFL")
                LicenseText(fileName: "IBMPlex-OFL")
                Text(verbatim: "Trio is integrated through its App Group contract only; no Trio code is included. \"Dexcom\" and \"G7\" are trademarks of Dexcom, Inc. This project is not affiliated with or endorsed by Dexcom.")
                    .font(Typography.body(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Layout.sideMargin)
            .padding(.vertical, 12)
        }
    }
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
