// Calibration entry rules and the step-by-step flow (PROGRESS D16). Pure; unit-tested in
// CalibrationRulesTests.
//
// Flow: enter value → confirm by typing it again (typo protection: 55 vs 155 would shift the
// sensor, and Trio doses on the sensor's readings) → if the value is far from the current reading
// or cannot be compared, an explicit "are you sure" step → submit. A non-flat trend is a warning,
// never a block.

import Foundation
import GlucoseCore
import WidgetCore

enum CalibrationAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
}

enum CalibrationEntry: Equatable, Sendable {
    case empty
    /// Not a whole number of mg/dL.
    case invalid
    case outOfRange(ClosedRange<Int>)
    case valid(Int)
}

/// How the fingerstick compares with the sensor's current reading.
enum CalibrationDifference: Equatable, Sendable {
    /// Within the larger of 20 mg/dL or 20 %: no extra step.
    case withinLimit(sensorMgdl: Int, difference: Int)
    /// Beyond it: "are you sure" step.
    case large(sensorMgdl: Int, difference: Int, limit: Int)
    /// The sensor reads LOW/HIGH, so no numeric comparison is possible (S4): "are you sure".
    case sensorFlag(GlucoseValue)
    /// No current (fresh) reading to compare with: "are you sure".
    case noCurrentReading

    var needsExtraConfirmation: Bool {
        if case .withinLimit = self { return false }
        return true
    }
}

enum CalibrationRules {
    /// Difference limit: the larger of 20 mg/dL or 20 % of the sensor reading (PROGRESS D16).
    static let absoluteLimitMgdl = 20
    /// 20 % as a divisor, so the comparison is exact integer arithmetic (0.2 × 105 is not 21 in
    /// floating point).
    static let relativeLimitDivisor = 5

    static func availability(_ state: CalibrationViewState, now: Date) -> CalibrationAvailability {
        guard state.acceptedRange != nil else {
            return .unavailable(reason: "This sensor doesn't accept calibrations.")
        }
        if let submission = state.lastSubmission, case .status(let status) = submission.outcome, status.isPending {
            return .unavailable(reason: "A calibration is already waiting for the sensor.")
        }
        switch state.sensorState {
        case .notPaired:
            return .unavailable(reason: "No sensor is paired.")
        case .warmingUp(let endsAt) where now < endsAt:
            return .unavailable(reason: "The sensor is warming up. Calibration is possible after \(TimeText.time(endsAt)).")
        case .expired:
            return .unavailable(reason: "The sensor has expired.")
        case .gracePeriod(let endsAt) where now >= endsAt:
            return .unavailable(reason: "The sensor has expired.")
        case .failed(let failure):
            if failure.requiresSensorReplacement {
                return .unavailable(reason: "The sensor has ended. Replace it; a new sensor can be calibrated after warm-up.")
            }
            if failure.requiresPairing {
                return .unavailable(reason: "The sensor needs to be paired again before it can take a calibration.")
            }
            if failure.kind == .clockMismatch {
                // G7Kit refuses a calibration during a clock mismatch (`invalidTime`); say why first.
                return .unavailable(reason: CalibrationRules.clockMismatchReason)
            }
            if failure.raisesSensorAlert {
                return .unavailable(reason: "The sensor reported a problem: \(failure.message)")
            }
            return .unavailable(reason: "The sensor isn't connected right now: \(failure.message)")
        case .error:
            // Conservative: refused during any `.error` (also temporary issues); the sensor's
            // state must be ordinary before a value that shifts every later reading is sent.
            return .unavailable(reason: "The sensor reported an error.")
        case .calibrationNeeded, .calibrationError:
            // Exactly when the sensor asks for one (D36).
            return .available
        case .bluetoothUnavailable:
            return .unavailable(reason: "Bluetooth is unavailable, so the sensor can't receive a calibration.")
        case .searching, .connecting, .authenticating:
            return .unavailable(reason: "Waiting for the sensor to connect.")
        case .warmingUp, .active, .gracePeriod:
            return .available
        }
    }

    static let clockMismatchReason = "Phone clock doesn't match — fix Date & Time first."

