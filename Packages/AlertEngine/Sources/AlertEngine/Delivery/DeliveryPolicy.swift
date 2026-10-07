// Which path(s) make an alert audible (HANDOFF §4.7, PROGRESS.md D4, D17, D26). Pure and total, so
// every combination is unit-tested.
//
// Facts this is built on (sources in docs/alerts.md):
//   • A Time Sensitive notification obeys the ring/silent switch: on silent it vibrates only.
//   • Only a Critical Alert bypasses the switch from a notification, and it needs an Apple-granted
//     entitlement that a build-from-source app is unlikely to get.
//   • An app that is running can play audio with AVAudioSession category `.playback`, which
//     ignores the switch (xDrip4iOS SoundPlayer.swift:31, Loop CriticalAlertAudioPlayer.swift:104).
//     The G7 wakes the app about every 5 minutes, which is when reading-driven alerts fire.
//   • On iOS 26+, an AlarmKit alarm rings on silent and in Focus, even while the app is suspended,
//     once the user allows alarms (D26; Loop PR #2520).
//
// So, for an alert with "Sound on silent" on:
//   critical authorized              → Critical Alert with our sound. Nothing else needed.
//   urgent low, alarms available     → system alarm (rings) + Time Sensitive notification with the
//                                      sound (the visual, with Snooze/Acknowledge). No in-app sound:
//                                      it would clash with the alarm.
//   otherwise, app awake (now)       → Time Sensitive notification with the sound (for the ringer-on
//                                      case and vibration) + in-app `.playback` sound (ringer off).
//   otherwise, pending notification  → Time Sensitive with the sound: audible only if the ringer is
//                                      on; vibrates on silent. The documented gap (D17).
// With "Sound on silent" off: Time Sensitive with the sound (respects the switch).
// Quiet hours: passive, no sound, no in-app sound — never for urgent low.
// Style silent (an announcement, D43: the 24-hour expiry reminder by default): active, no sound, no
// in-app sound — a visible notification. Never for urgent low (S7).
// Style vibrate only (D53): the same interruption level as the sound style would get (Time
// Sensitive; Critical when granted and "Sound on silent" is on), but the notification carries the
// silent `alert-vibrate.caf`, so iOS plays only the vibration that goes with a notification sound;
// where the sound style would play the in-app sound (awake, "Sound on silent" on), the app vibrates
// instead (`inAppHaptic`) and never activates its audio session. Never for urgent low (S7).
// Urgent low always counts as "Sound on silent" on and is never silenced (S7). Only urgent low
// uses system alarms (D26).
//
// Critical Alerts win over system alarms when both are available (Loop does the same: it uses
// AlarmKit only in builds without the entitlement, AlertManager.swift:451-457).

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
    /// An ordinary notification: shown on the lock screen, held back by Focus and summaries. Used
    /// with no sound for an announcement whose sound is off (D43).
    case active
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

extension NotificationSoundChoice {
    /// Whether it makes a sound at all: not for `.none` or the silent vibrate-only file (D53).
    public var isAudible: Bool {
        switch self {
        case .none: return false
        case .named(let fileName), .critical(let fileName, _): return fileName != AlertSoundCatalog.vibrateFileName
        }
    }
}

public struct DeliveryDecision: Sendable, Equatable {
    public let interruption: NotificationInterruption
    public let notificationSound: NotificationSoundChoice
    /// `nil`: no in-app sound.
    public let inAppSound: InAppSound?
    /// Also schedule a system alarm (AlarmKit) playing this bundled file. `nil`: no alarm.
    public let systemAlarmSoundFileName: String?
    /// Vibrate now from the app (D53 vibrate only, awake): in place of `inAppSound`.
    public let inAppHaptic: Bool

    public init(interruption: NotificationInterruption, notificationSound: NotificationSoundChoice,
                inAppSound: InAppSound?, systemAlarmSoundFileName: String? = nil, inAppHaptic: Bool = false) {
        self.interruption = interruption
        self.notificationSound = notificationSound
        self.inAppSound = inAppSound
        self.systemAlarmSoundFileName = systemAlarmSoundFileName
        self.inAppHaptic = inAppHaptic
    }

    /// Orders decisions by how reliably they are heard with the phone on silent: 3 rings on silent
    /// even while suspended (Critical Alert, system alarm), 2 while awake (in-app sound), 1 only
    /// with the ringer on, 0 not audible at all (silent, or vibrate only).
    public var loudness: Int {
        if (interruption == .critical && notificationSound.isAudible) || systemAlarmSoundFileName != nil { return 3 }
        if inAppSound != nil { return 2 }
        if interruption == .timeSensitive && notificationSound.isAudible { return 1 }
        return 0
    }
}

public enum DeliveryPolicy {
    /// Critical Alert sounds play at this volume (0…1). Full volume: these are the alerts that
    /// must wake someone.
    public static let criticalVolume: Float = 1.0

    /// - Parameters:
    ///   - criticalAlertsEnabled: the user granted Critical Alerts and the build has the entitlement.
    ///   - systemAlarmsAvailable: iOS 26+ and the user allowed alarms (`SystemAlarmAuthorization.authorized`).
    public static func decide(
        for notice: AlertNotice, criticalAlertsEnabled: Bool, systemAlarmsAvailable: Bool, timing: DeliveryTiming
    ) -> DeliveryDecision {
        let isUrgent = notice.kind == .urgentLow
        // S7, defence in depth: the engine already never silences urgent low and always marks it
        // sound-on-silent; this function does not trust that.
        let soundsOnSilent = notice.soundsOnSilent || isUrgent
        let silenced = notice.isSilenced && !isUrgent
        let fileName = AlertSoundCatalog.fileName(notice.sound)

        // S7 again: urgent low's style is always `.sound`, whatever the notice says.
        let style = isUrgent ? .sound : notice.style

        if silenced {
            return DeliveryDecision(interruption: .passive, notificationSound: .none, inAppSound: nil)
        }
        switch style {
        case .silent:
            return DeliveryDecision(interruption: .active, notificationSound: .none, inAppSound: nil)
        case .vibrateOnly:
            let vibrate = AlertSoundCatalog.vibrateFileName
            if soundsOnSilent && criticalAlertsEnabled {
                return DeliveryDecision(interruption: .critical, notificationSound: .critical(fileName: vibrate, volume: criticalVolume),
                                        inAppSound: nil)
            }
            return DeliveryDecision(interruption: .timeSensitive, notificationSound: .named(fileName: vibrate), inAppSound: nil,
                                    inAppHaptic: soundsOnSilent && timing == .now)
        case .sound:
            break
        }
        if soundsOnSilent && criticalAlertsEnabled {
            return DeliveryDecision(
                interruption: .critical,
                notificationSound: .critical(fileName: fileName, volume: criticalVolume),
                inAppSound: nil
            )
        }
        if isUrgent && systemAlarmsAvailable {
            return DeliveryDecision(
                interruption: .timeSensitive,
                notificationSound: .named(fileName: fileName),
                inAppSound: nil,
                systemAlarmSoundFileName: AlertSoundCatalog.alarmFileName(notice.sound)
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
