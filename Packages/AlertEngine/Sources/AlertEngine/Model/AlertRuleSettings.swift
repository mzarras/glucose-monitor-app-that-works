// Per-alert settings (HANDOFF §5 "Configurable" column). Each type clamps its numbers in its
// initialiser and in every property setter, so an out-of-range value cannot be stored. Decoding
// goes only through `AlertSettings.init(from:)`, which rebuilds these through the same
// initialisers; the types are deliberately `Encodable` only so nothing can decode one around it.
//
// "Sound on silent" (`soundsOnSilent`) is the equivalent of xDrip4iOS's per-alert "override mute"
// (xDrip/Core Data/classes/AlertType+CoreDataClass.swift:10). When on, the alert uses the loudest
// path available: a Critical Alert if the user has granted it, otherwise the in-app
// AVAudioSession `.playback` sound whenever the app is awake (see DeliveryPolicy).

/// Urgent low (S7). There is no `isEnabled` and no `soundsOnSilent`: urgent low is always on and
/// always uses the loudest available path. A stored `"isEnabled": false` has nothing to decode
/// into, so it can never take effect.
public struct UrgentLowSettings: Sendable, Equatable, Hashable, Encodable {
    /// 50…60 mg/dL (HANDOFF §5).
    public var thresholdMgdl: Int {
        didSet { thresholdMgdl = AlertLimits.clamp(thresholdMgdl, to: AlertLimits.urgentLowThresholdMgdl) }
    }
    public var sound: AlertSoundID
    /// Minutes between repeats while unacknowledged, 2…5 (HANDOFF §4.7). Cannot be turned off.
    public var repeatMinutes: Int {
        didSet { repeatMinutes = AlertLimits.clamp(repeatMinutes, to: AlertLimits.urgentLowRepeatMinutes) }
    }
    /// How long Acknowledge or Snooze silences it, 1…30 minutes (S7).
    public var snoozeMinutes: Int {
        didSet { snoozeMinutes = AlertLimits.clamp(snoozeMinutes, to: AlertLimits.urgentLowSnoozeMinutes) }
    }

    public init(
        thresholdMgdl: Int = AlertLimits.urgentLowDefaultThresholdMgdl,
        sound: AlertSoundID = AlertSoundCatalog.defaultSound(for: .urgentLow),
        repeatMinutes: Int = AlertLimits.urgentLowDefaultRepeatMinutes,
        snoozeMinutes: Int = AlertLimits.urgentLowDefaultSnoozeMinutes
    ) {
        self.thresholdMgdl = AlertLimits.clamp(thresholdMgdl, to: AlertLimits.urgentLowThresholdMgdl)
        self.sound = sound
        self.repeatMinutes = AlertLimits.clamp(repeatMinutes, to: AlertLimits.urgentLowRepeatMinutes)
        self.snoozeMinutes = AlertLimits.clamp(snoozeMinutes, to: AlertLimits.urgentLowSnoozeMinutes)
    }
}

/// Urgent low soon: off by default. Its target is the urgent-low threshold and its horizon is
/// fixed at 20 minutes (HANDOFF §5); only the sensor-reported rate is used (S1).
public struct UrgentLowSoonSettings: Sendable, Equatable, Hashable, Encodable {
    public var isEnabled: Bool
    public var sound: AlertSoundID
    public var soundsOnSilent: Bool
    public var snoozeMinutes: Int {
        didSet { snoozeMinutes = AlertLimits.clamp(snoozeMinutes, to: AlertLimits.snoozeMinutes) }
    }

    public init(
        isEnabled: Bool = false,
        sound: AlertSoundID = AlertSoundCatalog.defaultSound(for: .urgentLowSoon),
        soundsOnSilent: Bool = true,
        snoozeMinutes: Int = AlertLimits.urgentLowSoonDefaultSnoozeMinutes
    ) {
        self.isEnabled = isEnabled
        self.sound = sound
        self.soundsOnSilent = soundsOnSilent
        self.snoozeMinutes = AlertLimits.clamp(snoozeMinutes, to: AlertLimits.snoozeMinutes)
    }
}

/// Low: on, ≤ 70 mg/dL by default.
public struct LowAlertSettings: Sendable, Equatable, Hashable, Encodable {
    public var isEnabled: Bool
    public var thresholdMgdl: Int {
        didSet { thresholdMgdl = AlertLimits.clamp(thresholdMgdl, to: AlertLimits.lowThresholdMgdl) }
    }
    public var sound: AlertSoundID
    public var soundsOnSilent: Bool
    public var snoozeMinutes: Int {
        didSet { snoozeMinutes = AlertLimits.clamp(snoozeMinutes, to: AlertLimits.snoozeMinutes) }
    }

