// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// The original file carries no copyright header of its own.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/DexcomG7CalibrationMessages.swift @ 7.1.0 (0370937)
// Changes: renamed types; [UInt8] parsing; `humanDescription` strings added; the transmitter clock
// reference moved to Session/G7SessionClock.swift; `matches` takes an Int glucose.

import Foundation

/// The `0x34` calibration command on Write_Control (9 bytes):
///
///     offset size field
///     0      1    opcode 0x34
///     1      2    fingerstick glucose, mg/dL, UInt16 little-endian
///     3      4    fingerstick time in sensor time (s since session start), UInt32 LE
///     7      2    CRC-16 CCITT (XModem) of bytes 0-6, little-endian
///
/// Source: DexcomG7CalibrationMessages.swift:3-23 ("G7 uses the established Dexcom calibration
/// payload: opcode, glucose, transmitter time, then CRC16"). Captured-format test vector:
/// xDrip Tests/DexcomG7CalibrationTests.swift:5-11.
struct G7CalibrationCommand: Equatable {
    let glucose: UInt16
    let sensorTime: UInt32

    var data: Data {
        let payload = [G7Opcode.calibrate.rawValue] + G7Bytes.littleEndian(glucose) + G7Bytes.littleEndian(sensorTime)
        return Data(G7CRC16.appending(to: payload))
    }
}

/// Why the sensor rejected a calibration: the secondary status byte of a rejected `0x34` response
/// (primary status 2). Codes 0-11 are every reason xDrip4iOS documents
/// (DexcomG7CalibrationMessages.swift:25-57); anything else is kept as `.unknown(code)`.
/// The byte is the `code` of `CalibrationStatus.rejected(code:reason:)`.
public enum G7CalibrationRejectionReason: Sendable, Equatable, Hashable {
    case unspecified            // 0
    case outsideRange           // 1
    case timestampInFuture      // 2
    case duplicate              // 3
    case earlierThanSessionStart // 4
    case notInOrder             // 5
    case alreadyEntered         // 6
    case disabled               // 7
    case notPermitted           // 8
    case calibrationBoundsFailed // 9
    case extremeOutlier         // 10
    case stale                  // 11
    case unknown(UInt8)

    public init(code: UInt8) {
        switch code {
        case 0: self = .unspecified
        case 1: self = .outsideRange
        case 2: self = .timestampInFuture
        case 3: self = .duplicate
        case 4: self = .earlierThanSessionStart
        case 5: self = .notInOrder
        case 6: self = .alreadyEntered
        case 7: self = .disabled
        case 8: self = .notPermitted
        case 9: self = .calibrationBoundsFailed
        case 10: self = .extremeOutlier
        case 11: self = .stale
        default: self = .unknown(code)
        }
    }

    public var code: UInt8 {
        switch self {
        case .unspecified: return 0
        case .outsideRange: return 1
        case .timestampInFuture: return 2
        case .duplicate: return 3
        case .earlierThanSessionStart: return 4
        case .notInOrder: return 5
        case .alreadyEntered: return 6
        case .disabled: return 7
        case .notPermitted: return 8
        case .calibrationBoundsFailed: return 9
        case .extremeOutlier: return 10
        case .stale: return 11
        case .unknown(let code): return code
        }
    }

    /// Wording follows xDrip4iOS `traceDescription` (DexcomG7CalibrationMessages.swift:59-75).
    public var humanDescription: String {
        switch self {
        case .unspecified: return "Rejected (no reason given)"
        case .outsideRange: return "Outside the accepted range"
        case .timestampInFuture: return "Timestamp in the future"
        case .duplicate: return "Duplicate"
        case .earlierThanSessionStart: return "Earlier than the session start"
        case .notInOrder: return "Not in order"
        case .alreadyEntered: return "Already entered"
        case .disabled: return "Calibration disabled"
        case .notPermitted: return "Calibration not permitted now"
        case .calibrationBoundsFailed: return "Calibration bounds check failed"
        case .extremeOutlier: return "Extreme outlier"
        case .stale: return "Stale"
        case .unknown(let code): return "Rejected (unknown reason \(code))"
        }
    }

    /// Duplicate-like rejections mean an earlier copy of this calibration is already being
    /// processed (e.g. a retried command); keep waiting for the bounds record
    /// (DexcomG7CalibrationMessages.swift:77-79, CGMG7Transmitter.swift:1833-1835).
    var meansAlreadyProcessing: Bool {
        self == .duplicate || self == .alreadyEntered
    }
}

/// Detail byte of an accepted `0x34` response (DexcomG7CalibrationMessages.swift:82-106).
enum G7CalibrationAcceptanceDetail: Equatable {
    case accepted
    case error0
    case error1
    case unknown(UInt8)

