// Alerts screen ⇄ AlertEngine's `AlertSettings` (HANDOFF §5; docs/alerts.md §3). Pure.
//
// `make` turns the engine's settings into rows; `apply` turns one screen edit into new settings.
// Every range comes from `AlertLimits` and every write goes through the settings types' own
// clamping setters, so nothing here can store a value the engine would not (S7: urgent low has no
// on/off and no sound-on-silent switch, its snooze is 1–30 minutes).

import AlertEngine
import Foundation

/// One change from the Alerts screen.
enum AlertEdit: Equatable, Sendable {
    case enabled(AlertKind, Bool)
    /// Glucose threshold (urgent low, low, high), mg/dL.
    case glucoseThreshold(AlertKind, Int)
    /// Rate threshold (falling fast, rising fast), mg/dL per minute.
    case rateThreshold(AlertKind, Double)
    /// Missed-readings window, minutes.
    case window(AlertKind, Int)
    case sound(AlertKind, AlertSoundID)
    case soundOnSilent(AlertKind, Bool)
    case snooze(AlertKind, Int)
    /// High: fire after N minutes above.
    case delay(AlertKind, Int)
    /// Urgent low: repeat interval, minutes.
    case repeatInterval(AlertKind, Int)
    /// D53: Sound / Vibrate only / Silent (one-off events). Refused for urgent low (S7).
    case style(AlertKind, AlertStyle)
    /// D53/D54 convenience: every alert on Sound except urgent low and Low to vibrate only
    /// (`AlertsMapping.vibrateAllKinds`). Silent announcements stay silent; urgent low is never
    /// touched (S7); Low keeps its sound (Michael, D54).
    case vibrateAllExceptUrgentLowAndLow
    case quietHours(QuietHours)
}

/// D53: the alert style through AlertEngine (`AlertSettings.style(_:)`, `setStyle(_:for:)`,
/// `allowedStyles(for:)`) — the only code that reads or writes it. The engine refuses anything but
/// `.sound` for urgent low (S7) and `.silent` for a condition alert.
enum AlertStyleAdapter {
    static func style(_ kind: AlertKind, in settings: AlertSettings) -> AlertStyle {
        settings.style(kind)
    }

    static func allowedStyles(_ kind: AlertKind) -> [AlertStyle] {
        AlertSettings.allowedStyles(for: kind)
    }

    static func setStyle(_ style: AlertStyle, for kind: AlertKind, in settings: inout AlertSettings) {
        settings.setStyle(style, for: kind)
    }
}

enum AlertsMapping {
    /// Row order on the screen (within each section): the engine's priority order.
    static func make(_ settings: AlertSettings) -> AlertsViewState {
        AlertsViewState(
            rows: AlertKind.allCases.map { row($0, settings) },
            sounds: AlertSoundCatalog.all.map { AlertSound(id: $0.id, name: $0.displayName, character: $0.character) },
            quietHours: settings.quietHours,
            vibrateAllKinds: vibrateAllKinds(settings)
        )
    }

    static func row(_ kind: AlertKind, _ settings: AlertSettings) -> AlertRow {
        var row = AlertRow(
            kind: kind,
            isEnabled: settings.isEnabled(kind),
            threshold: nil,
            soundID: settings.sound(kind),
            soundOnSilent: settings.soundsOnSilent(kind),
            snoozeMinutes: settings.snoozeMinutes(kind),
            delayMinutes: nil,
            repeatMinutes: nil,
            style: AlertStyleAdapter.style(kind, in: settings),
            allowedStyles: AlertStyleAdapter.allowedStyles(kind)
        )
        switch kind {
        case .urgentLow:
            row.threshold = .glucose(mgdl: settings.urgentLow.thresholdMgdl, isBelow: true, allowed: AlertLimits.urgentLowThresholdMgdl)
            row.repeatMinutes = settings.urgentLow.repeatMinutes
        case .urgentLowSoon:
            row.threshold = .projected(mgdl: settings.urgentLow.thresholdMgdl, minutes: AlertLimits.urgentLowSoonHorizonMinutes)
        case .low:
            row.threshold = .glucose(mgdl: settings.low.thresholdMgdl, isBelow: true, allowed: AlertLimits.lowThresholdMgdl)
        case .high:
            row.threshold = .glucose(mgdl: settings.high.thresholdMgdl, isBelow: false, allowed: AlertLimits.highThresholdMgdl)
            row.delayMinutes = settings.high.delayMinutes
        case .fallingFast:
            row.threshold = .rate(mgdlPerMinute: settings.fallingFast.thresholdMgdlPerMinute, allowed: AlertLimits.rateThresholdMgdlPerMinute)
        case .risingFast:
            row.threshold = .rate(mgdlPerMinute: settings.risingFast.thresholdMgdlPerMinute, allowed: AlertLimits.rateThresholdMgdlPerMinute)
        case .missedReadings:
            row.threshold = .window(minutes: settings.missedReadings.windowMinutes, allowed: AlertLimits.missedReadingsWindowMinutes)
        case .sensorWarmUpComplete, .sensorExpiringIn24Hours, .sensorExpiringIn12Hours, .sensorExpiringIn2Hours, .sensorGracePeriod,
             .sensorFailed, .sensorError, .calibrationNeeded, .sensorExpired, .bluetoothUnavailable, .trioBridge, .storageFailing:
            break
        }
        return row
    }

