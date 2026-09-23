// What the Settings screen needs to know about whether alerts can be heard (S5: "notifications
// denied", "alarm volume too low" must surface). Platform-neutral mirror of UNNotificationSettings
// plus the media output volume.

import Foundation

public struct NotificationPermissionState: Sendable, Equatable {
    public enum Authorization: Sendable, Equatable {
        case notDetermined, denied, authorized, provisional, ephemeral
    }

    /// Mirrors `UNNotificationSetting`.
    public enum Setting: Sendable, Equatable {
        case notSupported, disabled, enabled
    }

    public var authorization: Authorization
    public var alerts: Setting
    public var sounds: Setting
    /// `.enabled` only if the build has the entitlement and the user allowed Critical Alerts.
    public var criticalAlerts: Setting
    public var timeSensitive: Setting

    public init(authorization: Authorization, alerts: Setting, sounds: Setting, criticalAlerts: Setting, timeSensitive: Setting) {
        self.authorization = authorization
        self.alerts = alerts
        self.sounds = sounds
        self.criticalAlerts = criticalAlerts
        self.timeSensitive = timeSensitive
    }

    /// Before the first check.
    public static let unknown = NotificationPermissionState(
        authorization: .notDetermined, alerts: .notSupported, sounds: .notSupported, criticalAlerts: .notSupported, timeSensitive: .notSupported
    )

    public var isAuthorized: Bool {
        switch authorization {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined, .denied: return false
        }
    }

    /// D4: critical delivery is used exactly when this is true.
    public var criticalAlertsEnabled: Bool {
        isAuthorized && criticalAlerts == .enabled
    }
}

/// A reason alerts may not be seen or heard. Each one is shown on the Settings screen (S5).
public enum DeliveryProblem: Sendable, Equatable {
    /// The permission prompt has not been answered yet.
    case notificationsNotRequested
    /// Notifications are off for this app: no alert can be delivered while the app is not open.
    case notificationsDenied
    /// Banners/alerts are off: notifications arrive silently in Notification Center only.
    case notificationAlertsOff
    /// Notification sounds are off for this app.
    case notificationSoundsOff
    /// Time Sensitive is off: Focus modes and summaries can hold alerts back.
    case timeSensitiveOff
    /// The media volume is zero: the ringer-off sound (AVAudioSession `.playback`) is inaudible.
    case alarmVolumeMuted
    /// The media volume is low (below `AlertLimits.lowAlarmVolume`).
    case alarmVolumeLow(Float)
}

public struct AlertDeliveryStatus: Sendable, Equatable {
    public var permissions: NotificationPermissionState
    /// System output (media) volume 0…1 when last read; `nil` if unknown.
    public var outputVolume: Float?

    public init(permissions: NotificationPermissionState, outputVolume: Float?) {
        self.permissions = permissions
        self.outputVolume = outputVolume
    }

    /// Problems, most serious first.
    public var problems: [DeliveryProblem] {
        var problems: [DeliveryProblem] = []
        switch permissions.authorization {
        case .notDetermined: problems.append(.notificationsNotRequested)
        case .denied: problems.append(.notificationsDenied)
        case .authorized, .provisional, .ephemeral:
            if permissions.alerts == .disabled { problems.append(.notificationAlertsOff) }
            if permissions.sounds == .disabled { problems.append(.notificationSoundsOff) }
            if permissions.timeSensitive == .disabled { problems.append(.timeSensitiveOff) }
        }
        if let volume = outputVolume {
            // A Critical Alert plays at its own volume, but the in-app sound and ordinary
            // notification sounds do not; warn either way (this is a heuristic, see AlertLimits).
            if volume <= 0.001 {
                problems.append(.alarmVolumeMuted)
            } else if volume < AlertLimits.lowAlarmVolume {
                problems.append(.alarmVolumeLow(volume))
            }
        }
        return problems
    }
}
