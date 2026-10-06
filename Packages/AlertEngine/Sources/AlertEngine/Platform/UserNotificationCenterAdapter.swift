// iOS: AlertNotificationCenter on top of UNUserNotificationCenter. A field-by-field translation of
// NotificationRequestSpec; every decision was made (and tested) before this point.

#if os(iOS)
import Foundation
import UserNotifications

@MainActor
public final class UserNotificationCenterAdapter: AlertNotificationCenter {
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func registerCategories() async {
        let acknowledge = UNNotificationAction(identifier: AlertNotificationIDs.acknowledgeAction, title: "Acknowledge", options: [])
        let snooze = UNNotificationAction(identifier: AlertNotificationIDs.snoozeAction, title: "Snooze", options: [])
        // `.customDismissAction` makes iOS report a swipe-away, so the in-app sound can stop
        // (xDrip4iOS does the same: xDrip/Managers/Alerts/AlertManager.swift:1144-1145).
        let snoozable = UNNotificationCategory(
            identifier: AlertNotificationIDs.snoozableCategory, actions: [acknowledge, snooze],
            intentIdentifiers: [], options: [.customDismissAction]
        )
        let informational = UNNotificationCategory(
            identifier: AlertNotificationIDs.informationalCategory, actions: [],
            intentIdentifiers: [], options: [.customDismissAction]
        )
        let ours: Set<String> = [AlertNotificationIDs.snoozableCategory, AlertNotificationIDs.informationalCategory]
        var categories = await center.notificationCategories().filter { !ours.contains($0.identifier) }
        categories.insert(snoozable)
        categories.insert(informational)
        center.setNotificationCategories(categories)
    }

    public func requestAuthorization() async -> NotificationPermissionState {
        // D4: always ask for Critical Alerts. Without the entitlement iOS does not offer it and
        // `criticalAlertSetting` stays `.notSupported`. There is no authorization option for Time
        // Sensitive: it comes from the entitlement and the user's per-app setting.
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge, .criticalAlert])
        return await permissionState()
    }

    public func permissionState() async -> NotificationPermissionState {
        let settings = await center.notificationSettings()
        return NotificationPermissionState(
            authorization: Self.map(settings.authorizationStatus),
            alerts: Self.map(settings.alertSetting),
            sounds: Self.map(settings.soundSetting),
            criticalAlerts: Self.map(settings.criticalAlertSetting),
            timeSensitive: Self.map(settings.timeSensitiveSetting)
        )
    }

    public func add(_ spec: NotificationRequestSpec) async throws {
        let content = UNMutableNotificationContent()
        content.title = spec.title
        content.body = spec.body
        content.threadIdentifier = spec.threadIdentifier
        content.categoryIdentifier = spec.categoryIdentifier
        content.userInfo = spec.userInfo
        switch spec.interruption {
        case .passive: content.interruptionLevel = .passive
        case .active: content.interruptionLevel = .active
        case .timeSensitive: content.interruptionLevel = .timeSensitive
        case .critical: content.interruptionLevel = .critical
        }
        switch spec.sound {
        case .none:
            content.sound = nil
        case .named(let fileName):
            content.sound = UNNotificationSound(named: UNNotificationSoundName(fileName))
        case .critical(let fileName, let volume):
            content.sound = UNNotificationSound.criticalSoundNamed(UNNotificationSoundName(fileName), withAudioVolume: volume)
        }
        // A one-shot interval trigger (not a calendar trigger) so a time-zone change cannot move it.
        let trigger = spec.fireDate.map {
            UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0.timeIntervalSinceNow), repeats: false)
        }
        try await center.add(UNNotificationRequest(identifier: spec.identifier, content: content, trigger: trigger))
    }

    public func removePending(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    public func removeDelivered(identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// For the app's delegate: turns a `UNNotificationResponse.actionIdentifier` into the
    /// platform-neutral response kind.
    public nonisolated static func responseKind(actionIdentifier: String) -> NotificationResponseKind {
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier: return .opened
        case UNNotificationDismissActionIdentifier: return .dismissed
        default: return .action(actionIdentifier)
        }
    }

    private static func map(_ status: UNAuthorizationStatus) -> NotificationPermissionState.Authorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .denied
        }
    }

    private static func map(_ setting: UNNotificationSetting) -> NotificationPermissionState.Setting {
        switch setting {
        case .notSupported: return .notSupported
        case .disabled: return .disabled
        case .enabled: return .enabled
        @unknown default: return .disabled
        }
    }
}
#endif
