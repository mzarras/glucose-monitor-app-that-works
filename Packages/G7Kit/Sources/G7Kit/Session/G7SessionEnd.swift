// Original to Sensor (no ported code).

import Foundation
import GlucoseCore

/// Why a G7 session is over, as the sensor itself reported it (algorithm state byte 14 of a
/// status-0 `0x4E`, category from G7AlgorithmState). Latched by G7ReadingPipeline only after two
/// separate reports, at least 60 s of sensor time apart (safety review N1), and persisted in the
/// pairing record, so the ended state is shown again after a relaunch and `currentSession` stays nil
/// (D28).
public enum G7SessionEnd: String, Sendable, Equatable, Codable {
    /// Expired states 0x0F, 0x18, 0x1A, 0x24.
    case expired
    /// Sensor-failed states 0x0B, 0x0C, 0x10, 0x11, 0x13-0x16, 0x19, 0x1B, 0x25.
    case sensorFailed
    /// 0x01 "session stopped" after warm-up has ended (before that it is the activation state).
    case stopped

    /// What the state stream shows for a latched end (S5: visible, with the reason).
    public var state: SensorState {
        switch self {
        case .expired: return .expired
        case .sensorFailed: return .failed(reason: G7FailureReason.sensorFailed)
        case .stopped: return .failed(reason: G7FailureReason.sessionStopped)
        }
    }
}

/// A first end report not yet confirmed by a second one (G7ReadingPipeline). Persisted, so an app
/// terminated by iOS between two sensor wakes still latches the end at the next report.
public struct G7UnconfirmedSessionEnd: Sendable, Equatable, Codable {
    public let end: G7SessionEnd
    /// Sensor clock (bytes 2-5) of the `0x4E` that reported it.
    public let sensorClock: UInt32

    public init(end: G7SessionEnd, sensorClock: UInt32) {
        self.end = end
        self.sensorClock = sensorClock
    }
}

/// The newest reading published for the paired sensor: its sensor timestamp and its date. Persisted
/// so that after a relaunch no later reading can be dated before it (S3 monotonic; safety review P4).
public struct G7ReadingMark: Sendable, Equatable, Codable {
    public let sensorTimestamp: UInt32
    public let date: Date

    public init(sensorTimestamp: UInt32, date: Date) {
        self.sensorTimestamp = sensorTimestamp
        self.date = date
    }
}
