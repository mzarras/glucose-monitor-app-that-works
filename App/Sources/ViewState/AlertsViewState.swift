// The Alerts screen (HANDOFF §5, §7.3.3, PROGRESS D17, D27). Built from AlertEngine's
// `AlertSettings` by `AlertsMapping`; edits go back through AlertsActions → `AppModel` →
// `AppServices.updateAlertSettings`. Rows are AlertEngine's own `AlertKind`s, and every range the
// screen offers comes from `AlertLimits` — one source of truth, so the screen can never offer a
// value the engine would clamp. AlertEngine enforces S7 again; this screen also never offers a way
// to disable urgent low or snooze it longer than 30 minutes.

import AlertEngine
import Foundation

// `AlertKind` in this module is AlertEngine's: the app has no alert enum of its own.
extension AlertKind {
    /// S7: urgent low (≤ 55 mg/dL) cannot be turned off.
    var canBeDisabled: Bool { self != .urgentLow }

    /// Snooze lengths the settings accept: urgent low 1–30 min (S7), others `AlertLimits.snoozeMinutes`.
    var snoozeRange: ClosedRange<Int> {
        self == .urgentLow ? AlertLimits.urgentLowSnoozeMinutes : AlertLimits.snoozeMinutes
    }

    /// S7: urgent low snoozes for at most 30 minutes (`AlertLimits.urgentLowMaximumSnoozeMinutes`).
    var maxSnoozeMinutes: Int { snoozeRange.upperBound }

    /// S7 / D17: urgent low always sounds on silent; the others have a per-alert setting.
    var soundOnSilentIsFixed: Bool { self == .urgentLow }

    /// D27 (HANDOFF §5): quiet hours silence every alert except urgent low. There is no per-alert
    /// quiet-hours setting.
    var soundsDuringQuietHours: Bool { self == .urgentLow }

    var title: String {
        switch self {
        case .urgentLow: return "Urgent low"
        case .urgentLowSoon: return "Urgent low soon"
        case .low: return "Low"
        case .high: return "High"
        case .fallingFast: return "Falling fast"
        case .risingFast: return "Rising fast"
        case .missedReadings: return "Missed readings"
        case .sensorWarmUpComplete: return "Warm-up complete"
        case .sensorExpiringIn24Hours: return "Sensor expires in 24 h"
        case .sensorExpiringIn12Hours: return "Sensor expires in 12 h"
        case .sensorExpiringIn2Hours: return "Sensor expires in 2 h"
        case .sensorGracePeriod: return "Grace period started"
        case .sensorFailed: return "Sensor failed"
        case .sensorError: return "Sensor error"
        case .calibrationNeeded: return "Calibration needed"
        case .sensorExpired: return "Sensor expired"
        case .bluetoothUnavailable: return "Bluetooth unavailable"
        case .trioBridge: return "Trio handoff failing"
        case .storageFailing: return "History isn't being saved"
        }
    }

    var section: AlertSection {
        if AlertKind.sensorExpiryReminders.contains(self) { return .expiryReminders }
        switch self {
        case .urgentLow, .urgentLowSoon, .low, .high, .fallingFast, .risingFast: return .glucose
        case .missedReadings, .bluetoothUnavailable, .trioBridge, .storageFailing: return .dataFlow
        case .sensorWarmUpComplete, .sensorFailed, .sensorError, .calibrationNeeded: return .sensor
        case .sensorExpiringIn24Hours, .sensorExpiringIn12Hours, .sensorExpiringIn2Hours, .sensorGracePeriod, .sensorExpired:
            return .expiryReminders // listed in `sensorExpiryReminders`; kept for exhaustiveness
        }
    }
}

enum AlertSection: String, CaseIterable, Sendable {
    case glucose = "GLUCOSE"
    case dataFlow = "READINGS & TRIO"
    case sensor = "SENSOR"
    /// D43: 24 h, 12 h, 2 h, grace start, expired — in the order they come due.
    case expiryReminders = "SENSOR EXPIRY REMINDERS"
}

