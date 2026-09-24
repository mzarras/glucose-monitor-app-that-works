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
    let calendar: Calendar
    let locale: Locale
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
        case .sensorExpiringIn2Hours: return "Sensor expires within 2 hours"
        case .sensorGracePeriod: return "Sensor grace period"
        case .sensorFailed: return "Sensor failed"
        case .sensorError: return "Sensor error"
        case .sensorExpired: return "Sensor expired"
        case .bluetoothUnavailable: return "Bluetooth unavailable"
        case .trioBridge: return "Trio isn't getting readings"
        }
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
        case .sensorExpiringIn24Hours, .sensorExpiringIn2Hours:
            if case .active(_, let expiresAt) = c.settledSensorState {
                return "The session ends \(dateTime(expiresAt, c)). Plan a sensor change."
            }
            return "Plan a sensor change."
        case .sensorGracePeriod:
            if case .gracePeriod(let endsAt) = c.settledSensorState {
                return "Readings stop \(dateTime(endsAt, c)). Change the sensor soon."
            }
            return "Change the sensor soon."
        case .sensorFailed:
            if case .failed(let reason) = c.settledSensorState {
                return "Readings have stopped. The sensor reported: \(reason)."
            }
            return "Readings have stopped."
        case .sensorError:
            if case .error(let code, let description) = c.settledSensorState {
                return "The sensor reported error \(code): \(description)."
            }
            return "The sensor reported an error."
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
