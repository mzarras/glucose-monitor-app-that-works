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
    ///   derived from the sensor clock, G7SessionClock).
    /// - warm-up, and "stopped" before warm-up has ended (the first message after activation reports
    ///   0x01, G7SensorKit G7GlucoseMessageTests.swift:40-66): warming up.
    /// - expired states: expired.
    /// - everything else (calibration needed/error, temporary issue, failed, unknown, "stopped" after
    ///   warm-up): `.error(code: raw state byte, description:)` so the reason is visible (S5).
    ///   Proposed contract refinement for calibration states: OPEN QUESTIONS in the WS1 report.
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
        case .expired:
            return .expired
        case .stopped, .calibrationNeeded, .calibrationError, .temporaryIssue, .sensorFailed, .unknown:
            return .error(code: Int(algorithmState.rawValue), description: algorithmState.name)
        }
    }
}