    /// Parses the typed fingerstick value. Only ASCII digits (the field uses a number pad).
    static func parse(_ text: String, acceptedRange: ClosedRange<Int>) -> CalibrationEntry {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }
        guard trimmed.count <= 3, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(trimmed) else {
            return .invalid
        }
        guard acceptedRange.contains(value) else { return .outOfRange(acceptedRange) }
        return .valid(value)
    }

    /// Retype step prompt. It never contains the first value (review m4).
    static let retypePrompt = "Type the value again, reading it from your meter rather than from what you typed. This catches a missing or extra digit."

    /// Shown when the two entries differ. It never contains the first value (review m4).
    static let mismatchMessage = "That doesn't match your first entry. Check your meter and type it again, or start over."

    /// The re-typed value must be exactly the same number.
    static func retypeMatches(_ value: Int, retyped: String) -> Bool {
        let trimmed = retyped.trimmingCharacters(in: .whitespaces)
        guard trimmed.allSatisfy({ $0.isASCII && $0.isNumber }), let again = Int(trimmed) else { return false }
        return again == value
    }

    static func differenceLimit(sensorMgdl: Int) -> Double {
        max(Double(absoluteLimitMgdl), Double(sensorMgdl) / Double(relativeLimitDivisor))
    }

    /// More than 20 mg/dL *and* more than 20 % of the sensor reading, i.e. more than the larger of the two.
    static func isLargeDifference(_ difference: Int, sensorMgdl: Int) -> Bool {
        difference > absoluteLimitMgdl && difference * relativeLimitDivisor > sensorMgdl
    }

    /// Compares with the latest live reading, if it is current (< 10 min, same rule as the hero,
    /// including a latched clock mismatch).
    static func difference(fingerstick: Int, latest: LatestReading?, sensorState: SensorState, now: Date, clockMismatchLatchedFor: Date? = nil) -> CalibrationDifference {
        let display = ClockMismatchLatch.apply(
            GlucoseDisplayState.classify(latest: latest, sensorState: sensorState, now: now),
            latest: latest, latchedFor: clockMismatchLatchedFor)
        guard case .current(let reading) = display else {
            return .noCurrentReading
        }
        guard let sensor = reading.value.numericMgdl else { return .sensorFlag(reading.value) }
        let difference = abs(fingerstick - sensor)
        if isLargeDifference(difference, sensorMgdl: sensor) {
            // Shown to the user; whole mg/dL, rounded down so "more than the limit" stays true.
            let limit = max(absoluteLimitMgdl, sensor / relativeLimitDivisor)
            return .large(sensorMgdl: sensor, difference: difference, limit: limit)
        }
        return .withinLimit(sensorMgdl: sensor, difference: difference)
    }

    /// Advice when glucose is not steady (a warning; it never blocks).
    static func trendAdvice(latest: LatestReading?) -> String? {
        guard let latest else { return nil }
        switch latest.trend {
        case .flat: return nil
        case .notComputable:
            return "The sensor isn't reporting a trend, so it's unclear whether glucose is steady. Calibrating while glucose is changing can make readings less accurate."
        default:
            return "Glucose is \(TrendText.word(latest.trend)). Calibrations are most accurate when glucose is steady; consider waiting until the trend arrow is flat."
        }
    }

    /// Text for the "are you sure" step.
    static func largeDifferenceMessage(_ difference: CalibrationDifference, fingerstick: Int) -> String? {
        switch difference {
        case .withinLimit:
            return nil
        case .large(let sensor, let diff, let limit):
            return "Your fingerstick (\(fingerstick) mg/dL) differs from the sensor's \(sensor) mg/dL by \(diff) mg/dL — more than the \(limit) mg/dL limit. A wrong calibration shifts every reading after it, and Trio doses from those readings. Wash your hands, re-check with your meter, and only continue if you're sure."
        case .sensorFlag(let value):
            return "The sensor reads \(GlucoseText.value(value)), so your fingerstick (\(fingerstick) mg/dL) can't be compared with it. A wrong calibration shifts every reading after it, and Trio doses from those readings. Only continue if you're sure."
        case .noCurrentReading:
            return "There's no current sensor reading to compare your fingerstick (\(fingerstick) mg/dL) with. A wrong calibration shifts every reading after it, and Trio doses from those readings. Only continue if you're sure."
        }
    }

    /// Status after submitting.
    static func outcomeText(_ outcome: CalibrationSubmission.Outcome) -> (title: String, detail: String) {
        switch outcome {
        case .status(.queued):
            return ("Waiting for sensor", "It will be sent at the next connection, within about 5 minutes.")
        case .status(.sent):
            return ("Sent to sensor", "Waiting for the sensor's answer.")
        case .status(.accepted):
            return ("Accepted", "The sensor accepted the calibration. Readings after the next connection reflect it.")
        case .status(.rejected(_, let reason)):
            return ("Rejected by the sensor", "\(reason). Readings are unchanged.")
        case .status(.unknown(let description)):
            return ("Outcome unknown", "\(description). Compare the next readings with your meter before relying on them.")
        case .refused(let refusal):
            return ("Not sent", refusalText(refusal))
        }
    }

    static func refusalText(_ refusal: CalibrationRefusal) -> String {
        switch refusal {
        case .notPaired: return "No sensor is paired."
        case .notAuthenticated: return "The sensor isn't connected yet. Try again after the next reading."
        case .warmingUp: return "The sensor is still warming up."
        case .sessionEnded: return "The sensor session has ended."
        case .valueOutOfRange(let range): return "The sensor accepts \(range.lowerBound)–\(range.upperBound) mg/dL."
        case .anotherCalibrationInProgress: return "Another calibration is still waiting for the sensor."
        case .invalidTime: return "Use a fingerstick taken in the last 5 minutes."
        }
    }
}

