// Original to Sensor (no ported code). Mapping tables cite their sources.

import Foundation
import GlucoseCore

/// Bluetooth radio/permission state, decoupled from `CBManagerState` so the mapping is testable.
enum G7BluetoothPower: Equatable, Sendable {
    case poweredOn
    case poweredOff
    case unauthorized
    case unsupported
    case resetting
    /// CoreBluetooth has not reported yet (transient at startup).
    case unknown
}

/// Maps sensor-reported status and Bluetooth state to `SensorState` (S2, S5).
enum G7SensorStatus {
    /// S5: every radio problem surfaces as `.bluetoothUnavailable`; nil means "no Bluetooth problem".
    static func state(for power: G7BluetoothPower) -> SensorState? {
        switch power {
        case .poweredOff: return .bluetoothUnavailable(.poweredOff)
        case .unauthorized: return .bluetoothUnavailable(.unauthorized)
        case .unsupported: return .bluetoothUnavailable(.unsupported)
        case .resetting: return .bluetoothUnavailable(.resetting)
        case .poweredOn, .unknown: return nil
        }
    }

    /// The sensor's own status for one `0x4E` (algorithm state, byte 14) within `session`.
    ///
    /// - ok: active until the rated life ends, then grace period, then expired (session bounds are
    ///   derived from the sensor clock, G7SessionClock): the grace end passing by time.
    /// - warm-up, and "stopped" before warm-up has ended (the first message after activation reports
    ///   0x01, G7SensorKit G7GlucoseMessageTests.swift:40-66): warming up.
    /// - expired states (0x0F, 0x18, 0x1A, 0x24): `.error(code: raw state byte, description:)`, like a
    ///   failed state. One report is not a confirmed end (D41): `.expired` makes the alert engine
    ///   suppress missed readings, so it is emitted only for the latched end (`G7SessionEnd.state`,
    ///   two reports, G7ReadingPipeline) or for the grace end passing by time.
    /// - calibration needed (0x04, 0x05, 0x07, 0x0E) / calibration error (0x08, 0x09, 0x0A, 0x0D),
    ///   categories from G7AlgorithmState (xDrip4iOS DexcomAlgorithmState.swift:19-49):
    ///   `.calibrationNeeded(code:)` / `.calibrationError(code:)` with the raw state byte (contract D36).
    /// - everything else (temporary issue, failed, unknown, "stopped" after warm-up):
    ///   `.error(code: raw state byte, description:)` so the reason is visible (S5).
    static func state(for algorithmState: G7AlgorithmState, session: SensorSession, now: Date) -> SensorState {
        switch algorithmState.category {
        case .ok:
            if now < session.expiresAt { return .active(sessionStart: session.start, expiresAt: session.expiresAt) }
            if now < session.gracePeriodEndsAt { return .gracePeriod(endsAt: session.gracePeriodEndsAt) }
            return .expired
        case .warmUp:
            return .warmingUp(endsAt: session.warmUpEndsAt)
        case .stopped where now < session.warmUpEndsAt:
            return .warmingUp(endsAt: session.warmUpEndsAt)
        case .calibrationNeeded:
            return .calibrationNeeded(code: Int(algorithmState.rawValue))
        case .calibrationError:
            return .calibrationError(code: Int(algorithmState.rawValue))
        case .stopped, .temporaryIssue, .sensorFailed, .expired, .unknown:
            return .error(code: Int(algorithmState.rawValue), description: algorithmState.name)
        }
    }

    /// The end this status reports, if it says the session is over for good: expired, failed, or
    /// stopped after warm-up. Temporary issues and calibration states do not end it. "OK but past the
    /// grace end" is not included: that is a time check on the session, so a garbled clock cannot end
    /// a session permanently. One report does not end the session either (G7ReadingPipeline latches
    /// only after two separate reports, at least 60 s of sensor time apart).
    static func sessionEnd(for state: SensorState, algorithmState: G7AlgorithmState) -> G7SessionEnd? {
        switch algorithmState.category {
        case .sensorFailed:
            return .sensorFailed
        case .expired:
            return .expired
        case .stopped:
            if case .warmingUp = state { return nil }
            return .stopped
        case .ok, .warmUp, .calibrationNeeded, .calibrationError, .temporaryIssue, .unknown:
            return nil
        }
    }
}
