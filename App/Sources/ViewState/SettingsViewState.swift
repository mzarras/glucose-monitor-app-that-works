// The Settings screen (HANDOFF §7.3.4, §8A, §11 step 6, PROGRESS D4/D7/D17/D20). Built by
// `SettingsMapping` from the `AppServices` summaries. Secrets (Nightscout token, Share password)
// never appear here: only whether one is saved. They go to the Keychain through SettingsActions.

import Foundation
import GlucoseCore
import GlucoseStore
import SwiftUI
import WidgetCore

struct SettingsViewState: Equatable, Sendable {
    var sensor: SensorSettings
    var trio: TrioSettings
    var nightscout: NightscoutSettings
    var dexcomShare: DexcomShareSettings
    var delivery: AlertDeliveryStatus
    /// Summary of the last history import, if any (HANDOFF §4.5).
    var lastImport: ImportSummary?
    var accent: AccentChoice
    /// Light/dark: follow the system (default) or force one. Widgets always follow the system.
    var appearance: AppearancePreference
    var unit: GlucoseUnit
    var retention: DataRetention
    /// Size of the SQLite database in bytes, nil if unknown.
    var databaseSizeBytes: Int64?
    /// "0.1.0 (1)"
    var appVersion: String
    /// Readings stored, from every source; nil until known.
    var readingCount: Int? = nil
    /// Whether the database is open (S5).
    var storageAvailability: StoreAvailability = .open
    /// A history import running now (Settings › Import history shows its progress).
    var runningImport: ImportProgress? = nil
    /// Result lines after actions (saving sharing settings, pairing, exports).
    var feedback = SettingsFeedback()
    /// DEBUG builds only: the replay controls (D11, D20). Always nil in Release.
    var debug: DebugSettings? = nil
    /// D45: listen alongside the Dexcom app or pair this app (the facade's `connectionMode`; nil
    /// only for a fixture without it).
    var connection: ConnectionModeState? = nil
    /// D45: a switch to this mode is on its way (the choices wait for it).
    var connectionSwitchingTo: SensorConnectionMode? = nil
    /// `AppServices.connectionSettingProblem`: why Settings › Sensor asks for the choice again.
    var connectionSettingProblem: String? = nil
    /// D47: Settings › Diagnostics "Record raw glucose packets" (`recordsRawGlucosePackets`).
    var packetRecording: PacketRecordingState? = nil
    /// D57: Settings › Predictions (the Zen Predict feed host and switch, last update).
    var predictions = PredictionsSettings.notConfigured

    /// D45: listening forces the Trio handoff and uploads off, and hides pairing-only actions.
    var isListening: Bool { connection?.isListening == true }

    /// D55: the compact notice at the top of Settings while the alarm volume is too low, nil
    /// otherwise. Computed from `delivery`, which `AppModel` rebuilds on every `.alertDelivery`
    /// change, so it clears as soon as the volume goes up: nothing to dismiss, no relaunch.
    var alarmVolumeNotice: String? { SettingsText.alarmVolumeNotice(delivery.alarmVolume) }

    /// D55: the "Alarm volume" row's red value. From the volume alone, never from
    /// `needsAttention`, so no other cause of the tab's dot can colour this row (p5-nav review m1).
    var alarmVolumeIsTooLow: Bool { alarmVolumeNotice != nil }

    /// Why the Settings tab shows its red dot, by name. Each cause has its own row; none colours
    /// another. Predictions add none: a forecast problem is not a safety problem (D57).
    var attentionCauses: Set<SettingsAttentionCause> {
        var causes: Set<SettingsAttentionCause> = []
        if alarmVolumeIsTooLow { causes.insert(.alarmVolumeTooLow) }
        return causes
    }

    /// D55: the Settings tab's red dot (`TabAttention`): any named cause.
    var needsAttention: Bool { !attentionCauses.isEmpty }
}

/// A reason for the Settings tab's red dot (D55).
enum SettingsAttentionCause: Hashable, Sendable, CaseIterable {
    /// The alarm volume is below `AlertLimits.lowAlarmVolume`: the notice at the top of Settings and
    /// the red "Alarm volume" row.
    case alarmVolumeTooLow
}

/// What happened after a Settings action, for the page that started it. Nil = nothing to say.
struct SettingsFeedback: Equatable, Sendable {
    var nightscout: String?
    var dexcomShare: String?
    var pairing: String?
    var export: String?
    /// D45: why the connection mode didn't change (`ConnectionModeText.errorText`).
    var connection: String?
    /// D57: why the feed host was refused (`ForecastEndpointError.description`), or "Saved.".
    var predictions: String?
}

