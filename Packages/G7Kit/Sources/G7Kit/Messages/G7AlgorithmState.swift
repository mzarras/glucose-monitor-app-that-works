//
//  DexcomAlgorithmState.swift
//  xdrip
//
//  Created by Johan Degraeve on 12/11/2021.
//  Copyright © 2021 Johan Degraeve. All rights reserved.
//
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/DexcomAlgorithmState.swift @ 7.1.0 (0370937)
// Changes: a struct over the raw byte (unknown bytes stay visible instead of collapsing to
// `None`); a `category` that drives S2/S5; the xDrip4iOS alert/colour mappings removed; three
// values cross-checked against LoopKit G7SensorKit AlgorithmState.swift (see table).

/// The sensor's algorithm state byte (byte 14 of `0x4E`, byte 6 of a backfill record).
///
/// Only `.ok` (0x06) carries a reading that may be published (S2). Every other state withholds the
/// reading and is surfaced through `SensorState` (S5). The raw byte is the `code` of
/// `SensorState.error(code:description:)`.
///
///     raw   name (xDrip4iOS DexcomAlgorithmState.swift:19-49)      category
///     0x00  None                                                    unknown
///     0x01  SessionStopped                                          stopped
///     0x02  SensorWarmup                                            warmUp
///     0x03  excessNoise                                             temporaryIssue
///     0x04  FirstofTwoBGsNeeded                                     calibrationNeeded
///     0x05  SecondofTwoBGsNeeded                                    calibrationNeeded
///     0x06  okay                                                    ok
///     0x07  needsCalibration                                        calibrationNeeded
///     0x08  CalibrationError1                                       calibrationError
///     0x09  CalibrationError2                                       calibrationError
///     0x0A  CalibrationLinearityFitFailure                          calibrationError
///     0x0B  SensorFailedDuetoCountsAberration                       sensorFailed
///     0x0C  SensorFailedDuetoResidualAberration                     sensorFailed
///     0x0D  OutOfCalibrationDueToOutlier                            calibrationError
///     0x0E  OutlierCalibrationRequest                               calibrationNeeded
///     0x0F  SessionExpired                                          expired
///     0x10  SessionFailedDueToUnrecoverableError                    sensorFailed
///     0x11  SessionFailedDueToTransmitterError                      sensorFailed
///     0x12  TemporarySensorIssue                                    temporaryIssue
///     0x13  SensorFailedDueToProgressiveSensorDecline               sensorFailed
///     0x14  SensorFailedDueToHighCountsAberration                   sensorFailed
///     0x15  SensorFailedDueToLowCountsAberration                    sensorFailed
///     0x16  SensorFailedDueToRestart                                sensorFailed
///     0x18  expired (*)                                             expired
///     0x19  sensorFailed (G7SensorKit AlgorithmState.swift:39)      sensorFailed
///     0x1A  sessionEnded (G7SensorKit AlgorithmState.swift:40)      expired
///     0x1B  SensorFailed8                                           sensorFailed
///     0x24  expired                                                 expired
///     0x25  sensorFailed                                            sensorFailed
///     other                                                         unknown
///
/// (*) 0x18: xDrip4iOS calls it `questionMarks`; G7SensorKit AlgorithmState.swift:38 calls it
/// `expired` (24), and G7SensorKit's captured packet `4e004d440e00d40b0001d46b650018036a000e`
/// (G7SensorKitTests/G7GlucoseMessageTests.swift:136-141, "7 hours after expiration") carries 0x18.
/// The captured evidence wins: 0x18 is treated as expired. Either way it is not `.ok`, so no
/// reading is ever published for it.
public struct G7AlgorithmState: Sendable, Equatable, Hashable {
    public enum Category: Sendable, Equatable, Hashable {
        case ok
        case warmUp
        case stopped
        case calibrationNeeded
        case calibrationError
        case temporaryIssue
        case sensorFailed
        case expired
        case unknown
    }

    /// The only state whose glucose value is valid (S2): 0x06.
    /// xDrip4iOS DexcomAlgorithmState.swift:25; G7SensorKit AlgorithmState.swift:104-115
    /// (`hasReliableGlucose` is true only for `.ok`).
    public static let ok = G7AlgorithmState(rawValue: 0x06)
    public static let warmUp = G7AlgorithmState(rawValue: 0x02)

    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public var category: Category {
        switch rawValue {
        case 0x06: return .ok
        case 0x02: return .warmUp
        case 0x01: return .stopped
        case 0x04, 0x05, 0x07, 0x0E: return .calibrationNeeded
        case 0x08, 0x09, 0x0A, 0x0D: return .calibrationError
        case 0x03, 0x12: return .temporaryIssue
        case 0x0B, 0x0C, 0x10, 0x11, 0x13, 0x14, 0x15, 0x16, 0x19, 0x1B, 0x25: return .sensorFailed
        case 0x0F, 0x18, 0x1A, 0x24: return .expired
        default: return .unknown
        }
    }

    /// Human-readable name, from xDrip4iOS DexcomAlgorithmState.swift:51-81 unless noted above.
    public var name: String {
        switch rawValue {
        case 0x00: return "No algorithm state"
        case 0x01: return "Session stopped"
        case 0x02: return "Sensor warm-up"
        case 0x03: return "Excess noise"
        case 0x04: return "First of two BG readings needed"
        case 0x05: return "Second of two BG readings needed"
        case 0x06: return "OK"
        case 0x07: return "Calibration needed"
        case 0x08: return "Calibration error 1"
        case 0x09: return "Calibration error 2"
        case 0x0A: return "Calibration linearity fit failure"
        case 0x0B: return "Sensor failed due to counts aberration"
        case 0x0C: return "Sensor failed due to residual aberration"
        case 0x0D: return "Out of calibration due to outlier"
        case 0x0E: return "Outlier calibration request"
        case 0x0F: return "Session expired"
        case 0x10: return "Session failed due to unrecoverable error"
        case 0x11: return "Session failed due to transmitter error"
        case 0x12: return "Temporary sensor issue"
        case 0x13: return "Sensor failed due to progressive sensor decline"
        case 0x14: return "Sensor failed due to high counts aberration"
        case 0x15: return "Sensor failed due to low counts aberration"
        case 0x16: return "Sensor failed due to restart"
        case 0x18: return "Session expired"
        case 0x19: return "Sensor failed"
        case 0x1A: return "Session ended"
        case 0x1B: return "Sensor failed"
        case 0x24: return "Session expired"
        case 0x25: return "Sensor failed"
        default: return "Unknown sensor state 0x" + String(rawValue, radix: 16, uppercase: true)
        }
    }
}
