// What a tap or swipe on one of our notifications means (brief item 5: Snooze / Acknowledge).

import Foundation

/// A notification response, reduced to what matters here. The iOS adapter maps
/// `UNNotificationDefaultActionIdentifier` to `.opened`, `UNNotificationDismissActionIdentifier`
/// to `.dismissed`, and anything else to `.action(identifier)`.
public enum NotificationResponseKind: Sendable, Equatable {
    case opened
    case dismissed
    case action(String)
}

public enum AlertNotificationResponse {
    /// The user action for a response to one of our notifications, or `nil` if the notification is
    /// not ours or the action is unknown.
    ///
    /// - Opening the notification or tapping Acknowledge acknowledges the alert.
    /// - Snooze snoozes for the duration carried in the notification (urgent low: the engine
    ///   clamps to ≤ 30 minutes regardless, S7).
    /// - Swiping it away only stops the in-app sound: an accidental swipe must not end repeats.
    public static func userAction(for response: NotificationResponseKind, userInfo: [AnyHashable: Any]) -> AlertUserAction? {
        guard let raw = userInfo[AlertNotificationIDs.userInfoKind] as? String, let kind = AlertKind(rawValue: raw) else {
            return nil
        }
        switch response {
        case .opened:
            return .acknowledge(kind)
        case .dismissed:
            return .silence(kind)
        case .action(AlertNotificationIDs.acknowledgeAction):
            return .acknowledge(kind)
        case .action(AlertNotificationIDs.snoozeAction):
            let stored = (userInfo[AlertNotificationIDs.userInfoSnoozeMinutes] as? String).flatMap(Int.init)
            guard let minutes = stored else { return .acknowledge(kind) }
            return .snooze(kind, minutes: minutes)
        case .action:
            return nil
        }
    }
}
