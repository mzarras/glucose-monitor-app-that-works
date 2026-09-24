// The Alerts screen (HANDOFF §5, §7.3.3, PROGRESS D17). Phase 2 fills it from AlertEngine's
// configuration; edits go back through AlertsActions. AlertEngine enforces S7; this screen also
// never offers a way to disable urgent low or snooze it longer than 30 minutes.

import Foundation

enum AlertKind: String, CaseIterable, Identifiable, Sendable {
    case urgentLow
    case urgentLowSoon
    case low
    case high
    case rateOfChange
    case missedReadings
    case sensorWarmUpComplete
    case sensorExpiring24h
    case sensorExpiring2h
    case sensorGracePeriod
    case sensorFailed
    case sensorError
    case trioBridge

    var id: String { rawValue }

    /// S7: urgent low (≤ 55 mg/dL) cannot be turned off.
    var canBeDisabled: Bool { self != .urgentLow }

    /// S7: urgent low snoozes for at most 30 minutes. Others: up to 2 hours.
    var maxSnoozeMinutes: Int { self == .urgentLow ? 30 : 120 }

    /// S7 / D17: urgent low always sounds on silent; the others have a per-alert setting.
    var soundOnSilentIsFixed: Bool { self == .urgentLow }

    /// D27 (HANDOFF §5): quiet hours silence every alert except urgent low. There is no per-alert
    /// quiet-hours setting.
    var soundsDuringQuietHours: Bool { self == .urgentLow }

    /// Allowed glucose thresholds, mg/dL. Urgent low 50–60 is HANDOFF §5; the others are this
    /// screen's limits (AlertEngine may be stricter).
    var glucoseThresholdRange: ClosedRange<Int>? {
        switch self {
        case .urgentLow: return 50...60
        case .low: return 60...100
        case .high: return 120...400
        default: return nil
        }
    }

    /// Rise/fall rate threshold, mg/dL per minute.
    var rateThresholdRange: ClosedRange<Double>? { self == .rateOfChange ? 2...5 : nil }

    /// Missed-readings window, minutes (HANDOFF §5: 10–60).
    var windowRange: ClosedRange<Int>? { self == .missedReadings ? 10...60 : nil }

    var title: String {
        switch self {
        case .urgentLow: return "Urgent low"
        case .urgentLowSoon: return "Urgent low soon"
        case .low: return "Low"
        case .high: return "High"
        case .rateOfChange: return "Rise / fall rate"
        case .missedReadings: return "Missed readings"
        case .sensorWarmUpComplete: return "Warm-up complete"
        case .sensorExpiring24h: return "Sensor expires in 24 h"
        case .sensorExpiring2h: return "Sensor expires in 2 h"
        case .sensorGracePeriod: return "Grace period started"
        case .sensorFailed: return "Sensor failed"
        case .sensorError: return "Sensor error"
        case .trioBridge: return "Trio handoff failing"
        }
    }

    var section: AlertSection {
        switch self {
        case .urgentLow, .urgentLowSoon, .low, .high, .rateOfChange: return .glucose
        case .missedReadings, .trioBridge: return .dataFlow
        case .sensorWarmUpComplete, .sensorExpiring24h, .sensorExpiring2h, .sensorGracePeriod, .sensorFailed, .sensorError: return .sensor
        }
    }
}

enum AlertSection: String, CaseIterable, Sendable {
    case glucose = "GLUCOSE"
    case dataFlow = "READINGS & TRIO"
    case sensor = "SENSOR"
}

/// A configurable threshold (HANDOFF §5 "Configurable" column).
enum AlertThreshold: Equatable, Sendable {
    /// Fires at or below (`isBelow`) / at or above the value, mg/dL.
    case glucose(mgdl: Int, isBelow: Bool, allowed: ClosedRange<Int>)
    /// Urgent low soon: projected ≤ `mgdl` within `minutes`, from the sensor-reported rate.
    case projected(mgdl: Int, minutes: Int)
    /// Rise/fall rate, mg/dL per minute (absolute value).
    case rate(mgdlPerMinute: Double, allowed: ClosedRange<Double>)
    /// Missed readings window, minutes.
    case window(minutes: Int, allowed: ClosedRange<Int>)
}

