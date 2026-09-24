// All alert settings (HANDOFF §5, §7.3 item 3). Codable for storage; decoding is lossy and
// migration-safe: unknown keys are ignored, a missing or unreadable field takes its default, an
// out-of-range number is clamped, an unknown sound id falls back to the alert's default sound, and
// there is no field through which urgent low could be turned off (S7).

import Foundation

public struct AlertSettings: Sendable, Equatable, Hashable, Codable {
    public var urgentLow: UrgentLowSettings
    public var urgentLowSoon: UrgentLowSoonSettings
    public var low: LowAlertSettings
    public var high: HighAlertSettings
    public var fallingFast: RateAlertSettings
    public var risingFast: RateAlertSettings
    public var missedReadings: MissedReadingsSettings
    public var sensorWarmUpComplete: EventAlertSettings
    public var sensorExpiringIn24Hours: EventAlertSettings
    public var sensorExpiringIn2Hours: EventAlertSettings
    public var sensorGracePeriod: EventAlertSettings
    public var sensorFailed: StatusAlertSettings
    public var sensorError: StatusAlertSettings
    public var calibrationNeeded: StatusAlertSettings
    public var sensorExpired: StatusAlertSettings
    public var bluetoothUnavailable: StatusAlertSettings
    public var trioBridge: StatusAlertSettings
    public var quietHours: QuietHours

    /// HANDOFF §5 defaults.
    public init() {
        urgentLow = UrgentLowSettings()
        urgentLowSoon = UrgentLowSoonSettings()
        low = LowAlertSettings()
        high = HighAlertSettings()
        fallingFast = RateAlertSettings(sound: AlertSoundCatalog.defaultSound(for: .fallingFast))
        risingFast = RateAlertSettings(sound: AlertSoundCatalog.defaultSound(for: .risingFast))
        missedReadings = MissedReadingsSettings()
        sensorWarmUpComplete = EventAlertSettings(sound: AlertSoundCatalog.defaultSound(for: .sensorWarmUpComplete))
        sensorExpiringIn24Hours = EventAlertSettings(sound: AlertSoundCatalog.defaultSound(for: .sensorExpiringIn24Hours))
        sensorExpiringIn2Hours = EventAlertSettings(sound: AlertSoundCatalog.defaultSound(for: .sensorExpiringIn2Hours))
        sensorGracePeriod = EventAlertSettings(sound: AlertSoundCatalog.defaultSound(for: .sensorGracePeriod))
        sensorFailed = .defaults(for: .sensorFailed)
        sensorError = .defaults(for: .sensorError)
        calibrationNeeded = .defaults(for: .calibrationNeeded)
        sensorExpired = .defaults(for: .sensorExpired)
        bluetoothUnavailable = .defaults(for: .bluetoothUnavailable)
        trioBridge = .defaults(for: .trioBridge)
        quietHours = .default
    }

    public static let defaults = AlertSettings()

    // MARK: Uniform read access (the engine and the Alerts list use these)

    /// Urgent low is always enabled (S7); there is nothing to read.
    public func isEnabled(_ kind: AlertKind) -> Bool {
        switch kind {
        case .urgentLow: return true
        case .urgentLowSoon: return urgentLowSoon.isEnabled
        case .low: return low.isEnabled
        case .high: return high.isEnabled
        case .fallingFast: return fallingFast.isEnabled
        case .risingFast: return risingFast.isEnabled
        case .missedReadings: return missedReadings.isEnabled
        case .sensorWarmUpComplete: return sensorWarmUpComplete.isEnabled
        case .sensorExpiringIn24Hours: return sensorExpiringIn24Hours.isEnabled
        case .sensorExpiringIn2Hours: return sensorExpiringIn2Hours.isEnabled
        case .sensorGracePeriod: return sensorGracePeriod.isEnabled
        case .sensorFailed: return sensorFailed.isEnabled
        case .sensorError: return sensorError.isEnabled
        case .calibrationNeeded: return calibrationNeeded.isEnabled
        case .sensorExpired: return sensorExpired.isEnabled
        case .bluetoothUnavailable: return bluetoothUnavailable.isEnabled
        case .trioBridge: return trioBridge.isEnabled
        }
    }