    public init(
        isEnabled: Bool = true,
        thresholdMgdl: Int = AlertLimits.lowDefaultThresholdMgdl,
        sound: AlertSoundID = AlertSoundCatalog.defaultSound(for: .low),
        soundsOnSilent: Bool = true,
        snoozeMinutes: Int = AlertLimits.lowDefaultSnoozeMinutes
    ) {
        self.isEnabled = isEnabled
        self.thresholdMgdl = AlertLimits.clamp(thresholdMgdl, to: AlertLimits.lowThresholdMgdl)
        self.sound = sound
        self.soundsOnSilent = soundsOnSilent
        self.snoozeMinutes = AlertLimits.clamp(snoozeMinutes, to: AlertLimits.snoozeMinutes)
    }
}

/// High: on, ≥ 250 mg/dL by default, with an optional "fire only after N minutes above" delay.
public struct HighAlertSettings: Sendable, Equatable, Hashable, Encodable {
    public var isEnabled: Bool
    public var thresholdMgdl: Int {
        didSet { thresholdMgdl = AlertLimits.clamp(thresholdMgdl, to: AlertLimits.highThresholdMgdl) }
    }
    public var delayMinutes: Int {
        didSet { delayMinutes = AlertLimits.clamp(delayMinutes, to: AlertLimits.highDelayMinutes) }
    }
    public var sound: AlertSoundID
    public var soundsOnSilent: Bool
    public var snoozeMinutes: Int {
        didSet { snoozeMinutes = AlertLimits.clamp(snoozeMinutes, to: AlertLimits.snoozeMinutes) }
    }

    public init(
        isEnabled: Bool = true,
        thresholdMgdl: Int = AlertLimits.highDefaultThresholdMgdl,
        delayMinutes: Int = AlertLimits.highDefaultDelayMinutes,
        sound: AlertSoundID = AlertSoundCatalog.defaultSound(for: .high),
        soundsOnSilent: Bool = true,
        snoozeMinutes: Int = AlertLimits.highDefaultSnoozeMinutes
    ) {
        self.isEnabled = isEnabled
        self.thresholdMgdl = AlertLimits.clamp(thresholdMgdl, to: AlertLimits.highThresholdMgdl)
        self.delayMinutes = AlertLimits.clamp(delayMinutes, to: AlertLimits.highDelayMinutes)
        self.sound = sound
        self.soundsOnSilent = soundsOnSilent
        self.snoozeMinutes = AlertLimits.clamp(snoozeMinutes, to: AlertLimits.snoozeMinutes)
    }
}

/// Falling fast / rising fast: off by default, 3 mg/dL/min. Uses the sensor-reported rate only.
public struct RateAlertSettings: Sendable, Equatable, Hashable, Encodable {
    public var isEnabled: Bool
    /// Magnitude in mg/dL per minute (2…5); the direction comes from the alert kind.
    public var thresholdMgdlPerMinute: Double {
        didSet { thresholdMgdlPerMinute = AlertLimits.clamp(thresholdMgdlPerMinute, to: AlertLimits.rateThresholdMgdlPerMinute) }
    }
    public var sound: AlertSoundID
    public var soundsOnSilent: Bool
    public var snoozeMinutes: Int {
        didSet { snoozeMinutes = AlertLimits.clamp(snoozeMinutes, to: AlertLimits.snoozeMinutes) }
    }

    public init(
        isEnabled: Bool = false,
        thresholdMgdlPerMinute: Double = AlertLimits.rateDefaultThresholdMgdlPerMinute,
        sound: AlertSoundID = AlertSoundCatalog.defaultSound(for: .fallingFast),
        soundsOnSilent: Bool = false,
        snoozeMinutes: Int = AlertLimits.rateDefaultSnoozeMinutes
    ) {
        self.isEnabled = isEnabled
        self.thresholdMgdlPerMinute = AlertLimits.clamp(thresholdMgdlPerMinute, to: AlertLimits.rateThresholdMgdlPerMinute)
        self.sound = sound
        self.soundsOnSilent = soundsOnSilent
        self.snoozeMinutes = AlertLimits.clamp(snoozeMinutes, to: AlertLimits.snoozeMinutes)
    }
}

