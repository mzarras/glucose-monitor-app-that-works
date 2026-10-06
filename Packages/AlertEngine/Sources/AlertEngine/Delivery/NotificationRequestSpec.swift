// A platform-neutral description of one notification request, plus the fixed identifiers. The
// iOS adapter turns a spec into a UNNotificationRequest one field at a time; everything that
// decides *what* to post is here and unit-tested on the host.

import Foundation

public struct NotificationRequestSpec: Sendable, Equatable {
    public let identifier: String
    public let title: String
    public let body: String
    /// Groups an alert's notifications in Notification Center.
    public let threadIdentifier: String
    public let categoryIdentifier: String
    public let interruption: NotificationInterruption
    public let sound: NotificationSoundChoice
    /// `nil`: deliver now. Otherwise a one-shot trigger at this time.
    public let fireDate: Date?
    /// `AlertNotificationIDs.userInfoKind` → `AlertKind.rawValue`, and the Snooze duration.
    public let userInfo: [String: String]
}

public enum AlertNotificationIDs {
    public static let prefix = "sensor.alert."

    /// Categories (registered once by the notification adapter).
    public static let snoozableCategory = "sensor.alert.category.snoozable"
    public static let informationalCategory = "sensor.alert.category.informational"
    /// Actions.
    public static let acknowledgeAction = "sensor.alert.action.acknowledge"
    public static let snoozeAction = "sensor.alert.action.snooze"
    /// userInfo keys.
    public static let userInfoKind = "alertKind"
    public static let userInfoSnoozeMinutes = "snoozeMinutes"

    /// The notification posted immediately for `kind`. A new one replaces the old one.
    public static func immediate(_ kind: AlertKind) -> String {
        prefix + kind.rawValue
    }

    /// The pending notification in `slot` (`ScheduledRepeat.slot`, 0 ..< scheduleIDCycle) for `kind`.
    public static func scheduled(_ kind: AlertKind, slot: Int) -> String {
        prefix + kind.rawValue + ".slot\(slot)"
    }

    /// Every pending identifier `kind` could have used.
    public static func allScheduled(_ kind: AlertKind) -> [String] {
        (0..<AlertLimits.scheduleIDCycle).map { scheduled(kind, slot: $0) }
    }

    /// Every identifier this package ever uses for `kind`.
    public static func all(_ kind: AlertKind) -> [String] {
        [immediate(kind)] + allScheduled(kind)
    }

    public static func thread(_ kind: AlertKind) -> String {
        prefix + kind.rawValue
    }
}

public enum NotificationRequestBuilder {
    /// The request for `notice`, delivered as `decision` says. A notice with a `slot` is a pending
    /// repeat and gets that slot's identifier; otherwise it is the immediate notification.
    public static func request(for notice: AlertNotice, decision: DeliveryDecision) -> NotificationRequestSpec {
        let slot = notice.slot
        var userInfo = [AlertNotificationIDs.userInfoKind: notice.kind.rawValue]
        if let minutes = notice.snoozeMinutes {
            userInfo[AlertNotificationIDs.userInfoSnoozeMinutes] = String(minutes)
        }
        let identifier = slot.map { AlertNotificationIDs.scheduled(notice.kind, slot: $0) } ?? AlertNotificationIDs.immediate(notice.kind)
        return NotificationRequestSpec(
            identifier: identifier,
            title: notice.title,
            body: notice.body,
            threadIdentifier: AlertNotificationIDs.thread(notice.kind),
            categoryIdentifier: notice.snoozeMinutes == nil
                ? AlertNotificationIDs.informationalCategory
                : AlertNotificationIDs.snoozableCategory,
            interruption: decision.interruption,
            sound: decision.notificationSound,
            fireDate: notice.fireDate,
            userInfo: userInfo
        )
    }
}
