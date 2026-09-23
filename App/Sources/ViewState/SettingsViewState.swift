// The Settings screen (HANDOFF §7.3.4, §8A, §11 step 6, PROGRESS D4/D7/D17). Secrets (Nightscout
// token, Share password) never appear here: only whether one is saved. They go to the Keychain
// through SettingsActions.

import Foundation
import GlucoseCore
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
}

struct SensorSettings: Equatable, Sendable {
    var state: SensorState
    /// Serial of the paired sensor, if known.
    var serial: String?
}

struct TrioSettings: Equatable, Sendable {
    var isEnabled: Bool
    var status: TrioStatus
}

struct NightscoutSettings: Equatable, Sendable {
    /// Site URL, e.g. "https://example.herokuapp.com". Empty if not set.
    var url: String
    /// Whether an access token is stored (the token itself stays in the Keychain).
    var hasToken: Bool
    var uploadEnabled: Bool
    var status: UploadStatus
}

/// Dexcom Share regions (xDrip4iOS Share uploader: US vs. outside-US servers).
enum ShareRegion: String, CaseIterable, Identifiable, Sendable {
    case us
    case outsideUS

    /// PROGRESS D7: US preselected.
    static let `default`: ShareRegion = .us

    var id: String { rawValue }
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
}

/// Settings → Alert delivery (PROGRESS D17).
struct AlertDeliveryStatus: Equatable, Sendable {
    var notifications: NotificationPermission
    var criticalAlerts: CriticalAlertsStatus
    var alarmVolume: AlarmVolumeStatus
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

/// How long readings are kept (HANDOFF §4.5: default 2 years).
enum DataRetention: String, CaseIterable, Identifiable, Sendable {
    case ninetyDays
    case oneYear
    case twoYears
    case forever

    static let `default`: DataRetention = .twoYears

    var id: String { rawValue }
    var label: String {
        switch self {
        case .ninetyDays: return "90 days"
        case .oneYear: return "1 year"
        case .twoYears: return "2 years"
        case .forever: return "Forever"
        }
    }
}

enum SettingsText {
    static func databaseSize(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

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
