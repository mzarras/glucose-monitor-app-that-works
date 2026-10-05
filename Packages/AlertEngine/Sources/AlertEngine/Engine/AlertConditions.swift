// Pure condition checks, one per alert. Each answers only "is the condition true now?" for the
// state machine; none creates, stores, or displays a value (S1).

import Foundation
import GlucoseCore

/// The answer to "is this alert's condition true?".
enum AlertCondition: Equatable {
    /// True: fire (or keep firing).
    case met
    /// Unknown or in the hysteresis band: change nothing. Used when there is no current reading
    /// (S1: a stale value is never evaluated), when the rate is missing, when the value sits
    /// between the threshold and the recovery margin, and for transient sensor states.
    case holding
    /// False: an active episode clears and the alert re-arms.
    case clear
}

/// The latest live, non-backfilled reading, as the engine remembers it.
public struct LiveReadingSummary: Sendable, Equatable, Codable {
    public let id: String
    public let date: Date
    public let value: GlucoseValue
    /// Sensor-reported mg/dL per minute; `nil` if the sensor reported none.
    public let trendRate: Double?

    public init(id: String, date: Date, value: GlucoseValue, trendRate: Double?) {
        self.id = id
        self.date = date
        self.value = value
        self.trendRate = trendRate
    }

    init(_ reading: GlucoseReading) {
        self.init(id: reading.id, date: reading.date, value: reading.value, trendRate: reading.trendRate)
    }
}

enum GlucoseConditions {
    /// Glucose at or below `threshold`. S4: the LOW flag counts as below every threshold and the
    /// HIGH flag as above it, without turning either into a number.
    static func atOrBelow(_ reading: LiveReadingSummary?, threshold: Int) -> AlertCondition {
        guard let reading else { return .holding }
        switch reading.value {
        case .belowRange: return .met
        case .aboveRange: return .clear
        case .mgdl(let value):
            if value <= threshold { return .met }
            if value > threshold + AlertLimits.glucoseRecoveryMarginMgdl { return .clear }
            return .holding
        }
    }

    /// Glucose at or above `threshold`. S4: HIGH counts as above, LOW as below.
    static func atOrAbove(_ reading: LiveReadingSummary?, threshold: Int) -> AlertCondition {
        guard let reading else { return .holding }
        switch reading.value {
        case .aboveRange: return .met
        case .belowRange: return .clear
        case .mgdl(let value):
            if value >= threshold { return .met }
            if value < threshold - AlertLimits.glucoseRecoveryMarginMgdl { return .clear }
            return .holding
        }
    }

    /// Low, superseded by urgent low: while an urgent-low episode is active the low alert clears
    /// so the two never sound together (Loop does the same, GlucoseAlertManager.swift:614-626).
    static func low(_ reading: LiveReadingSummary?, threshold: Int, urgentLowActive: Bool) -> AlertCondition {
        if urgentLowActive { return .clear }
        return atOrBelow(reading, threshold: threshold)
    }

    /// Urgent low soon (HANDOFF §5): the sensor-reported rate, applied for the fixed horizon, takes
    /// the current value to the urgent-low threshold or below. Uses the reported rate only, never
    /// a model; with no reported rate there is no projection at all (S1). The projected number
    /// exists only inside this comparison and is never stored or shown.
    static func urgentLowSoon(_ reading: LiveReadingSummary?, urgentLowThreshold: Int, urgentLowActive: Bool) -> AlertCondition {
        if urgentLowActive { return .clear }
        guard let reading else { return .holding }
        guard case .mgdl(let value) = reading.value else {
            // LOW is urgent low's business; HIGH is nowhere near. Neither is "soon".
            return .clear
        }
        if value <= urgentLowThreshold { return .clear }
        guard let rate = reading.trendRate, rate.isFinite else { return .holding }
        let horizon = Double(AlertLimits.urgentLowSoonHorizonMinutes)
        let reachesThreshold = Double(value) + rate * horizon <= Double(urgentLowThreshold)
        if reachesThreshold { return .met }
        let clearsWithMargin = Double(value) + rate * horizon > Double(urgentLowThreshold + AlertLimits.glucoseRecoveryMarginMgdl)
        return clearsWithMargin ? .clear : .holding
    }

    /// Sensor-reported rate at or below −threshold.
    static func fallingFast(_ reading: LiveReadingSummary?, threshold: Double) -> AlertCondition {
        guard let rate = reading?.trendRate, rate.isFinite else { return .holding }
        if rate <= -threshold { return .met }
        if rate > -(threshold - AlertLimits.rateRecoveryMarginMgdlPerMinute) { return .clear }
        return .holding
    }

    /// Sensor-reported rate at or above +threshold.
    static func risingFast(_ reading: LiveReadingSummary?, threshold: Double) -> AlertCondition {
        guard let rate = reading?.trendRate, rate.isFinite else { return .holding }
        if rate >= threshold { return .met }
        if rate < threshold - AlertLimits.rateRecoveryMarginMgdlPerMinute { return .clear }
        return .holding
    }
}

