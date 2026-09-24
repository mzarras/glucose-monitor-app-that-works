// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// The original file carries no copyright header of its own.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/G7/CGMG7Transmitter.swift @ 7.1.0 (0370937)
// Changes: the single-byte requests xDrip4iOS builds inline are named constants here.

import Foundation

/// One-byte requests written (with response) to Write_Control after authentication.
/// None of them carries a CRC.
enum G7ControlRequest {
    /// GetData: asks for the current `0x4E` glucose response (CGMG7Transmitter.swift:1633-1641).
    static let glucose = Data([G7Opcode.glucose.rawValue])
    /// Asks for the `0x52` extended version: session length and warm-up (CGMG7Transmitter.swift:1373).
    static let extendedVersion = Data([G7Opcode.extendedVersion.rawValue])
    /// Asks for the `0x32` calibration record (CGMG7Transmitter.swift:1746).
    static let calibrationBounds = Data([G7Opcode.calibrationBounds.rawValue])

    /// True for the single byte `59` the sensor sends on Write_Control when backfill is complete
    /// (CGMG7Transmitter.swift:1010-1012; G7SensorKit G7Opcode.swift:17).
    static func isBackfillFinished(_ data: Data) -> Bool {
        data.first == G7Opcode.backfillFinished.rawValue
    }
}