/// A configurable threshold (HANDOFF §5 "Configurable" column). `allowed` is the `AlertLimits`
/// range for the alert.
enum AlertThreshold: Equatable, Sendable {
    /// Fires at or below (`isBelow`) / at or above the value, mg/dL.
    case glucose(mgdl: Int, isBelow: Bool, allowed: ClosedRange<Int>)
    /// Urgent low soon: projected ≤ `mgdl` (the urgent-low threshold) within `minutes`, from the
    /// sensor-reported rate. Not editable on its own.
    case projected(mgdl: Int, minutes: Int)
    /// Rise/fall rate, mg/dL per minute (absolute value).
    case rate(mgdlPerMinute: Double, allowed: ClosedRange<Double>)
    /// Missed readings window, minutes.
    case window(minutes: Int, allowed: ClosedRange<Int>)
}

struct AlertRow: Equatable, Identifiable, Sendable {
    let kind: AlertKind
    /// Ignored for urgent low, which is always on (S7).
    var isEnabled: Bool
    var threshold: AlertThreshold?
    var soundID: AlertSoundID
    /// D17: play the alarm through the ringer switch (in-app audio while awake). Always true for
    /// urgent low.
    var soundOnSilent: Bool
    /// Re-alert interval / acknowledge duration, if the alert has one (one-off announcements don't).
    var snoozeMinutes: Int?
    /// High only: fire after this many minutes above the threshold (HANDOFF §5 "delay").
    var delayMinutes: Int?
    /// Urgent low only: repeat an unacknowledged alert this often (HANDOFF §4.7).
    var repeatMinutes: Int?
    /// D53: how the alert gets attention — its sound, a vibration without sound, or (one-off
    /// announcements) a silent notification. Urgent low is always `.sound` (S7).
    var style: AlertStyleChoice = .sound
    /// The styles the person may choose; empty for urgent low, which has no style control (S7).
    var allowedStyles: [AlertStyleChoice] = []

    var id: AlertKind { kind }

    /// What the row shows as on/off. Urgent low reads as on whatever `isEnabled` holds (S7).
    var effectiveIsEnabled: Bool { kind.canBeDisabled ? isEnabled : true }
    var effectiveSoundOnSilent: Bool { kind.soundOnSilentIsFixed ? true : soundOnSilent }
    /// The sound picker and "Sound on silent" apply only when the alert plays its sound.
    var showsSoundSettings: Bool { style == .sound }
}

/// D53 alert style, the screen's side. Mirrors AlertEngine's `AlertStyle` (WS4: `.sound`,
/// `.vibrateOnly`, `.silent` for one-off events); `AlertStyleAdapter` is the only place that talks to
/// the engine about it.
enum AlertStyleChoice: String, CaseIterable, Identifiable, Sendable {
    case sound
    case vibrateOnly
    case silent

    var id: String { rawValue }
}

struct AlertSound: Equatable, Identifiable, Sendable {
    let id: AlertSoundID
    let name: String
    /// What it sounds like (the picker's second line).
    let character: String
}

/// A time of day for display ("10 PM"); quiet hours store minutes after midnight.
struct TimeOfDay: Equatable, Sendable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    init(minuteOfDay: Int) {
        let minutes = ((minuteOfDay % 1_440) + 1_440) % 1_440
        self.init(hour: minutes / 60, minute: minutes % 60)
    }

    var minuteOfDay: Int { hour * 60 + minute }
}

struct AlertsViewState: Equatable, Sendable {
    var rows: [AlertRow]
    var sounds: [AlertSound]
    /// AlertEngine's quiet hours (D27: everything except urgent low).
    var quietHours: QuietHours

    func row(_ kind: AlertKind) -> AlertRow? { rows.first { $0.kind == kind } }