    public func sound(_ kind: AlertKind) -> AlertSoundID {
        switch kind {
        case .urgentLow: return urgentLow.sound
        case .urgentLowSoon: return urgentLowSoon.sound
        case .low: return low.sound
        case .high: return high.sound
        case .fallingFast: return fallingFast.sound
        case .risingFast: return risingFast.sound
        case .missedReadings: return missedReadings.sound
        case .sensorWarmUpComplete: return sensorWarmUpComplete.sound
        case .sensorExpiringIn24Hours: return sensorExpiringIn24Hours.sound
        case .sensorExpiringIn2Hours: return sensorExpiringIn2Hours.sound
        case .sensorGracePeriod: return sensorGracePeriod.sound
        case .sensorFailed: return sensorFailed.sound
        case .sensorError: return sensorError.sound
        case .calibrationNeeded: return calibrationNeeded.sound
        case .sensorExpired: return sensorExpired.sound
        case .bluetoothUnavailable: return bluetoothUnavailable.sound
        case .trioBridge: return trioBridge.sound
        }
    }

    /// Urgent low always sounds on silent (S7: loudest available path).
    public func soundsOnSilent(_ kind: AlertKind) -> Bool {
        switch kind {
        case .urgentLow: return true
        case .urgentLowSoon: return urgentLowSoon.soundsOnSilent
        case .low: return low.soundsOnSilent
        case .high: return high.soundsOnSilent
        case .fallingFast: return fallingFast.soundsOnSilent
        case .risingFast: return risingFast.soundsOnSilent
        case .missedReadings: return missedReadings.soundsOnSilent
        case .sensorWarmUpComplete: return sensorWarmUpComplete.soundsOnSilent
        case .sensorExpiringIn24Hours: return sensorExpiringIn24Hours.soundsOnSilent
        case .sensorExpiringIn2Hours: return sensorExpiringIn2Hours.soundsOnSilent
        case .sensorGracePeriod: return sensorGracePeriod.soundsOnSilent
        case .sensorFailed: return sensorFailed.soundsOnSilent
        case .sensorError: return sensorError.soundsOnSilent
        case .calibrationNeeded: return calibrationNeeded.soundsOnSilent
        case .sensorExpired: return sensorExpired.soundsOnSilent
        case .bluetoothUnavailable: return bluetoothUnavailable.soundsOnSilent
        case .trioBridge: return trioBridge.soundsOnSilent
        }
    }

    /// How long Acknowledge silences the alert, and (for alerts other than urgent low) the interval
    /// at which it re-alerts while the condition persists. `nil` for one-off events, which never
    /// re-alert. Urgent low is ≤ 30 minutes by construction (S7).
    public func snoozeMinutes(_ kind: AlertKind) -> Int? {
        switch kind {
        case .urgentLow: return urgentLow.snoozeMinutes
        case .urgentLowSoon: return urgentLowSoon.snoozeMinutes
        case .low: return low.snoozeMinutes
        case .high: return high.snoozeMinutes
        case .fallingFast: return fallingFast.snoozeMinutes
        case .risingFast: return risingFast.snoozeMinutes
        case .missedReadings: return missedReadings.snoozeMinutes
        case .sensorFailed: return sensorFailed.snoozeMinutes
        case .sensorError: return sensorError.snoozeMinutes
        case .calibrationNeeded: return calibrationNeeded.snoozeMinutes
        case .sensorExpired: return sensorExpired.snoozeMinutes
        case .bluetoothUnavailable: return bluetoothUnavailable.snoozeMinutes
        case .trioBridge: return trioBridge.snoozeMinutes
        case .sensorWarmUpComplete, .sensorExpiringIn24Hours, .sensorExpiringIn2Hours, .sensorGracePeriod:
            return nil
        }
    }

