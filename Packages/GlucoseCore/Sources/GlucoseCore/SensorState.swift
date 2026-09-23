// Contract (HANDOFF §4.3, S2, S5). Owned by the orchestrator; change only through PROGRESS.md.

import Foundation

/// What the CGM source is doing right now. Drives the Now screen's status line, the S5 banners,
/// and sensor alerts.
public enum SensorState: Sendable, Equatable, Hashable, Codable {
    case notPaired
    case searching
    case connecting
    case authenticating
    case warmingUp(endsAt: Date)
    case active(sessionStart: Date, expiresAt: Date)
    case gracePeriod(endsAt: Date)
    case expired
    case failed(reason: String)
    case error(code: Int, description: String)
    /// Added in Phase 0 (not in HANDOFF §4.3): S5 requires "BLE unavailable/unauthorized" to
    /// surface in the UI and as an alert, and none of the §4.3 cases can express it faithfully.
    case bluetoothUnavailable(BluetoothIssue)
}

/// Why Bluetooth cannot be used (maps from `CBManagerState`).
public enum BluetoothIssue: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case poweredOff
    case unauthorized
    case unsupported
    case resetting
}

/// The sensor session the source is authenticated to. Added in Phase 0: `LiveReadingGate` needs
/// the session start, warm-up end, and expiry to apply S2 downstream of the source.
///
/// All dates are derived from what the sensor reports (S3): `start` is the phone's clock at
/// connection time minus the sensor-reported session age.
public struct SensorSession: Sendable, Equatable, Hashable, Codable {
    public let serial: String
    public let start: Date
    public let warmUpEndsAt: Date
    /// End of the rated life (10 days for a G7 10-day sensor).
    public let expiresAt: Date
    /// End of the grace period after `expiresAt` (12 h for G7). No reading is valid after this.
    public let gracePeriodEndsAt: Date

    public init(serial: String, start: Date, warmUpEndsAt: Date, expiresAt: Date, gracePeriodEndsAt: Date) {
        self.serial = serial
        self.start = start
        self.warmUpEndsAt = warmUpEndsAt
        self.expiresAt = expiresAt
        self.gracePeriodEndsAt = gracePeriodEndsAt
    }

    /// Non-empty serial and `start ≤ warmUpEndsAt ≤ expiresAt ≤ gracePeriodEndsAt`.
    /// `LiveReadingGate` refuses every reading against a session that is not well formed.
    public var isWellFormed: Bool {
        !serial.isEmpty && start <= warmUpEndsAt && warmUpEndsAt <= expiresAt && expiresAt <= gracePeriodEndsAt
    }
}
