// Status of everything around the sensor that the UI reports on: Trio handoff, uploads,
// notification delivery, alarm volume, force-quit gaps. Phase 2 fills these from TrioBridge,
// NightscoutKit, AlertEngine and the app lifecycle. Feeds the S5 banners (AppBanners) and the
// status rows on Now and Settings.

import Foundation

/// Trio handoff through the App Group (HANDOFF §8).
enum TrioStatus: Equatable, Sendable {
    /// The bridge is turned off in Settings.
    case off
    /// Writing normally. `lastHandoff` is the last successful write, nil if none yet.
    case ok(lastHandoff: Date?)
    /// Writes are failing (or Trio is not consuming, if detectable) since `since` (S5).
    case failing(since: Date, message: String)
}

/// An uploader (Nightscout or Dexcom Share, HANDOFF §8A).
enum UploadStatus: Equatable, Sendable {
    case off
    case ok(lastUpload: Date?)
    /// Consecutive failures since `since`; `lastError` is the most recent error, human-readable.
    case failing(failureCount: Int, lastError: String, since: Date)
}

/// iOS notification authorization (`UNAuthorizationStatus`).
enum NotificationPermission: Equatable, Sendable {
    case notDetermined
    case authorized
    /// Delivered quietly to Notification Center only — alerts would not sound.
    case provisional
    case denied
}

/// Critical Alerts (HANDOFF §4.7, PROGRESS D4/D17). Optional: alarms sound on silent while the app
/// is running without it.
enum CriticalAlertsStatus: Equatable, Sendable {
    /// Entitled and allowed by the user.
    case active
    /// This build is not signed with the Apple-granted entitlement (the usual case).
    case entitlementNotGranted
    /// Entitled, but switched off in iOS Settings.
    case disabledByUser
}

/// Whether the alarm volume is loud enough (PROGRESS D17). Measured by AlertEngine.
enum AlarmVolumeStatus: Equatable, Sendable {
    case unknown
    /// `level` is the output volume, 0...1.
    case ok(level: Double)
    case tooLow(level: Double)
}

/// Readings missed because the app was force-quit (HANDOFF §4.6: iOS does not relaunch it).
struct ForceQuitGap: Equatable, Sendable {
    let from: Date
    let to: Date
}

struct ServiceHealth: Equatable, Sendable {
    var trio: TrioStatus
    var nightscout: UploadStatus
    var dexcomShare: UploadStatus
    var notifications: NotificationPermission
    var alarmVolume: AlarmVolumeStatus
    /// Set on launch when the app detects it was force-quit; cleared when the user dismisses it.
    var forceQuitGap: ForceQuitGap?

    /// Nothing configured, nothing wrong (used before Phase 2 wiring and in Release until then).
    static let unconfigured = ServiceHealth(
        trio: .off,
        nightscout: .off,
        dexcomShare: .off,
        notifications: .notDetermined,
        alarmVolume: .unknown,
        forceQuitGap: nil
    )
}
