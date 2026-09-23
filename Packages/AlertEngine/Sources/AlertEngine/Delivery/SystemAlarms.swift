// System alarms for urgent low (PROGRESS.md D26): on iOS 26+, with the user's permission, urgent
// low and each of its pre-scheduled repeats are also AlarmKit alarms. An alarm rings like a Clock
// alarm — on silent, in Focus, while the app is suspended — without the Critical Alerts
// entitlement. Loop does this for its critical alerts (LoopKit/Loop next-dev,
// Loop/Managers/Alerts/CriticalAlertAlarmScheduler.swift; PR #2520, confirmed on hardware for the
// immediate alarm). Loop schedules only the immediate alarm; the pre-scheduled repeat alarms here
// are this project's addition and are UNPROVEN on hardware (docs/alerts.md, HANDOFF §11 item).
//
// This file is platform-neutral: the port, the IDs, and the request. The AlarmKit implementation is
// Platform/SystemAlarmAdapter.swift (iOS only).

import Foundation

/// Whether urgent low can ring as a system alarm. Shown on the Settings screen's
/// "Urgent low alarm" row.
public enum SystemAlarmAuthorization: Sendable, Equatable {
    /// iOS older than 26, or no AlarmKit in this build: urgent low uses the D17 path.
    case unavailable
    /// The permission prompt has not been answered.
    case notDetermined
    /// The user said no (Settings → the app → Alarms).
    case denied
    case authorized
}

/// One alarm to schedule.
public struct SystemAlarmRequest: Sendable, Equatable {
    public let id: UUID
    /// A fixed alarm at or before the moment it is scheduled never rings (Loop `25f79bd`); the
    /// executor never asks for less than `SystemAlarmIDs.minimumLeadTime` ahead.
    public let fireDate: Date
    public let title: String
    /// A sound file in the app bundle root (`AlertSoundCatalog.alarmFileName`).
    public let soundFileName: String

    public init(id: UUID, fireDate: Date, title: String, soundFileName: String) {
        self.id = id
        self.fireDate = fireDate
        self.title = title
        self.soundFileName = soundFileName
    }
}

@MainActor
public protocol SystemAlarmScheduling: AnyObject {
    var authorization: SystemAlarmAuthorization { get }
    /// Asks once (onboarding); returns the resulting state. No prompt once decided.
    func requestAuthorization() async -> SystemAlarmAuthorization
    /// Schedules one alarm. Throws if the system refuses (not authorized, limit reached, …); the
    /// caller then falls back to the notification + in-app sound path.
    func schedule(_ request: SystemAlarmRequest) async throws
    /// Stops (if ringing) and cancels these alarms; unknown IDs are ignored.
    func cancel(ids: [UUID])
    /// Stops and cancels every alarm this app has. Only urgent low uses alarms.
    func cancelAll()
}

/// Fixed alarm IDs, one per slot, like the fixed notification identifiers: nothing needs to be
/// stored to find an alarm again, and cancelling by ID is always possible after a relaunch.
public enum SystemAlarmIDs {
    /// Slot 0 is the alarm for the urgent low firing now; slots 1… are its repeats.
    /// Format: fixed prefix + slot number in the last 12 hex digits (a valid version-4-shaped UUID).
    public static func id(slot: Int) -> UUID {
        // Force-unwrap is safe: the format always yields 36 valid characters for 0 ≤ slot < 16^12.
        UUID(uuidString: String(format: "5E7A1A7D-0000-4000-8000-%012X", slot))!
    }

    public static var immediate: UUID { id(slot: 0) }

    /// The alarm for pending repeat number `index` (0-based, same as the notification slot).
    public static func repeatSlot(_ index: Int) -> UUID { id(slot: index + 1) }

    public static var allRepeats: [UUID] {
        (0..<AlertLimits.maximumScheduledSlots).map(repeatSlot)
    }

    /// Loop schedules its "immediate" alarm 2 s ahead: a fixed alarm at or before now never rings
    /// (Loop/Managers/Alerts/CriticalAlertAlarmScheduler.swift:73-76, commit 25f79bd).
    public static let minimumLeadTime: TimeInterval = 2
}

public enum SystemAlarmError: Error, Sendable, Equatable {
    case unavailable
}
