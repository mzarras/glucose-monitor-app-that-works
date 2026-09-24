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
    /// Changed in Phase 2 (was `failed(reason: String)`): a structured kind for decisions (alerts,
    /// banners, UI) plus the source's text for the person wearing the sensor.
    case failed(SensorFailure)
    case error(code: Int, description: String)
    /// Added in Phase 2: the sensor withholds readings until it is calibrated. `code` is the
    /// source's raw algorithm state (documented by the source).
    case calibrationNeeded(code: Int)
    /// Added in Phase 2: the sensor rejected or could not use a calibration and withholds readings.
    case calibrationError(code: Int)
    /// Added in Phase 0 (not in HANDOFF §4.3): S5 requires "BLE unavailable/unauthorized" to
    /// surface in the UI and as an alert, and none of the §4.3 cases can express it faithfully.
    case bluetoothUnavailable(BluetoothIssue)
}

/// Why a CGM source cannot deliver readings (S5). The source supplies `message`, written for the
/// person wearing the sensor; consumers decide what to do from `kind`, never from the text.
public struct SensorFailure: Sendable, Equatable, Hashable, Codable {
    public enum Kind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        // The sensor itself is finished — replace it.
        case sensorFailed
        case sessionStopped
        case unsupportedSensor
        // This phone is not, or no longer, accepted by the sensor — pair again.
        case pairingRejected
        case pairingCodeNeeded
        case bondRemoved
        // A pairing in progress did not complete (user action during pairing).
        case bluetoothPairingIncomplete
        // Transient or environmental: readings may be withheld for a while.
        case authenticationFailed
        case rejectedAfterAuthentication
        case otherAppRejected
        case clockMismatch
        case noGlucoseValue
        case sessionLengthUnknown
        case credentialsUnavailable
        /// Anything a source cannot classify. Fails loud (S5): it raises the sensor alert.
        case other
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    /// No more readings will come from this sensor.
    public var requiresSensorReplacement: Bool {
        switch kind {
        case .sensorFailed, .sessionStopped, .unsupportedSensor: return true
        default: return false
        }
    }

    /// Readings will not resume until the user pairs again.
    public var requiresPairing: Bool {
        switch kind {
        case .pairingRejected, .pairingCodeNeeded, .bondRemoved: return true
        default: return false
        }
    }

    /// Whether the alert engine raises the sensor alert (S5): an ended sensor, a lost pairing, or a
    /// failure the source could not classify. Transient kinds surface as banners; if they stop
    /// readings for long, the missed-readings alert covers them — including after warm-up has
    /// ended without any reading (the alert engine must not stay in warm-up suppression).
    public var raisesSensorAlert: Bool { requiresSensorReplacement || requiresPairing || kind == .other }
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