    // MARK: Uniform write access for the Alerts list

    /// Turns an alert on or off. Returns `false`, and changes nothing, for urgent low (S7).
    @discardableResult
    public mutating func setEnabled(_ enabled: Bool, for kind: AlertKind) -> Bool {
        switch kind {
        case .urgentLow: return false
        case .urgentLowSoon: urgentLowSoon.isEnabled = enabled
        case .low: low.isEnabled = enabled
        case .high: high.isEnabled = enabled
        case .fallingFast: fallingFast.isEnabled = enabled
        case .risingFast: risingFast.isEnabled = enabled
        case .missedReadings: missedReadings.isEnabled = enabled
        case .sensorWarmUpComplete: sensorWarmUpComplete.isEnabled = enabled
        case .sensorExpiringIn24Hours: sensorExpiringIn24Hours.isEnabled = enabled
        case .sensorExpiringIn2Hours: sensorExpiringIn2Hours.isEnabled = enabled
        case .sensorGracePeriod: sensorGracePeriod.isEnabled = enabled
        case .sensorFailed: sensorFailed.isEnabled = enabled
        case .sensorError: sensorError.isEnabled = enabled
        case .calibrationNeeded: calibrationNeeded.isEnabled = enabled
        case .sensorExpired: sensorExpired.isEnabled = enabled
        case .bluetoothUnavailable: bluetoothUnavailable.isEnabled = enabled
        case .trioBridge: trioBridge.isEnabled = enabled
        }
        return true
    }

    public mutating func setSound(_ sound: AlertSoundID, for kind: AlertKind) {
        switch kind {
        case .urgentLow: urgentLow.sound = sound
        case .urgentLowSoon: urgentLowSoon.sound = sound
        case .low: low.sound = sound
        case .high: high.sound = sound
        case .fallingFast: fallingFast.sound = sound
        case .risingFast: risingFast.sound = sound
        case .missedReadings: missedReadings.sound = sound
        case .sensorWarmUpComplete: sensorWarmUpComplete.sound = sound
        case .sensorExpiringIn24Hours: sensorExpiringIn24Hours.sound = sound
        case .sensorExpiringIn2Hours: sensorExpiringIn2Hours.sound = sound
        case .sensorGracePeriod: sensorGracePeriod.sound = sound
        case .sensorFailed: sensorFailed.sound = sound
        case .sensorError: sensorError.sound = sound
        case .calibrationNeeded: calibrationNeeded.sound = sound
        case .sensorExpired: sensorExpired.sound = sound
        case .bluetoothUnavailable: bluetoothUnavailable.sound = sound
        case .trioBridge: trioBridge.sound = sound
        }
    }

    /// Returns `false`, and changes nothing, for urgent low: it always sounds on silent (S7).
    @discardableResult
    public mutating func setSoundsOnSilent(_ on: Bool, for kind: AlertKind) -> Bool {
        switch kind {
        case .urgentLow: return false
        case .urgentLowSoon: urgentLowSoon.soundsOnSilent = on
        case .low: low.soundsOnSilent = on
        case .high: high.soundsOnSilent = on
        case .fallingFast: fallingFast.soundsOnSilent = on
        case .risingFast: risingFast.soundsOnSilent = on
        case .missedReadings: missedReadings.soundsOnSilent = on
        case .sensorWarmUpComplete: sensorWarmUpComplete.soundsOnSilent = on
        case .sensorExpiringIn24Hours: sensorExpiringIn24Hours.soundsOnSilent = on
        case .sensorExpiringIn2Hours: sensorExpiringIn2Hours.soundsOnSilent = on
        case .sensorGracePeriod: sensorGracePeriod.soundsOnSilent = on
        case .sensorFailed: sensorFailed.soundsOnSilent = on
        case .sensorError: sensorError.soundsOnSilent = on
        case .calibrationNeeded: calibrationNeeded.soundsOnSilent = on
        case .sensorExpired: sensorExpired.soundsOnSilent = on
        case .bluetoothUnavailable: bluetoothUnavailable.soundsOnSilent = on
        case .trioBridge: trioBridge.soundsOnSilent = on
        }
        return true
    }

