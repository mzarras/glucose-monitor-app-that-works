// Pure text for the Now screen: what the hero shows, the state line, and the status rows.
// Unit-tested in NowFormattingTests (test_S5_… for hero replacement).

import Foundation
import GlucoseCore
import WidgetCore

/// What occupies the hero area.
enum NowHero: Equatable, Sendable {
    /// A current reading: the big number (or LOW/HIGH), arrow, unit and delta.
    case reading(LatestReading)
    /// Stale or invalid: a message instead of the number (S5). A last value, if quoted, is part of
    /// a sentence with its time, never on its own.
    case message(title: String, detail: String, action: HeroAction?)

    enum HeroAction: Equatable, Sendable {
        case pairSensor
        /// The sensor being worn no longer accepts this phone (D36): pair it again with its code
        /// (Settings › Sensor, G7Kit `pairAgain(code:)`), not the new-sensor flow.
        case pairAgain
        /// The sensor asks for a calibration (D36).
        case calibrate

        var title: String {
            switch self {
            case .pairSensor: return "Pair a sensor"
            case .pairAgain: return "Pair again"
            case .calibrate: return "Calibrate"
            }
        }
    }

    static func make(_ display: GlucoseDisplayState, now: Date, context: DisplayContext = .current) -> NowHero {
        switch display {
        case .current(let reading):
            return .reading(reading)
        case .stale(let reading):
            let minutes = AgeText.wholeMinutes(from: reading.date, to: now)
            return .message(
                title: "No reading for \(TimeText.minutesPhrase(minutes))",
                detail: "Last reading \(GlucoseText.valueWithUnit(reading.value)) at \(TimeText.time(reading.date, context)). Keep your phone near the sensor; readings usually resume on their own.",
                action: nil)
        case .noData(let last):
            if let last {
                let minutes = AgeText.wholeMinutes(from: last.date, to: now)
                return .message(
                    title: "No recent readings",
                    detail: "Last reading \(GlucoseText.valueWithUnit(last.value)) at \(TimeText.time(last.date, context)), \(AgeText.long(minutes: minutes)). Check the sensor and keep your phone nearby.",
                    action: nil)
            }
            return .message(title: "No readings yet", detail: "Waiting for the sensor's first reading.", action: nil)
        case .warmingUp(let endsAt):
            return .message(
                title: "Warming up",
                detail: "First reading expected around \(TimeText.time(endsAt, context)), in \(TimeText.duration(endsAt.timeIntervalSince(now))).",
                action: nil)
        case .sensorExpired:
            return .message(title: "Sensor expired", detail: "This sensor has stopped sending readings. Start a new sensor.", action: .pairSensor)
        case .sensorError(let message, _):
            return .message(title: "Sensor error", detail: "\(message). Readings are paused.", action: nil)
        case .sensorFailed(let failure, _):
            // The source's own words (D36); the title and the action come from the kind.
            if failure.requiresPairing {
                return .message(title: "Pair the sensor again", detail: PairingGuidance.pairAgainDetail(failure), action: .pairAgain)
            }
            if failure.requiresSensorReplacement {
                return .message(title: "Replace the sensor", detail: failure.message, action: .pairSensor)
            }
            // D37: a failure the source could not classify fails loud.
            return .message(title: "Sensor problem", detail: failure.message, action: nil)
        case .calibrationNeeded:
            return .message(
                title: "Calibrate the sensor",
                detail: "The sensor needs a fingerstick calibration before it sends readings again. Use a fresh fingerstick from washed, dry hands.",
                action: .calibrate)
        case .calibrationRejected:
            return .message(
                title: "Calibration not accepted",
                detail: "The sensor couldn't use the last calibration and is withholding readings. Enter a new fingerstick.",
                action: .calibrate)
        case .notPaired:
            return .message(title: "No sensor paired", detail: "Pair a G7 sensor to start receiving readings.", action: .pairSensor)
        case .clockMismatch(let latest):
            return .message(
                title: "Phone clock doesn't match",
                detail: "The latest reading is dated \(TimeText.time(latest.date, context)), which doesn't match this phone's clock, so it can't be shown as current. Check Settings › General › Date & Time and turn on Set Automatically.",
                action: nil)
        }
    }
}

/// The mono line under the hero, e.g. "STEADY · IN RANGE · 3 MIN AGO".
struct StateLine: Equatable, Sendable {
    enum Dot: Equatable, Sendable {
        case band(GlucoseBand)
        case alert
        case muted
    }

    let text: String
    let dot: Dot

