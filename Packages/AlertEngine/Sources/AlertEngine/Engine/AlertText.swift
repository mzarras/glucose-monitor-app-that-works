// Notification titles and bodies. Rules: LOW/HIGH are written as flags, never as 40/400 (S4);
// every glucose value is written with the time it was measured, so a repeat that fires later can
// never pass an old value off as current (S1); nothing projected or computed is ever shown as a
// glucose value (S1).

import Foundation
import GlucoseCore

struct AlertTextContext {
    /// The latest live reading, whether or not it is still current.
    let reading: LiveReadingSummary?
    /// The newest valid reading of any kind (live or backfill); `nil` if none since launch.
    let lastValidReadingDate: Date?
    let settings: AlertSettings
    let settledSensorState: SensorState?
    let lastReportedSensorState: SensorState?
    let bridgeStatus: TrioBridgeStatus
    var storageHealth: StorageHealth = .ok
    let calendar: Calendar
    let locale: Locale
    /// When the notification is delivered: its fire date, or now. Expiry reminders (D43) are
    /// written for that moment ("tomorrow", time left).
    var deliveredAt: Date?
    /// The current session's expiry and grace end, as the expiry reminders know them (D43).
    var sessionExpiresAt: Date?
    var graceEndsAt: Date?
}

enum AlertText {
    static func title(_ kind: AlertKind) -> String {
        switch kind {
        case .urgentLow: return "Urgent low"
        case .urgentLowSoon: return "Urgent low soon"
        case .low: return "Low"
        case .high: return "High"
        case .fallingFast: return "Falling fast"
        case .risingFast: return "Rising fast"
        case .missedReadings: return "No readings"
        case .sensorWarmUpComplete: return "Sensor ready"
        case .sensorExpiringIn24Hours: return "Sensor expires within 24 hours"
        case .sensorExpiringIn12Hours: return "Sensor expires within 12 hours"
        case .sensorExpiringIn2Hours: return "Sensor expires within 2 hours"
        case .sensorGracePeriod: return "Sensor grace period"
        case .sensorFailed: return "Sensor failed"
        case .sensorError: return "Sensor error"
        case .calibrationNeeded: return "Calibration needed"
        case .sensorExpired: return "Sensor expired"
        case .bluetoothUnavailable: return "Bluetooth unavailable"
        case .trioBridge: return "Trio isn't getting readings"
        case .storageFailing: return "History isn't being saved"
        }
    }

    /// The title for a notification: the sensor alert says what to do about this failure (D36); the
    /// expiry reminders state the time left and the clock time (D43).
    static func title(_ kind: AlertKind, context c: AlertTextContext) -> String {
        switch kind {
        case .sensorFailed:
            if case .failed(let failure) = c.settledSensorState {
                if failure.requiresPairing { return "Pair the sensor again" }
                if failure.requiresSensorReplacement { return "Replace the sensor" }
                // `.other` (D37): a failure the source could not classify; its message says what it is.
                return "Sensor problem"
            }
        case .sensorExpiringIn24Hours, .sensorExpiringIn12Hours:
            if let expiry = c.sessionExpiresAt, let at = c.deliveredAt {
                return "Sensor expires in \(duration(expiry.timeIntervalSince(at)))"
            }
        case .sensorExpiringIn2Hours:
            if let expiry = c.sessionExpiresAt, let at = c.deliveredAt {
                return "Sensor expires in \(duration(expiry.timeIntervalSince(at))) (at \(time(expiry, c)))"
            }
        case .sensorGracePeriod:
            guard let graceEnd = c.graceEndsAt, let at = c.deliveredAt else { return "Sensor session ended — grace period" }
            if let expiry = c.sessionExpiresAt, abs(at.timeIntervalSince(expiry)) < 60 {
                return "Sensor session ended — \(shortDuration(graceEnd.timeIntervalSince(expiry))) grace period"
            }
            return "Sensor session ended — \(shortDuration(graceEnd.timeIntervalSince(at))) of grace period left"
        default:
            break
        }
        return title(kind)
    }