/// Missed readings (S5): on, 15-minute window by default.
public struct MissedReadingsSettings: Sendable, Equatable, Hashable, Encodable {
    public var isEnabled: Bool
    /// 10…60 minutes (HANDOFF §5). Also the interval between repeats while it stays unanswered.
    public var windowMinutes: Int {
        didSet { windowMinutes = AlertLimits.clamp(windowMinutes, to: AlertLimits.missedReadingsWindowMinutes) }
    }
    public var sound: AlertSoundID
    /// Takes effect only while the app is awake; see docs/alerts.md "The suspended-app gap".
    public var soundsOnSilent: Bool
    public var snoozeMinutes: Int {
        didSet { snoozeMinutes = AlertLimits.clamp(snoozeMinutes, to: AlertLimits.snoozeMinutes) }
    }

    public init(
        isEnabled: Bool = true,
        windowMinutes: Int = AlertLimits.missedReadingsDefaultWindowMinutes,
        sound: AlertSoundID = AlertSoundCatalog.defaultSound(for: .missedReadings),
        soundsOnSilent: Bool = true,
        snoozeMinutes: Int = AlertLimits.missedReadingsDefaultSnoozeMinutes
    ) {
        self.isEnabled = isEnabled
        self.windowMinutes = AlertLimits.clamp(windowMinutes, to: AlertLimits.missedReadingsWindowMinutes)
        self.sound = sound
        self.soundsOnSilent = soundsOnSilent
        self.snoozeMinutes = AlertLimits.clamp(snoozeMinutes, to: AlertLimits.snoozeMinutes)
    }
}

/// A condition alert about the sensor, Bluetooth, the Trio bridge or storage (sensor failed, sensor
/// error, calibration needed, sensor expired, Bluetooth unavailable, Trio bridge, storage failing).
/// On by default (S5).
public struct StatusAlertSettings: Sendable, Equatable, Hashable, Encodable {
    public var isEnabled: Bool
    public var sound: AlertSoundID
    public var soundsOnSilent: Bool
    /// Re-alert interval while the problem persists, and the Acknowledge/Snooze duration.
    public var snoozeMinutes: Int {
        didSet { snoozeMinutes = AlertLimits.clamp(snoozeMinutes, to: AlertLimits.snoozeMinutes) }
    }

    public init(isEnabled: Bool, sound: AlertSoundID, soundsOnSilent: Bool, snoozeMinutes: Int) {
        self.isEnabled = isEnabled
        self.sound = sound
        self.soundsOnSilent = soundsOnSilent
        self.snoozeMinutes = AlertLimits.clamp(snoozeMinutes, to: AlertLimits.snoozeMinutes)
    }

    /// Defaults per kind. Sound on silent is on for those that mean readings have stopped or are
    /// not reaching Trio (each raised while the app is awake handling that event); off for storage
    /// failing, which loses history but not alerts or Trio (D42).
    public static func defaults(for kind: AlertKind) -> StatusAlertSettings {
        let snooze: Int
        switch kind {
        case .bluetoothUnavailable: snooze = AlertLimits.bluetoothDefaultSnoozeMinutes
        case .trioBridge: snooze = AlertLimits.trioBridgeDefaultSnoozeMinutes
        case .calibrationNeeded: snooze = AlertLimits.calibrationDefaultSnoozeMinutes
        case .storageFailing: snooze = AlertLimits.storageDefaultSnoozeMinutes
        default: snooze = AlertLimits.sensorProblemDefaultSnoozeMinutes
        }
        return StatusAlertSettings(
            isEnabled: true,
            sound: AlertSoundCatalog.defaultSound(for: kind),
            soundsOnSilent: kind != .storageFailing,
            snoozeMinutes: snooze
        )
    }
}

/// A one-off sensor announcement (warm-up complete, expiring in 24 h / 2 h, grace period). On by
/// default, informational, so it respects the ringer switch unless the user turns sound on silent on.
public struct EventAlertSettings: Sendable, Equatable, Hashable, Encodable {
    public var isEnabled: Bool
    public var sound: AlertSoundID
    public var soundsOnSilent: Bool

    public init(
        isEnabled: Bool = true,
        sound: AlertSoundID = AlertSoundCatalog.defaultSound(for: .sensorWarmUpComplete),
        soundsOnSilent: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.sound = sound
        self.soundsOnSilent = soundsOnSilent
    }
}