    static func make(_ display: GlucoseDisplayState, sensorState: SensorState, now: Date, context: DisplayContext = .current) -> StateLine {
        switch display {
        case .current(let reading):
            let minutes = AgeText.wholeMinutes(from: reading.date, to: now)
            let text = [TrendText.word(reading.trend).uppercased(), BandText.upper(reading.value), AgeText.upper(minutes: minutes)]
                .joined(separator: " · ")
            return StateLine(text: text, dot: .band(reading.value.band))
        case .stale(let reading):
            return StateLine(text: "STALE · LAST READING \(AgeText.upper(minutes: AgeText.wholeMinutes(from: reading.date, to: now)))", dot: .alert)
        case .noData:
            return StateLine(text: "NO DATA · \(SensorStatusText.connection(sensorState).uppercased())", dot: .alert)
        case .warmingUp(let endsAt):
            return StateLine(text: "WARMING UP · READY \(TimeText.time(endsAt, context).uppercased())", dot: .muted)
        case .sensorExpired:
            return StateLine(text: "SENSOR EXPIRED", dot: .alert)
        case .sensorError:
            return StateLine(text: "SENSOR ERROR", dot: .alert)
        case .sensorFailed(let failure, _):
            let text = failure.requiresPairing ? "PAIR THE SENSOR AGAIN" : failure.requiresSensorReplacement ? "REPLACE THE SENSOR" : "SENSOR PROBLEM"
            return StateLine(text: text, dot: .alert)
        case .calibrationNeeded:
            return StateLine(text: "CALIBRATION NEEDED", dot: .alert)
        case .calibrationRejected:
            return StateLine(text: "CALIBRATION NOT ACCEPTED", dot: .alert)
        case .notPaired:
            return StateLine(text: "NO SENSOR PAIRED", dot: .muted)
        case .clockMismatch:
            return StateLine(text: "CLOCK MISMATCH · NO CURRENT READING", dot: .alert)
        }
    }
}

enum SensorStatusText {
    /// Now screen SENSOR row, e.g. "day 6 of 10 · 4d 7h left".
    static func row(_ state: SensorState, now: Date, context: DisplayContext = .current) -> String {
        switch state {
        case .active(let start, let expiresAt):
            let day = Int(now.timeIntervalSince(start) / 86_400) + 1
            let totalDays = Int((expiresAt.timeIntervalSince(start) / 86_400).rounded())
            let left = expiresAt.timeIntervalSince(now)
            if left <= 0 { return "day \(day) of \(totalDays) · expiry reached" }
            return "day \(max(1, day)) of \(totalDays) · \(TimeText.duration(left)) left"
        case .warmingUp(let endsAt):
            return now < endsAt
                ? "warming up · ready \(TimeText.time(endsAt, context))"
                : "warm-up finished · waiting for reading"
        case .gracePeriod(let endsAt):
            return now < endsAt ? "grace period · \(TimeText.duration(endsAt.timeIntervalSince(now))) left" : "expired"
        case .expired:
            return "expired"
        case .notPaired, .searching, .connecting, .authenticating, .failed, .error, .calibrationNeeded, .calibrationError, .bluetoothUnavailable:
            return connection(state)
        }
    }

    /// Short connection word, lower case.
    static func connection(_ state: SensorState) -> String {
        switch state {
        case .notPaired: return "not paired"
        case .searching: return "searching for sensor"
        case .connecting: return "connecting"
        case .authenticating: return "authenticating"
        case .warmingUp: return "warming up"
        case .active: return "waiting for sensor"
        case .gracePeriod: return "grace period"
        case .expired: return "sensor expired"
        case .failed(let failure):
            if failure.requiresSensorReplacement { return "replace sensor" }
            if failure.requiresPairing { return "pair again" }
            if failure.raisesSensorAlert { return "sensor problem" }
            return "readings interrupted"
        case .error(let code, _): return "sensor error \(code)"
        case .calibrationNeeded: return "calibration needed"
        case .calibrationError: return "calibration not accepted"
        case .bluetoothUnavailable(.poweredOff): return "Bluetooth off"
        case .bluetoothUnavailable(.unauthorized): return "Bluetooth not allowed"
        case .bluetoothUnavailable(.unsupported): return "Bluetooth unsupported"
        case .bluetoothUnavailable(.resetting): return "Bluetooth restarting"
        }
    }
}

enum TrioStatusText {
    /// Now screen TRIO row, e.g. "handed off 12:35".
    static func row(_ status: TrioStatus, context: DisplayContext = .current) -> String {
        switch status {
        case .off: return "off"
        case .ok(let last?): return "handed off \(TimeText.time(last, context))"
        case .ok(nil): return "no handoff yet"
        case .failing(let since, _): return "failing since \(TimeText.time(since, context))"
        }
    }
}

enum UploadStatusText {
    static func row(_ status: UploadStatus, context: DisplayContext = .current) -> String {
        switch status {
        case .off: return "off"
        case .ok(let last?): return "uploaded \(TimeText.time(last, context))"
        case .ok(nil): return "no upload yet"
        case .failing(let count, _, let since):
            return "\(count) \(count == 1 ? "failure" : "failures") since \(TimeText.time(since, context))"
        case .notSetUp:
            return "not set up"
        }
    }
}