    // MARK: Decoding (lossy, migration-safe)

    private enum CodingKeys: String, CodingKey {
        case urgentLow, urgentLowSoon, low, high, fallingFast, risingFast, missedReadings
        case sensorWarmUpComplete, sensorExpiringIn24Hours, sensorExpiringIn2Hours, sensorGracePeriod
        case sensorFailed, sensorError, calibrationNeeded, sensorExpired, bluetoothUnavailable, trioBridge
        case quietHours
    }

    /// Field names used inside each alert's object. Must match the property names above, which the
    /// synthesized `encode(to:)` uses.
    private enum FieldKey: String, CodingKey {
        case isEnabled, thresholdMgdl, delayMinutes, thresholdMgdlPerMinute, windowMinutes
        case sound, soundsOnSilent, snoozeMinutes, repeatMinutes
        case startMinuteOfDay, endMinuteOfDay
    }

    /// One alert's stored object. Every read falls back to the given default when the key is
    /// missing or its value has the wrong type; nothing here can throw.
    private struct Fields {
        let container: KeyedDecodingContainer<FieldKey>?

        func value<T: Decodable>(_ key: FieldKey, or fallback: T) -> T {
            guard let container else { return fallback }
            return (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
    }

    public init(from decoder: Decoder) throws {
        let d = AlertSettings.defaults
        guard let root = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = d
            return
        }
        func fields(_ key: CodingKeys) -> Fields {
            Fields(container: try? root.nestedContainer(keyedBy: FieldKey.self, forKey: key))
        }

        // S7: no `isEnabled` or `soundsOnSilent` is read for urgent low — there is nowhere to put
        // them. The three numbers go through the clamping initialiser (snooze ≤ 30 minutes).
        let u = fields(.urgentLow)
        urgentLow = UrgentLowSettings(
            thresholdMgdl: u.value(.thresholdMgdl, or: d.urgentLow.thresholdMgdl),
            sound: u.value(.sound, or: d.urgentLow.sound),
            repeatMinutes: u.value(.repeatMinutes, or: d.urgentLow.repeatMinutes),
            snoozeMinutes: u.value(.snoozeMinutes, or: d.urgentLow.snoozeMinutes)
        )

        let s = fields(.urgentLowSoon)
        urgentLowSoon = UrgentLowSoonSettings(
            isEnabled: s.value(.isEnabled, or: d.urgentLowSoon.isEnabled),
            sound: s.value(.sound, or: d.urgentLowSoon.sound),
            soundsOnSilent: s.value(.soundsOnSilent, or: d.urgentLowSoon.soundsOnSilent),
            snoozeMinutes: s.value(.snoozeMinutes, or: d.urgentLowSoon.snoozeMinutes)
        )

        let l = fields(.low)
        low = LowAlertSettings(
            isEnabled: l.value(.isEnabled, or: d.low.isEnabled),
            thresholdMgdl: l.value(.thresholdMgdl, or: d.low.thresholdMgdl),
            sound: l.value(.sound, or: d.low.sound),
            soundsOnSilent: l.value(.soundsOnSilent, or: d.low.soundsOnSilent),
            snoozeMinutes: l.value(.snoozeMinutes, or: d.low.snoozeMinutes)
        )

        let h = fields(.high)
        high = HighAlertSettings(
            isEnabled: h.value(.isEnabled, or: d.high.isEnabled),
            thresholdMgdl: h.value(.thresholdMgdl, or: d.high.thresholdMgdl),
            delayMinutes: h.value(.delayMinutes, or: d.high.delayMinutes),
            sound: h.value(.sound, or: d.high.sound),
            soundsOnSilent: h.value(.soundsOnSilent, or: d.high.soundsOnSilent),
            snoozeMinutes: h.value(.snoozeMinutes, or: d.high.snoozeMinutes)
        )

        fallingFast = Self.rate(fields(.fallingFast), default: d.fallingFast)
        risingFast = Self.rate(fields(.risingFast), default: d.risingFast)

        let m = fields(.missedReadings)
        missedReadings = MissedReadingsSettings(
            isEnabled: m.value(.isEnabled, or: d.missedReadings.isEnabled),
            windowMinutes: m.value(.windowMinutes, or: d.missedReadings.windowMinutes),
            sound: m.value(.sound, or: d.missedReadings.sound),
            soundsOnSilent: m.value(.soundsOnSilent, or: d.missedReadings.soundsOnSilent),
            snoozeMinutes: m.value(.snoozeMinutes, or: d.missedReadings.snoozeMinutes)
        )

        sensorWarmUpComplete = Self.event(fields(.sensorWarmUpComplete), default: d.sensorWarmUpComplete)
        sensorExpiringIn24Hours = Self.event(fields(.sensorExpiringIn24Hours), default: d.sensorExpiringIn24Hours)
        sensorExpiringIn2Hours = Self.event(fields(.sensorExpiringIn2Hours), default: d.sensorExpiringIn2Hours)
        sensorGracePeriod = Self.event(fields(.sensorGracePeriod), default: d.sensorGracePeriod)
        sensorFailed = Self.status(fields(.sensorFailed), default: d.sensorFailed)
        sensorError = Self.status(fields(.sensorError), default: d.sensorError)
        calibrationNeeded = Self.status(fields(.calibrationNeeded), default: d.calibrationNeeded)
        sensorExpired = Self.status(fields(.sensorExpired), default: d.sensorExpired)
        bluetoothUnavailable = Self.status(fields(.bluetoothUnavailable), default: d.bluetoothUnavailable)
        trioBridge = Self.status(fields(.trioBridge), default: d.trioBridge)

        let q = fields(.quietHours)
        quietHours = QuietHours(
            isEnabled: q.value(.isEnabled, or: d.quietHours.isEnabled),
            startMinuteOfDay: q.value(.startMinuteOfDay, or: d.quietHours.startMinuteOfDay),
            endMinuteOfDay: q.value(.endMinuteOfDay, or: d.quietHours.endMinuteOfDay)
        )
    }

