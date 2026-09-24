// The per-alert state machine's states (brief item 3). See docs/alerts.md for the diagram.
//
//   armed ──met──▶ (delaying ──delay elapsed──▶) firing ──acknowledge/snooze──▶ snoozed
//     ▲                                             │  ▲                          │
//     └──────────────── clear (recovered) ──────────┘  └── snooze over, still met ┘
//
// "Cleared" is the transition back to armed; it removes the alert's notifications.

import Foundation

public enum AlertEpisode: Sendable, Equatable, Codable {
    /// The condition is not true; the alert will fire when it becomes true.
    case armed
    /// High only: the condition is true, waiting out "fire only after N min above".
    case delaying(since: Date)
    /// The alert has sounded and has not been acknowledged.
    case firing(AlertFiring)
    /// Acknowledged or snoozed. It sounds again at `until` if the condition is still true.
    case snoozed(AlertSnooze)

    /// Firing or snoozed: an episode is in progress.
    public var isActive: Bool {
        switch self {
        case .firing, .snoozed: return true
        case .armed, .delaying: return false
        }
    }
}

public struct AlertFiring: Sendable, Equatable, Codable {
    /// When this sounding began. For the pre-scheduled alerts it is also the anchor of the repeat
    /// slots: `since + k × interval`.
    public var since: Date
    /// The last slot or re-alert at which the alert sounded.
    public var lastSoundedAt: Date

    public init(since: Date, lastSoundedAt: Date) {
        self.since = since
        self.lastSoundedAt = lastSoundedAt
    }
}

public struct AlertSnooze: Sendable, Equatable, Codable {
    public var snoozedAt: Date
    public var until: Date

    public init(snoozedAt: Date, until: Date) {
        self.snoozedAt = snoozedAt
        self.until = until
    }
}

/// An alert's state as the Alerts and Now screens show it.
public enum AlertPhase: Sendable, Equatable {
    /// Turned off in settings (never for urgent low).
    case off
    case armed
    /// High with a delay: it fires at `firesAt` if glucose stays high.
    case pending(firesAt: Date)
    case firing(since: Date)
    case snoozed(until: Date)
}