    /// `isRepeat`: a pre-scheduled urgent-low repeat, written for the moment it fires.
    static func body(_ kind: AlertKind, context c: AlertTextContext, isRepeat: Bool) -> String {
        switch kind {
        case .urgentLow:
            let reading = readingText(c)
            return isRepeat ? "Not acknowledged. Last reading \(reading)." : "\(reading). Treat now."
        case .urgentLowSoon:
            let threshold = c.settings.urgentLow.thresholdMgdl
            return "\(readingText(c)), \(rateText(c.reading?.trendRate)). At that rate it reaches "
                + "\(threshold) mg/dL within \(AlertLimits.urgentLowSoonHorizonMinutes) min."
        case .low, .high:
            return "\(readingText(c))."
        case .fallingFast, .risingFast:
            return "\(capitalizedFirst(rateText(c.reading?.trendRate))). \(readingText(c))."
        case .missedReadings:
            if let last = c.lastValidReadingDate {
                return "No valid reading since \(time(last, c))."
            }
            return "No valid reading in the last \(c.settings.missedReadings.windowMinutes) min."
        case .sensorWarmUpComplete:
            return "Warm-up is complete. Readings are starting."
        case .sensorExpiringIn24Hours, .sensorExpiringIn12Hours:
            guard let expiry = c.sessionExpiresAt else { return "Plan a sensor change." }
            let at = c.deliveredAt ?? expiry
            return "The session ends \(day(expiry, from: at, c)) at \(time(expiry, c)).\(gracePeriodFollows(c))"
        case .sensorExpiringIn2Hours:
            return "Plan a sensor change.\(gracePeriodFollows(c))"
        case .sensorGracePeriod:
            guard let graceEnd = c.graceEndsAt else { return "Replace the sensor soon." }
            let at = c.deliveredAt ?? graceEnd
            return "Readings stop at \(time(graceEnd, c)) \(day(graceEnd, from: at, c)). Replace the sensor before then."
        case .sensorFailed:
            if case .failed(let failure) = c.settledSensorState {
                // The source's text, written for the person wearing the sensor (D36).
                return "Readings have stopped. \(failure.message)"
            }
            return "Readings have stopped."
        case .sensorError:
            if case .error(let code, let description) = c.settledSensorState {
                return "The sensor reported error \(code): \(description)."
            }
            return "The sensor reported an error."
        case .calibrationNeeded:
            switch c.settledSensorState {
            case .calibrationError(let code):
                return "The sensor could not use the calibration (state \(code)). No readings until it is calibrated again."
            case .calibrationNeeded(let code):
                return "The sensor needs a calibration (state \(code)). No readings until it is calibrated."
            default:
                return "The sensor needs a calibration."
            }
        case .sensorExpired:
            return "The session has ended. No readings until a new sensor is paired."
        case .bluetoothUnavailable:
            if case .bluetoothUnavailable(let issue) = c.lastReportedSensorState {
                switch issue {
                case .poweredOff: return "Bluetooth is off. No readings can arrive."
                case .unauthorized: return "Bluetooth permission is off for this app. No readings can arrive."
                case .unsupported: return "This phone cannot use Bluetooth LE. No readings can arrive."
                case .resetting: return "Bluetooth is restarting."
                }
            }
            return "No readings can arrive."
        case .trioBridge:
            switch c.bridgeStatus {
            case .writeFailing(_, let reason): return "Writing readings to Trio fails: \(reason)."
            case .notConsumedSince(let since): return "Trio has not read a new reading since \(time(since, c))."
            case .off, .healthy: return "Trio is not receiving readings."
            }
        case .storageFailing:
            let since: String
            if case .failing(let date) = c.storageHealth {
                since = " since \(time(date, c))"
            } else {
                since = ""
            }
            return "Readings could not be saved on the phone\(since). Alerts and Trio still get them; "
                + "history and charts will have a gap. Check free storage."
        }
    }

    /// "52 mg/dL at 3:12 AM", "LOW (below sensor range) at 3:12 AM" (S4). Always with the time of
    /// measurement (S1).
    static func readingText(_ c: AlertTextContext) -> String {
        guard let reading = c.reading else { return "No recent reading" }
        return "\(valueText(reading.value)) at \(time(reading.date, c))"
    }

    static func valueText(_ value: GlucoseValue) -> String {
        switch value {
        case .mgdl(let mgdl): return "\(mgdl) mg/dL"
        case .belowRange: return "LOW (below sensor range)"
        case .aboveRange: return "HIGH (above sensor range)"
        }
    }

    /// The sensor-reported rate, exactly as reported, one decimal place.
    static func rateText(_ rate: Double?) -> String {
        guard let rate, rate.isFinite else { return "trend not reported" }
        let magnitude = String(format: "%.1f", abs(rate))
        if rate < 0 { return "falling \(magnitude) mg/dL/min" }
        if rate > 0 { return "rising \(magnitude) mg/dL/min" }
        return "steady"
    }

    /// " A 12-hour grace period follows." when the session's grace period is known, else "".
    private static func gracePeriodFollows(_ c: AlertTextContext) -> String {
        guard let expiry = c.sessionExpiresAt, let graceEnd = c.graceEndsAt, graceEnd > expiry else { return "" }
        let minutes = Int((graceEnd.timeIntervalSince(expiry) / 60).rounded())
        let length = minutes % 60 == 0 ? "\(minutes / 60)-hour" : shortDuration(graceEnd.timeIntervalSince(expiry))
        // "An 8-hour", "An 11 h 30 min", "A 12-hour".
        let spoken = length.prefix { $0.isNumber }
        let article = spoken.hasPrefix("8") || spoken == "11" || spoken == "18" ? "An" : "A"
        return " \(article) \(length) grace period follows."
    }

    /// "today", "tomorrow" or "on Sep 25, 2026": `date`'s day as seen from `reference`.
    static func day(_ date: Date, from reference: Date, _ c: AlertTextContext) -> String {
        let calendar = c.calendar
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: reference), to: calendar.startOfDay(for: date)).day
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        default:
            return "on " + plainSpaces(date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: c.locale,
                                                                       calendar: calendar, timeZone: calendar.timeZone)))
        }
    }

    /// Time left, to the minute: "24 hours", "1 hour", "45 minutes", "20 h 15 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int((seconds / 60).rounded()))
        let hours = total / 60
        let minutes = total % 60
        if total == 0 { return "less than a minute" }
        if minutes == 0 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        if hours == 0 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        return "\(hours) h \(minutes) min"
    }

    /// Time left, short, to the minute: "12 h", "9 h 20 min", "45 min".
    static func shortDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int((seconds / 60).rounded()))
        let hours = total / 60
        let minutes = total % 60
        if hours == 0 { return "\(minutes) min" }
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }

    static func time(_ date: Date, _ c: AlertTextContext) -> String {
        plainSpaces(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: c.locale, calendar: c.calendar, timeZone: c.calendar.timeZone)))
    }

    static func dateTime(_ date: Date, _ c: AlertTextContext) -> String {
        plainSpaces(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: c.locale, calendar: c.calendar, timeZone: c.calendar.timeZone)))
    }

    /// Foundation puts a narrow no-break space (U+202F) before "AM"/"PM"; use an ordinary space.
    private static func plainSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private static func capitalizedFirst(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
