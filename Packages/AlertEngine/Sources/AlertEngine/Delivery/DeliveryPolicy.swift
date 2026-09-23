// Which path(s) make an alert audible (HANDOFF §4.7, PROGRESS.md D4 + D17). Pure and total, so
// every combination is unit-tested.
//
// Facts this is built on (sources in docs/alerts.md):
//   • A Time Sensitive notification obeys the ring/silent switch: on silent it vibrates only.
//   • Only a Critical Alert bypasses the switch from a notification, and it needs an Apple-granted
//     entitlement that a build-from-source app is unlikely to get.
//   • An app that is running can play audio with AVAudioSession category `.playback`, which
//     ignores the switch (xDrip4iOS SoundPlayer.swift:31, Loop CriticalAlertAudioPlayer.swift:104).
//     The G7 wakes the app about every 5 minutes, which is when reading-driven alerts fire.
//
// So, for an alert with "Sound on silent" on:
//   critical authorized              → Critical Alert with our sound. Nothing else needed.
//   otherwise, app awake (now)       → Time Sensitive notification with the sound (for the ringer-on
//                                      case and vibration) + in-app `.playback` sound (ringer off).
//   otherwise, pending notification  → Time Sensitive with the sound: audible only if the ringer is
//                                      on; vibrates on silent. The documented gap (D17).
// With "Sound on silent" off: Time Sensitive with the sound (respects the switch).
// Quiet hours: passive, no sound, no in-app sound — never for urgent low.
// Urgent low always counts as "Sound on silent" on and is never silenced (S7).

import Foundation

/// When the notification is delivered relative to the app running.
public enum DeliveryTiming: Sendable, Equatable, CaseIterable {
    /// Delivered while the app is awake handling an input: in-app audio is possible.
    case now
    /// A pending notification iOS delivers later, possibly while the app is suspended.
    case scheduled
}

public enum NotificationInterruption: Sendable, Equatable {
    /// Quietly into Notification Center (quiet hours).
    case passive
    /// Breaks through notification summaries and Focus if allowed; obeys the silent switch.
    case timeSensitive
    /// Critical Alert: plays even on silent and in Focus. Needs the entitlement and the user's grant.
    case critical
}

public enum NotificationSoundChoice: Sendable, Equatable {
    case none
    /// A bundled sound file, played by iOS subject to the ringer switch and ringer volume.
    case named(fileName: String)
    /// A Critical Alert sound at a fixed volume (0…1), regardless of switch and ringer volume.
    case critical(fileName: String, volume: Float)
}

/// Sound played by the app itself through AVAudioSession `.playback` (ignores the silent switch,
/// follows the media volume).
public struct InAppSound: Sendable, Equatable {
    public let fileName: String
    /// Keep looping this long; 0 plays the file once.
    public let loopSeconds: TimeInterval
}

public struct DeliveryDecision: Sendable, Equatable {
    public let interruption: NotificationInterruption
    public let notificationSound: NotificationSoundChoice
    /// `nil`: no in-app sound.
    public let inAppSound: InAppSound?

    /// Orders decisions by how reliably they are heard with the phone on silent.
    public var loudness: Int {
        switch (interruption, inAppSound) {
        case (.critical, _): return 3
        case (_, .some): return 2
        case (.timeSensitive, nil): return notificationSound == .none ? 0 : 1
        case (.passive, nil): return 0
        }
    }
}

public enum DeliveryPolicy {
    /// Critical Alert sounds play at this volume (0…1). Full volume: these are the alerts that
    /// must wake someone.
    public static let criticalVolume: Float = 1.0

    public static func decide(for notice: AlertNotice, criticalAlertsEnabled: Bool, timing: DeliveryTiming) -> DeliveryDecision {
        let isUrgent = notice.kind == .urgentLow
        // S7, defence in depth: the engine already never silences urgent low and always marks it
        // sound-on-silent; this function does not trust that.
        let soundsOnSilent = notice.soundsOnSilent || isUrgent
        let silenced = notice.isSilenced && !isUrgent
        let fileName = AlertSoundCatalog.fileName(notice.sound)

        if silenced {
            return DeliveryDecision(interruption: .passive, notificationSound: .none, inAppSound: nil)
        }
        if soundsOnSilent && criticalAlertsEnabled {
            return DeliveryDecision(
                interruption: .critical,
                notificationSound: .critical(fileName: fileName, volume: criticalVolume),
                inAppSound: nil
            )
        }
        if soundsOnSilent && timing == .now {
            // The notification keeps its sound as well: with the ringer on but the media volume
            // at zero, the notification sound is the one that is heard. With the ringer on and
            // both volumes up, both play; that is the accepted cost (Loop does the same).
            let loop = isUrgent ? AlertLimits.urgentInAppAudioSeconds : 0
            return DeliveryDecision(
                interruption: .timeSensitive,
                notificationSound: .named(fileName: fileName),
                inAppSound: InAppSound(fileName: fileName, loopSeconds: loop)
            )
        }
        return DeliveryDecision(interruption: .timeSensitive, notificationSound: .named(fileName: fileName), inAppSound: nil)
    }
}