/// Where the user is in the calibration sheet. A value type the view keeps in `@State`.
struct CalibrationFlow: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        case entry
        /// Value accepted; type it again.
        case confirm(value: Int, takenAt: Date)
        /// Far from (or not comparable with) the sensor: explicit "are you sure".
        case largeDifference(value: Int, takenAt: Date, difference: CalibrationDifference)
        /// Handed to the source; the status comes from `CalibrationViewState.lastSubmission`.
        case submitted(CalibrationRequest)
    }

    var step: Step = .entry
    var entryText = ""
    var confirmText = ""

    /// Entry → confirm. `takenAt` is when the user finished entering the value.
    mutating func continueFromEntry(acceptedRange: ClosedRange<Int>, now: Date) {
        guard case .entry = step, case .valid(let value) = CalibrationRules.parse(entryText, acceptedRange: acceptedRange) else { return }
        confirmText = ""
        step = .confirm(value: value, takenAt: now)
    }

    /// Confirm → are-you-sure, or straight to a request ready to submit.
    /// - Returns: the request to submit, or nil if another step is needed (or the retype doesn't match).
    mutating func continueFromConfirm(latest: LatestReading?, sensorState: SensorState, now: Date, clockMismatchLatchedFor: Date? = nil) -> CalibrationRequest? {
        guard case .confirm(let value, let takenAt) = step, CalibrationRules.retypeMatches(value, retyped: confirmText) else { return nil }
        let difference = CalibrationRules.difference(fingerstick: value, latest: latest, sensorState: sensorState, now: now,
                                                     clockMismatchLatchedFor: clockMismatchLatchedFor)
        if difference.needsExtraConfirmation {
            step = .largeDifference(value: value, takenAt: takenAt, difference: difference)
            return nil
        }
        let request = CalibrationRequest(mgdl: value, takenAt: takenAt)
        step = .submitted(request)
        return request
    }

    /// "Calibrate anyway" on the are-you-sure step.
    mutating func confirmLargeDifference() -> CalibrationRequest? {
        guard case .largeDifference(let value, let takenAt, _) = step else { return nil }
        let request = CalibrationRequest(mgdl: value, takenAt: takenAt)
        step = .submitted(request)
        return request
    }

    /// Back to entry, keeping nothing that was confirmed.
    mutating func startOver() {
        step = .entry
        confirmText = ""
    }

    /// The value is shown for review only once the second entry matches the first (review m4).
    var showsValueForReview: Bool {
        guard case .confirm(let value, _) = step else { return false }
        return CalibrationRules.retypeMatches(value, retyped: confirmText)
    }

    /// Whether the confirm field shows a mismatch: at least as many characters as the value has
    /// digits, and not the same number (no warning while the user is still typing).
    var confirmMismatch: Bool {
        guard case .confirm(let value, _) = step, confirmText.count >= String(value).count else { return false }
        return !CalibrationRules.retypeMatches(value, retyped: confirmText)
    }
}

/// Review minor 4: remembers that the sensor asked for a calibration while its state passes through
/// transient failures (a clock mismatch, another app, …), so the need stays visible. Pure.
enum CalibrationNeed {
    static func update(previous: Bool, sensorState: SensorState) -> Bool {
        switch sensorState {
        case .calibrationNeeded, .calibrationError:
            return true
        case .failed(let failure) where !failure.raisesSensorAlert:
            return previous
        case .searching, .connecting, .authenticating, .bluetoothUnavailable, .error:
            return previous
        case .notPaired, .warmingUp, .active, .gracePeriod, .expired, .failed:
            // Readings resumed (the calibration took), or the sensor/pairing is gone.
            return false
        }
    }
}