/// DEBUG builds: replay a ReplayKit scenario in the running app (PROGRESS D11, D19, D20).
struct DebugSettings: Equatable, Sendable {
    var availableScenarios: [String]
    var activeScenario: String?
    var speed: Double?
    /// D20: let the Trio bridge and uploaders run in this DEBUG build (they still refuse every
    /// non-sensor reading, S6).
    var developerLiveOutputsEnabled: Bool

    /// Replay speeds offered: scenario seconds per real second.
    static let speeds: [Double] = [1, 10, 60, 300]
}

struct SensorSettings: Equatable, Sendable {
    var state: SensorState
    /// Serial of the paired sensor, if known.
    var serial: String?
    /// When the current `.failed` state began (Phase 2 fills it); used to offer "Pair again" for a
    /// `credentialsUnavailable` that persists (`PairingGuidance.credentialsRetryWindow`).
    var failureSince: Date? = nil
    /// Whether the source can stop a session (G7: no — the row is hidden).
    var canStopSession: Bool = false
    /// The authenticated session, nil when none is valid (D28).
    var session: SensorSession? = nil
    /// iOS Bluetooth permission for this app.
    var bluetooth: BluetoothAuthorization = .notDetermined
    /// A pairing request is on its way to the sensor (code accepted by the app, sensor not yet
    /// connected).
    var pairingInProgress: Bool = false
    /// Review M1: `state` is the source's, not the facade's launch default; while false nothing
    /// offers to pair.
    var stateKnown: Bool = true

    /// `.notPaired` before the source has reported: say so instead of offering to pair.
    var isWaitingForFirstState: Bool { !stateKnown && state == .notPaired }
}

struct TrioSettings: Equatable, Sendable {
    var isEnabled: Bool
    var status: TrioStatus
    /// Info.plist `TrioAppGroupID`, to compare with Trio's App Group (`SettingsText.trioAppGroupHelp`).
    var appGroupID: String? = nil
    /// Last time Trio's App Group was brought up to date, and how many readings that write held.
    var lastWriteAt: Date? = nil
    var readingsInLastWrite: Int = 0
    /// Newest reading Trio has from this app.
    var newestReadingWrittenAt: Date? = nil
    var heartbeatPublished: Bool = false
    var heartbeatError: String? = nil
    /// DEBUG builds keep the bridge off unless the developer switch is on (D20).
    var pausedInDebugBuild: Bool = false
    /// The bridge is on but can't run in this build (e.g. no Trio App Group), and why.
    var unavailableReason: String? = nil
    /// Readings held back at launch until Trio's App Group is re-seeded, and since when (never
    /// written older than Trio's newest).
    var heldBackReadings: Int = 0
    var heldBackSince: Date? = nil
}

struct NightscoutSettings: Equatable, Sendable {
    /// Site URL, e.g. "https://example.herokuapp.com". Empty if not set.
    var url: String
    /// Whether an access token is stored (the token itself stays in the Keychain).
    var hasToken: Bool
    var uploadEnabled: Bool
    var status: UploadStatus
    /// Readings waiting to be uploaded.
    var queueDepth: Int = 0
    /// DEBUG builds keep uploaders off unless the developer switch is on (D20).
    var pausedInDebugBuild: Bool = false
}

/// Dexcom Share regions (xDrip4iOS Share uploader: US vs. outside-US servers): the facade's type.
typealias ShareRegion = DexcomShareRegion

extension DexcomShareRegion {
    /// PROGRESS D7: US preselected.
    static let `default`: DexcomShareRegion = .us

    var label: String {
        switch self {
        case .us: return "United States"
        case .outsideUS: return "Outside the US"
        }
    }
}

struct DexcomShareSettings: Equatable, Sendable {
    var isEnabled: Bool
    var username: String
    /// Whether a password is stored (Keychain).
    var hasPassword: Bool
    var region: ShareRegion
    var status: UploadStatus
    /// The receiver/upload serial number assigned to the Dexcom account (docs/following.md) — not
    /// the G7 pairing code. Empty if not set.
    var receiverSerialNumber: String = ""
    var queueDepth: Int = 0
    var pausedInDebugBuild: Bool = false
}