enum StatusConditions {
    /// States that describe the sensor session. Everything else (searching, connecting,
    /// authenticating, Bluetooth unavailable) happens every 5-minute connection cycle or is about
    /// the phone, and must not fire or clear a sensor alert. A failure counts only if it raises the
    /// sensor alert (the sensor is finished, or needs pairing again: D36); transient failures
    /// (clock mismatch, another app, no value, …) are like a connection cycle — they neither fire
    /// nor clear anything, and missed readings covers readings that stop for long.
    static func isSettled(_ state: SensorState) -> Bool {
        switch state {
        case .notPaired, .warmingUp, .active, .gracePeriod, .expired, .error, .calibrationNeeded, .calibrationError:
            return true
        case .failed(let failure):
            return failure.raisesSensorAlert
        case .searching, .connecting, .authenticating, .bluetoothUnavailable:
            return false
        }
    }

    /// No readings are expected: missed readings would only be noise. With no sensor paired there
    /// is nothing to miss; during warm-up the UI shows a countdown — but only until `endsAt`: after
    /// that, readings are expected whether or not the source ever reports another state (the phone
    /// may be out of range when warm-up ends, or the source may report only a transient failure).
    static func suppressesMissedReadings(_ settled: SensorState?, now: Date, settings: AlertSettings) -> Bool {
        if sessionHasNoReadingsToMiss(settled, settings: settings) { return true }
        if case .warmingUp(let endsAt) = settled { return now < endsAt }
        return false
    }

    /// No sensor, or a confirmed end of the session that another alert is announcing (D39, as
    /// corrected by D41): `.expired` while the sensor-expired alert is on, or a sensor-failed /
    /// session-stopped failure while the sensor-failed alert is on. That alert says so and stays
    /// until a new sensor; missed readings every window on top would add alarms, not information.
    /// Nothing else counts — not a lost pairing, a transient failure, an unsupported sensor, or an
    /// end whose alert is turned off: then missed readings is the only alarm the user gets.
    /// (G7Kit emits `.expired` only for a confirmed end; an unconfirmed report is `.error`.)
    static func sessionHasNoReadingsToMiss(_ settled: SensorState?, settings: AlertSettings) -> Bool {
        switch settled {
        case .notPaired:
            return true
        case .expired:
            return settings.isEnabled(.sensorExpired)
        case .failed(let failure):
            switch failure.kind {
            case .sensorFailed, .sessionStopped: return settings.isEnabled(.sensorFailed)
            default: return false
            }
        default:
            return false
        }
    }

    static func sensorFailed(_ settled: SensorState?) -> AlertCondition {
        guard let settled else { return .holding }
        if case .failed(let failure) = settled, failure.raisesSensorAlert { return .met }
        return .clear
    }

    /// Calibration needed or rejected; clears on any other settled state (e.g. back to active).
    static func calibrationNeeded(_ settled: SensorState?) -> AlertCondition {
        switch settled {
        case nil: return .holding
        case .calibrationNeeded, .calibrationError: return .met
        default: return .clear
        }
    }

    static func sensorError(_ settled: SensorState?) -> AlertCondition {
        guard let settled else { return .holding }
        if case .error = settled { return .met }
        return .clear
    }

    static func sensorExpired(_ settled: SensorState?) -> AlertCondition {
        guard let settled else { return .holding }
        if case .expired = settled { return .met }
        return .clear
    }

    /// `.resetting` lasts seconds while the Bluetooth stack restarts; wait for the next state.
    static func bluetoothUnavailable(_ lastReported: SensorState?) -> AlertCondition {
        guard let lastReported else { return .holding }
        guard case .bluetoothUnavailable(let issue) = lastReported else { return .clear }
        return issue == .resetting ? .holding : .met
    }

    static func trioBridge(_ status: TrioBridgeStatus, now: Date) -> AlertCondition {
        switch status {
        case .off, .healthy: return .clear
        case .writeFailing: return .met
        case .notConsumedSince(let since):
            let limit = TimeInterval(AlertLimits.trioNotConsumingMinutes * 60)
            return now.timeIntervalSince(since) >= limit ? .met : .holding
        }
    }

    /// D42: met once the store has failed continuously for `storageFailingMinutes`.
    static func storageFailing(_ health: StorageHealth, now: Date) -> AlertCondition {
        switch health {
        case .ok: return .clear
        case .failing(let since):
            let limit = TimeInterval(AlertLimits.storageFailingMinutes * 60)
            return now.timeIntervalSince(since) >= limit ? .met : .holding
        }
    }

    static func missedReadings(now: Date, reference: Date, windowMinutes: Int) -> AlertCondition {
        now.timeIntervalSince(reference) >= TimeInterval(windowMinutes * 60) ? .met : .clear
    }
}