    private static func rate(_ f: Fields, default d: RateAlertSettings) -> RateAlertSettings {
        RateAlertSettings(
            isEnabled: f.value(.isEnabled, or: d.isEnabled),
            thresholdMgdlPerMinute: f.value(.thresholdMgdlPerMinute, or: d.thresholdMgdlPerMinute),
            sound: f.value(.sound, or: d.sound),
            soundsOnSilent: f.value(.soundsOnSilent, or: d.soundsOnSilent),
            snoozeMinutes: f.value(.snoozeMinutes, or: d.snoozeMinutes)
        )
    }

    private static func status(_ f: Fields, default d: StatusAlertSettings) -> StatusAlertSettings {
        StatusAlertSettings(
            isEnabled: f.value(.isEnabled, or: d.isEnabled),
            sound: f.value(.sound, or: d.sound),
            soundsOnSilent: f.value(.soundsOnSilent, or: d.soundsOnSilent),
            snoozeMinutes: f.value(.snoozeMinutes, or: d.snoozeMinutes)
        )
    }

    private static func event(_ f: Fields, default d: EventAlertSettings) -> EventAlertSettings {
        EventAlertSettings(
            isEnabled: f.value(.isEnabled, or: d.isEnabled),
            sound: f.value(.sound, or: d.sound),
            soundsOnSilent: f.value(.soundsOnSilent, or: d.soundsOnSilent)
        )
    }

    /// Decodes stored settings, or returns the defaults if `data` is not a JSON object at all.
    /// Never throws: a settings file must never stop alerts from running.
    public static func decodeOrDefault(_ data: Data?) -> AlertSettings {
        guard let data, let settings = try? JSONDecoder().decode(AlertSettings.self, from: data) else {
            return .defaults
        }
        return settings
    }
}