    /// `settings` with `edit` applied. Edits that don't fit the alert (a rate for "Low", a delay for
    /// anything but "High") change nothing. The settings' setters clamp to `AlertLimits`.
    static func apply(_ edit: AlertEdit, to settings: AlertSettings) -> AlertSettings {
        var s = settings
        switch edit {
        case .enabled(let kind, let on):
            s.setEnabled(on, for: kind) // refuses urgent low (S7)
        case .glucoseThreshold(let kind, let mgdl):
            switch kind {
            case .urgentLow: s.urgentLow.thresholdMgdl = mgdl
            case .low: s.low.thresholdMgdl = mgdl
            case .high: s.high.thresholdMgdl = mgdl
            default: break
            }
        case .rateThreshold(let kind, let rate):
            switch kind {
            case .fallingFast: s.fallingFast.thresholdMgdlPerMinute = rate
            case .risingFast: s.risingFast.thresholdMgdlPerMinute = rate
            default: break
            }
        case .window(let kind, let minutes):
            if kind == .missedReadings { s.missedReadings.windowMinutes = minutes }
        case .sound(let kind, let sound):
            s.setSound(sound, for: kind)
        case .soundOnSilent(let kind, let on):
            s.setSoundsOnSilent(on, for: kind) // refuses urgent low (S7)
        case .snooze(let kind, let minutes):
            setSnooze(minutes, for: kind, in: &s)
        case .delay(let kind, let minutes):
            if kind == .high { s.high.delayMinutes = minutes }
        case .repeatInterval(let kind, let minutes):
            if kind == .urgentLow { s.urgentLow.repeatMinutes = minutes }
        case .style(let kind, let style):
            AlertStyleAdapter.setStyle(style, for: kind, in: &s) // refuses urgent low (S7)
        case .vibrateAllExceptUrgentLowAndLow:
            for kind in vibrateAllKinds(s) {
                AlertStyleAdapter.setStyle(.vibrateOnly, for: kind, in: &s)
            }
        case .quietHours(let quietHours):
            s.quietHours = quietHours
        }
        return s
    }

    /// The alerts "Set all to vibrate except urgent low and Low" changes, in screen order: every
    /// alert on Sound that may vibrate, whether on or off, except urgent low (S7) and Low (D54).
    static func vibrateAllKinds(_ settings: AlertSettings) -> [AlertKind] {
        AlertKind.allCases.filter { kind in
            kind != .urgentLow && kind != .low
                && AlertStyleAdapter.style(kind, in: settings) == .sound
                && AlertStyleAdapter.allowedStyles(kind).contains(.vibrateOnly)
        }
    }

    /// Each settings type clamps its own snooze (urgent low 1–30, S7). One-off announcements have none.
    private static func setSnooze(_ minutes: Int, for kind: AlertKind, in s: inout AlertSettings) {
        switch kind {
        case .urgentLow: s.urgentLow.snoozeMinutes = minutes
        case .urgentLowSoon: s.urgentLowSoon.snoozeMinutes = minutes
        case .low: s.low.snoozeMinutes = minutes
        case .high: s.high.snoozeMinutes = minutes
        case .fallingFast: s.fallingFast.snoozeMinutes = minutes
        case .risingFast: s.risingFast.snoozeMinutes = minutes
        case .missedReadings: s.missedReadings.snoozeMinutes = minutes
        case .sensorFailed: s.sensorFailed.snoozeMinutes = minutes
        case .sensorError: s.sensorError.snoozeMinutes = minutes
        case .calibrationNeeded: s.calibrationNeeded.snoozeMinutes = minutes
        case .sensorExpired: s.sensorExpired.snoozeMinutes = minutes
        case .bluetoothUnavailable: s.bluetoothUnavailable.snoozeMinutes = minutes
        case .trioBridge: s.trioBridge.snoozeMinutes = minutes
        case .storageFailing: s.storageFailing.snoozeMinutes = minutes
        case .sensorWarmUpComplete, .sensorExpiringIn24Hours, .sensorExpiringIn12Hours, .sensorExpiringIn2Hours, .sensorGracePeriod:
            break
        }
    }
}
