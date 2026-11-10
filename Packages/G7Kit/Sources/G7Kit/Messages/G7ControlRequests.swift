// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// The original file carries no copyright header of its own.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/G7/CGMG7Transmitter.swift @ 7.1.0 (0370937)
// Changes: the single-byte requests xDrip4iOS builds inline are named constants here. The backfill
// request is not in xDrip4iOS; its layout is from LoopKit G7SensorKit (MIT)
// G7SensorKit/G7CGMManager/G7Sensor.swift:624-659 @ next-dev 2bb6700 (`requestBackfillIfNeeded`).

import Foundation

/// Requests written (with response) to Write_Control after authentication. None carries a CRC.
enum G7ControlRequest {
    /// GetData: asks for the current `0x4E` glucose response (CGMG7Transmitter.swift:1633-1641).
    static let glucose = Data([G7Opcode.glucose.rawValue])
    /// Asks for the `0x52` extended version: session length and warm-up (CGMG7Transmitter.swift:1373).
    static let extendedVersion = Data([G7Opcode.extendedVersion.rawValue])
    /// Asks for the `0x32` calibration record (CGMG7Transmitter.swift:1746).
    static let calibrationBounds = Data([G7Opcode.calibrationBounds.rawValue])

    /// Backfill request (D65), 9 bytes:
    ///
    ///     offset size field
    ///     0      1    0x59
    ///     1      4    first sensor time wanted, s since session start, little-endian
    ///     5      4    last sensor time wanted, s since session start, little-endian
    ///
    /// G7SensorKit G7Sensor.swift:647-649 (`request.append(start.littleEndian)`, then `end`). The
    /// sensor answers with the records it holds in that range on Backfill, then a `59` on
    /// Write_Control (G7Sensor.swift:932-935: "The acknowledgement arrives after the records").
    static func backfill(fromSensorTime start: UInt32, to end: UInt32) -> Data {
        Data([G7Opcode.backfillFinished.rawValue] + G7Bytes.littleEndian(start) + G7Bytes.littleEndian(end))
    }

    /// True for a `59` request built by `backfill(fromSensorTime:to:)`.
    static func isBackfillRequest(_ data: Data) -> Bool {
        data.count == 9 && data.first == G7Opcode.backfillFinished.rawValue
    }

    /// True for the `59` the sensor sends on Write_Control when backfill is complete
    /// (CGMG7Transmitter.swift:1010-1012; G7SensorKit G7Opcode.swift:17).
    static func isBackfillFinished(_ data: Data) -> Bool {
        data.first == G7Opcode.backfillFinished.rawValue
    }
}
