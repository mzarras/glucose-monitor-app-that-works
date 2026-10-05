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
    case quietHours(QuietHours)
}

enum AlertsMapping {
    /// Row order on the screen (within each section): the engine's priority order.
    static func make(_ settings: AlertSettings) -> AlertsViewState {
        AlertsViewState(
            rows: AlertKind.allCases.map { row($0, settings) },
            sounds: AlertSoundCatalog.all.map { AlertSound(id: $0.id, name: $0.displayName, character: $0.character) },
            quietHours: settings.quietHours
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
            repeatMinutes: nil
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
        case .sensorWarmUpComplete, .sensorExpiringIn24Hours, .sensorExpiringIn2Hours, .sensorGracePeriod, .sensorFailed, .sensorError,
             .calibrationNeeded, .sensorExpired, .bluetoothUnavailable, .trioBridge, .storageFailing:
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
        case .quietHours(let quietHours):
            s.quietHours = quietHours
        }
        return s
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
        case .sensorWarmUpComplete, .sensorExpiringIn24Hours, .sensorExpiringIn2Hours, .sensorGracePeriod:
            break
        }
    }
}