/// Settings → Alert delivery (PROGRESS D17).
struct AlertDeliveryStatus: Equatable, Sendable {
    var notifications: NotificationPermission
    /// D26: urgent low as a system alarm (iOS 26+).
    var urgentLowAlarm: UrgentLowAlarmStatus
    var criticalAlerts: CriticalAlertsStatus
    var alarmVolume: AlarmVolumeStatus
    /// Everything else AlertEngine reports (banners, sounds, Time Sensitive, alarm scheduling).
    var issues: [DeliveryIssue] = []
}

struct ImportSummary: Equatable, Sendable {
    var origin: ImportOrigin
    var readingsImported: Int
    var covered: DateInterval?
    var finishedAt: Date
}

enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    static let `default`: AppearancePreference = .system

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// How long readings are kept (HANDOFF §4.5: default 2 years): GlucoseStore's policy.
typealias DataRetention = RetentionPolicy

extension RetentionPolicy {
    var label: String {
        switch self {
        case .days90: return "90 days"
        case .oneYear: return "1 year"
        case .twoYears: return "2 years"
        case .forever: return "Forever"
        }
    }
}

enum SettingsText {
    /// Settings › Data › Export diagnostics: exactly what the log holds (RingBufferDiagnosticLog's
    /// categories: ble, sensor, store, bridge, upload, alert, importer, app). G7Kit logs the sensor's
    /// name and serial; "Nightscout site saved" logs the host name; alert and upload lines can carry
    /// a glucose value. Modules log no passwords, tokens or pairing codes.
    static let diagnosticsContents = "Bluetooth and sensor events (with the sensor's name and serial), reading and alert decisions with their times and glucose values, Trio and upload events (with the Nightscout host name). No passwords, tokens or pairing codes. For bug reports."

    /// Settings › Trio › App Group: what to compare with Trio. Trio has no screen that shows its
    /// group; it appears only in its glucose notifications as "Group ID: …" (`AppGroupSource
    /// .sourceInfo`) with Add Glucose Source to Alarm on, and the CGM screen's "CGM address :" line
    /// (`CustomCGMOptionsView`) appears once Trio has read this app's heartbeat from the group.
    static let trioAppGroupHelp = "Must be Trio’s App Group: both apps signed by the same Team ID. Trio shows it only in its glucose notifications, as “Group ID: …”, with Settings › Notifications › Trio Notifications › Add Glucose Source to Alarm on. Once the heartbeat is published, Trio’s CGM screen shows a “CGM address :” line instead of “CGM is not used as heartbeat.”"