extension AlertThreshold {
    /// This threshold with its value clamped to `kind`'s limits, and those limits as `allowed`,
    /// whatever range the caller sent (review m5).
    func clamped(for kind: AlertKind) -> AlertThreshold {
        switch self {
        case .glucose(let mgdl, let isBelow, let allowed):
            let range = kind.glucoseThresholdRange ?? allowed
            return .glucose(mgdl: min(max(mgdl, range.lowerBound), range.upperBound), isBelow: isBelow, allowed: range)
        case .rate(let rate, let allowed):
            let range = kind.rateThresholdRange ?? allowed
            return .rate(mgdlPerMinute: min(max(rate, range.lowerBound), range.upperBound), allowed: range)
        case .window(let minutes, let allowed):
            let range = kind.windowRange ?? allowed
            return .window(minutes: min(max(minutes, range.lowerBound), range.upperBound), allowed: range)
        case .projected:
            return self
        }
    }
}

struct AlertRow: Equatable, Identifiable, Sendable {
    let kind: AlertKind
    /// Ignored for urgent low, which is always on (S7).
    var isEnabled: Bool
    var threshold: AlertThreshold?
    /// Id of the sound in `AlertsViewState.sounds`; nil for alerts that use the default sound.
    var soundID: String?
    /// D17: play the alarm through the ringer switch (in-app audio while awake). Always true for
    /// urgent low.
    var soundOnSilent: Bool
    /// Default snooze length, if the alert can be snoozed.
    var snoozeMinutes: Int?
    /// High only: fire after this many minutes above the threshold (HANDOFF §5 "delay").
    var delayMinutes: Int?
    /// Urgent low only: repeat an unacknowledged alert this often (HANDOFF §4.7: 5 min).
    var repeatMinutes: Int?

    var id: AlertKind { kind }

    /// What the row shows as on/off. Urgent low reads as on whatever `isEnabled` holds (S7).
    var effectiveIsEnabled: Bool { kind.canBeDisabled ? isEnabled : true }
    var effectiveSoundOnSilent: Bool { kind.soundOnSilentIsFixed ? true : soundOnSilent }
}

struct AlertSound: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct TimeOfDay: Equatable, Sendable {
    var hour: Int
    var minute: Int
}

/// Silences every alert except urgent low on a schedule (HANDOFF §5, PROGRESS D27).
struct QuietHours: Equatable, Sendable {
    var isEnabled: Bool
    var start: TimeOfDay
    var end: TimeOfDay
}

struct AlertsViewState: Equatable, Sendable {
    var rows: [AlertRow]
    var sounds: [AlertSound]
    var quietHours: QuietHours

    func row(_ kind: AlertKind) -> AlertRow? { rows.first { $0.kind == kind } }
    func soundName(_ id: String?) -> String {
        guard let id else { return "Default" }
        return sounds.first { $0.id == id }?.name ?? "Default"
    }
}

enum AlertsText {
    /// "≤ 55 mg/dL", "projected ≤ 55 in 20 min", "≥ 3 mg/dL/min", "no reading for 15 min".
    static func threshold(_ threshold: AlertThreshold?) -> String? {
        guard let threshold else { return nil }
        switch threshold {
        case .glucose(let mgdl, let isBelow, _):
            return "\(isBelow ? "≤" : "≥") \(mgdl) mg/dL"
        case .projected(let mgdl, let minutes):
            return "projected ≤ \(mgdl) in \(minutes) min"
        case .rate(let rate, _):
            return "≥ \(formatRate(rate)) mg/dL/min"
        case .window(let minutes, _):
            return "no reading for \(minutes) min"
        }
    }

    static func formatRate(_ rate: Double) -> String {
        rate == rate.rounded() ? String(Int(rate)) : String(format: "%.1f", rate)
    }

    /// Snooze choices offered for an alert: never longer than its maximum (S7: 30 min for urgent low).
    static func snoozeOptions(for kind: AlertKind) -> [Int] {
        [5, 10, 15, 20, 30, 45, 60, 90, 120].filter { $0 <= kind.maxSnoozeMinutes }
    }

    /// Explanation under the urgent low row (S7).
    static let urgentLowNote = "Always on and always sounds, even on silent. It can't be turned off; you can snooze it for up to 30 minutes."

    static let quietHoursNote = "Silences all alerts except Urgent low."

    /// "10 PM – 7 AM"
    static func quietHoursSchedule(_ quietHours: QuietHours) -> String {
        "\(time(quietHours.start)) – \(time(quietHours.end))"
    }

    /// "Sound on silent" row detail (D17).
    static let soundOnSilentNote = "Plays the alarm with the ringer switch off while the app is running. Otherwise the alert follows the ringer switch."

    static func time(_ time: TimeOfDay) -> String {
        let twelve = time.hour % 12 == 0 ? 12 : time.hour % 12
        let suffix = time.hour < 12 ? "AM" : "PM"
        return time.minute == 0 ? "\(twelve) \(suffix)" : "\(twelve):\(time.minute < 10 ? "0" : "")\(time.minute) \(suffix)"
    }
}
