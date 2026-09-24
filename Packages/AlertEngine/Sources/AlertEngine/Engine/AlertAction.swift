// What the engine asks the delivery layer to do. Each case is explicit and comparable, so the
// state machine is tested by asserting on these values alone.

import Foundation
import GlucoseCore

/// One alert, ready to deliver: the text and the sound, plus whether quiet hours silence it.
public struct AlertNotice: Sendable, Equatable {
    public let kind: AlertKind
    public let title: String
    public let body: String
    public let sound: AlertSoundID
    /// The per-alert "Sound on silent" setting. Always true for urgent low (S7).
    public let soundsOnSilent: Bool
    /// Quiet hours: deliver with no sound at all. Never true for urgent low (S7).
    public let isSilenced: Bool
    /// Duration of the notification's Snooze action; `nil` for one-off events (no Snooze action).
    public let snoozeMinutes: Int?
    /// `nil`: deliver now. Otherwise the time a pending notification fires (for `playDueAlert`:
    /// the time of the repeat that is due).
    public let fireDate: Date?
    /// For a pending repeat: its identifier slot (`ScheduledRepeat.slot`), which names the
    /// notification and, for urgent low, the system alarm. `nil` for the immediate notification.
    public let slot: Int?

    public init(
        kind: AlertKind, title: String, body: String, sound: AlertSoundID, soundsOnSilent: Bool,
        isSilenced: Bool, snoozeMinutes: Int?, fireDate: Date?, slot: Int? = nil
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.sound = sound
        self.soundsOnSilent = soundsOnSilent
        self.isSilenced = isSilenced
        self.snoozeMinutes = snoozeMinutes
        self.fireDate = fireDate
        self.slot = slot
    }
}

public enum AlertAction: Sendable, Equatable {
    /// Post the notification now and, if the delivery policy says so, play the in-app sound.
    case fire(AlertNotice)
    /// A notification that was scheduled for this moment is due (iOS posts it by itself). The app
    /// happens to be awake, so play the in-app sound if the delivery policy says so. Used for the
    /// urgent-low repeats and the missed-readings alert.
    case playDueAlert(AlertNotice)
    /// Add these pending notifications (each has a `fireDate` and a `slot`); for urgent low, also
    /// their system alarms. Replaces only the same slots; removes nothing else. The engine never
    /// includes a slot that is due within `AlertLimits.protectedLeadTime`.
    case schedule(AlertKind, [AlertNotice])
    /// Remove these pending slots (notifications and, for urgent low, alarms). The engine only names
    /// slots due later than `protectedLeadTime`.
    case cancelSlots(AlertKind, [Int])
    /// Remove every pending notification (and, for urgent low, every alarm) for this alert. Only used
    /// when the alert is not firing (launch reconcile).
    case cancelScheduled(AlertKind)
    /// Remove pending and delivered notifications for this alert and stop its in-app sound.
    case cancel(AlertKind)
    /// Stop the in-app sound for this alert; leave notifications alone.
    case stopSound(AlertKind)
    /// A reading was refused by `LiveReadingGate` and changed nothing (S2, S6). For diagnostics.
    case readingRejected(readingID: String, reason: LiveReadingGate.Rejection)
    /// A user action that does not apply in the alert's current state (e.g. snoozing an alert that
    /// is not firing). Changed nothing. For diagnostics.
    case userActionIgnored(AlertUserAction)
}