    init(code: UInt8) {
        switch code {
        case 0: self = .accepted
        case 1: self = .error0
        case 2: self = .error1
        default: self = .unknown(code)
        }
    }
}

/// Meaning of the two status bytes of the `0x34` response (DexcomG7CalibrationMessages.swift:108-133).
enum G7CalibrationCommandStatus: Equatable {
    case acceptedHigh(G7CalibrationAcceptanceDetail)
    case acceptedLow(G7CalibrationAcceptanceDetail)
    case rejected(G7CalibrationRejectionReason)
    case factoryCalibrated
    case unknown(primary: UInt8, secondary: UInt8)
}

/// The sensor's immediate 4-byte answer to `0x34`: `34 <response> <primary> <secondary>`
/// (DexcomG7CalibrationMessages.swift:135-165). No CRC.
struct G7CalibrationCommandResponse: Equatable {
    static let length = 4

    let transmitterResponse: UInt8
    let primaryStatus: UInt8
    let secondaryStatus: UInt8
    let status: G7CalibrationCommandStatus

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == Self.length, bytes[0] == G7Opcode.calibrate.rawValue else { return nil }
        transmitterResponse = bytes[1]
        primaryStatus = bytes[2]
        secondaryStatus = bytes[3]
        switch primaryStatus {
        case 0: status = .acceptedHigh(G7CalibrationAcceptanceDetail(code: secondaryStatus))
        case 1: status = .acceptedLow(G7CalibrationAcceptanceDetail(code: secondaryStatus))
        case 2: status = .rejected(G7CalibrationRejectionReason(code: secondaryStatus))
        case 3: status = .factoryCalibrated
        default: status = .unknown(primary: primaryStatus, secondary: secondaryStatus)
        }
    }
}

/// Processing state byte of the `0x32` record (DexcomG7CalibrationMessages.swift:167-184).
enum G7CalibrationProcessingState: UInt8, Equatable {
    case noCalibration = 0 // "none" in xDrip4iOS; renamed to avoid clashing with Optional.none
    case factoryCalibrated = 1
    case inProgress = 2
    case completeHigh = 3
    case completeLow = 4
}

/// The 20-byte `0x32` calibration record: the sensor's durable answer about the latest calibration
/// (DexcomG7CalibrationMessages.swift:200-252). The request is the single byte `32`
/// (CGMG7Transmitter.swift:1746).
///
///     offset size field
///     0      1    opcode 0x32
///     1      1    transmitter response
///     2      1    session number
///     3      4    session signature, UInt32 LE
///     7      2    calibration glucose, mg/dL, UInt16 LE
///     9      4    calibration time, sensor time, UInt32 LE
///     13     1    processing state (G7CalibrationProcessingState)
///     14     1    calibrations permitted (non-zero = yes)
///     15     1    originating display (2 = phone, 4 = receiver, ... :186-198)
///     16     4    last processing update, sensor time, UInt32 LE
struct G7CalibrationBounds: Equatable {
    static let length = 20

    let transmitterResponse: UInt8
    let sessionNumber: UInt8
    let sessionSignature: UInt32
    let glucose: UInt16
    let calibrationTime: UInt32
    let processingRawValue: UInt8
    let processingState: G7CalibrationProcessingState?
    let calibrationsPermitted: Bool
    let originatingDisplayRawValue: UInt8
    let lastProcessingUpdateTime: UInt32

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == Self.length, bytes[0] == G7Opcode.calibrationBounds.rawValue else { return nil }
        transmitterResponse = bytes[1]
        sessionNumber = bytes[2]
        sessionSignature = G7Bytes.uint32(bytes, at: 3)
        glucose = G7Bytes.uint16(bytes, at: 7)
        calibrationTime = G7Bytes.uint32(bytes, at: 9)
        processingRawValue = bytes[13]
        processingState = G7CalibrationProcessingState(rawValue: processingRawValue)
        calibrationsPermitted = bytes[14] != 0
        originatingDisplayRawValue = bytes[15]
        lastProcessingUpdateTime = G7Bytes.uint32(bytes, at: 16)
    }

    /// True when this record describes the calibration we sent: same glucose and a sensor time
    /// within `tolerance` seconds. A stale record for the previous calibration can arrive right
    /// after a new command (DexcomG7CalibrationMessages.swift:254-259, CGMG7Transmitter.swift:1890-1909).
    func matches(glucose expectedGlucose: UInt16, sensorTime expectedTime: UInt32, tolerance: UInt32 = 2) -> Bool {
        guard glucose == expectedGlucose else { return false }
        return abs(Int64(calibrationTime) - Int64(expectedTime)) <= Int64(tolerance)
    }
}