    /// The rows of one section; the expiry reminders in the order they come due (D43).
    func rows(in section: AlertSection) -> [AlertRow] {
        let inSection = rows.filter { $0.kind.section == section }
        guard section == .expiryReminders else { return inSection }
        let order = AlertKind.sensorExpiryReminders
        return inSection.sorted { (order.firstIndex(of: $0.kind) ?? .max) < (order.firstIndex(of: $1.kind) ?? .max) }
    }
    func soundName(_ id: AlertSoundID) -> String {
        sounds.first { $0.id == id }?.name ?? AlertSoundCatalog.displayName(id)
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

    /// Snooze choices offered for an alert: never outside its `AlertLimits` range (S7: at most 30
    /// minutes for urgent low). The current value is always offered, so the picker shows it.
    static func snoozeOptions(for kind: AlertKind, current: Int? = nil) -> [Int] {
        let range = kind.snoozeRange
        var options = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240].filter(range.contains)
        if let current, range.contains(current), !options.contains(current) {
            options.append(current)
            options.sort()
        }
        return options
    }

    /// Explanation under the urgent low row (S7).
    /// D44: a snooze ends with the alarm again, reading or not, unless a reading above the limit
    /// arrived during it.
    static let urgentLowNote = "Always on and always sounds, even on silent. It can't be turned off; you can snooze it for up to 30 minutes. When the snooze ends it rings again, even if no new reading has come in, unless a reading above the limit arrived first."

    /// D27 wording (HANDOFF §5): nothing but urgent low sounds during quiet hours.
    static let quietHoursNote = "Silences all alerts except Urgent low."

    /// "10 PM – 7 AM"
    static func quietHoursSchedule(_ quietHours: QuietHours) -> String {
        "\(time(TimeOfDay(minuteOfDay: quietHours.startMinuteOfDay))) – \(time(TimeOfDay(minuteOfDay: quietHours.endMinuteOfDay)))"
    }

    /// The expiry reminders' section note (D43).
    static let expiryRemindersNote = "Reminders before the sensor's session ends, when the grace period starts, and when it has expired. They arrive even while the app is in the background."

    /// D53: the alert style choice.
    static func styleTitle(_ style: AlertStyleChoice) -> String {
        switch style {
        case .sound: return "Sound"
        case .vibrateOnly: return "Vibrate only"
        case .silent: return "Silent"
        }
    }

    /// One line under the choice; nil for Sound (the sound settings follow).
    static func styleNote(_ style: AlertStyleChoice) -> String? {
        switch style {
        case .sound: return nil
        case .vibrateOnly: return "Vibrates without sound. Easy to miss while asleep."
        case .silent: return "The notification appears without sound or vibration."
        }
    }

    /// Urgent low's detail page instead of a style choice (S7).
    static let urgentLowStyleNote = "Urgent low always sounds (it can't be set to vibrate)."

    /// The Alerts list subtitle's sound part: "vibrate only", "no sound", or the sound name with
    /// "sounds on silent".
    static func soundSummary(_ row: AlertRow, soundName: String) -> [String] {
        switch row.style {
        case .vibrateOnly: return ["vibrate only"]
        case .silent: return ["no sound"]
        case .sound: return row.effectiveSoundOnSilent ? [soundName, "sounds on silent"] : [soundName]
        }
    }

    /// D53 convenience ("most of my notifications to vibrate, except for the critical ones").
    static let vibrateAllButton = "Set all to vibrate except urgent low"
    static let vibrateAllTitle = "Vibrate instead of sound?"
    static let vibrateAllMessage = "Every alert that plays a sound, except urgent low, will vibrate without sound. Urgent low keeps sounding. Change any alert back on its page."
    static let vibrateAllConfirm = "Set to vibrate"

    /// "Sound on silent" row detail (D17).
    static let soundOnSilentNote = "Plays the alarm with the ringer switch off while the app is running. Otherwise the alert follows the ringer switch."

    static func time(_ time: TimeOfDay) -> String {
        let twelve = time.hour % 12 == 0 ? 12 : time.hour % 12
        let suffix = time.hour < 12 ? "AM" : "PM"
        return time.minute == 0 ? "\(twelve) \(suffix)" : "\(twelve):\(time.minute < 10 ? "0" : "")\(time.minute) \(suffix)"
    }
}