    static func databaseSize(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "18.4 MB · 25,412 readings"
    static func database(bytes: Int64?, readings: Int?) -> String {
        guard let readings else { return databaseSize(bytes) }
        return "\(databaseSize(bytes)) · \(readings.formatted()) \(readings == 1 ? "reading" : "readings")"
    }

    /// Settings › Data line when the database isn't open (S5), nil when it is.
    static func storageProblem(_ availability: StoreAvailability) -> String? {
        switch availability {
        case .open: return nil
        case .opening: return "Opening the reading database…"
        case .waitingForFirstUnlock(let held):
            return "The database opens after the first unlock since the phone restarted. \(held) \(held == 1 ? "reading is" : "readings are") held until then."
        case .failed(let message):
            // D42: history isn't being saved, but live readings still reach alerts and Trio.
            return "History isn't being saved: \(message) Alerts and Trio still get new readings; charts, statistics and uploads catch up once it recovers."
        }
    }

    /// Trio row details: "Last write 12:35 · 1 reading · newest 12:35".
    static func trioLastWrite(_ trio: TrioSettings, context: DisplayContext = .current) -> String {
        guard let last = trio.lastWriteAt else { return "No write yet" }
        var parts = ["Last write \(TimeText.time(last, context))", "\(trio.readingsInLastWrite) \(trio.readingsInLastWrite == 1 ? "reading" : "readings")"]
        if let newest = trio.newestReadingWrittenAt { parts.append("newest \(TimeText.time(newest, context))") }
        return parts.joined(separator: " · ")
    }

    /// Settings › Alert delivery line for a delivery problem not shown elsewhere on that page.
    static func deliveryIssue(_ issue: DeliveryIssue) -> String? {
        switch issue {
        case .notificationsNotRequested, .urgentLowAlarmNotRequested:
            return nil // the page's own rows offer "Allow"
        case .notificationAlertsOff:
            return "Banners are off for this app: alerts arrive silently in Notification Center."
        case .notificationSoundsOff:
            return "Notification sounds are off for this app."
        case .timeSensitiveOff:
            return "Time Sensitive is off: Focus and summaries can hold alerts back."
        case .urgentLowAlarmFailed(let message):
            return "The urgent low alarm couldn't be scheduled (\(message)); urgent low uses a notification and the in-app sound instead."
        case .repeatsNotScheduled(let alert, let missing):
            return "\(alert): \(missing) \(missing == 1 ? "repeat" : "repeats") fewer than planned while the app is in the background."
        }
    }

    /// Settings › Trio, while readings wait for the launch re-seed: "3 readings held back since
    /// 12:35 PM, until Trio's App Group is brought up to date". Nil when none are held.
    static func trioHeldBack(_ trio: TrioSettings, context: DisplayContext = .current) -> String? {
        guard trio.heldBackReadings > 0 else { return nil }
        let count = trio.heldBackReadings == 1 ? "1 reading" : "\(trio.heldBackReadings) readings"
        let since = trio.heldBackSince.map { " since \(TimeText.time($0, context))" } ?? ""
        return "\(count) held back\(since), until Trio's App Group is brought up to date."
    }

    /// DEBUG builds keep the Trio bridge and uploaders off unless the developer switch is on (D20).
    static let pausedInDebugBuild = "Paused: this is a DEBUG build. Turn on Settings › Developer › Live outputs to use it (it still accepts only live sensor readings)."

    static func notifications(_ permission: NotificationPermission) -> (status: String, note: String?) {
        switch permission {
        case .authorized: return ("Allowed", nil)
        case .provisional: return ("Quiet only", "Alerts are delivered silently. Turn on alerts, sounds and Lock Screen in iOS Settings.")
        case .denied: return ("Off", "Alerts can't reach you. Turn on notifications for this app in iOS Settings.")
        case .notDetermined: return ("Not asked yet", "You'll be asked when alerts are set up.")
        }
    }

    /// Critical Alerts, framed as optional (PROGRESS D17).
    static func criticalAlerts(_ status: CriticalAlertsStatus) -> (status: String, note: String) {
        let optional = "Optional. Needs an Apple entitlement; not required — alarms sound on silent while the app is running."
        switch status {
        case .active:
            return ("On", "Urgent alerts also break through silent mode and Focus when the app isn't running.")
        case .entitlementNotGranted:
            return ("Not available", optional + " If Apple grants the entitlement, switch SENSOR_APP_ENTITLEMENTS (see docs/setup.md) and rebuild.")
        case .disabledByUser:
            return ("Off", optional + " To turn it on: iOS Settings › Notifications › this app › Critical Alerts.")
        }
    }

    /// Urgent low alarm (PROGRESS D26).
    static func urgentLowAlarm(_ status: UrgentLowAlarmStatus) -> (status: String, note: String) {
        switch status {
        case .authorized:
            return ("On", "Urgent low rings as a system alarm, even on silent, in Focus, and while the app is in the background.")
        case .denied:
            return ("Off", "Alarms aren't allowed, so urgent low can't ring as a system alarm while the app is in the background. To fix: open iOS Settings for this app and allow Alarms.")
        case .notDetermined:
            return ("Not set up", "You'll be asked to allow alarms so urgent low can ring even on silent.")
        case .unavailable:
            return ("Not available", "Needs iOS 26 or later. On this iOS, urgent low uses a Time Sensitive notification and rings on silent while the app is running.")
        }
    }

    /// D55: "Alarm volume 15%. Alarms may be hard to hear; turn the volume up." while the volume is
    /// below `AlertLimits.lowAlarmVolume` (`.tooLow`, ServiceHealthMapping.alarmVolume); nil when it
    /// is fine or not known yet.
    static func alarmVolumeNotice(_ status: AlarmVolumeStatus) -> String? {
        guard case .tooLow(let level) = status else { return nil }
        return "Alarm volume \(Int((level * 100).rounded()))%. Alarms may be hard to hear; turn the volume up."
    }

    static func alarmVolume(_ status: AlarmVolumeStatus) -> String {
        switch status {
        case .unknown: return "—"
        case .ok(let level): return "\(Int((level * 100).rounded()))%"
        case .tooLow(let level): return "\(Int((level * 100).rounded()))% — too low"
        }
    }
}

extension AppearancePreference {
    /// For `.preferredColorScheme`: nil follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
