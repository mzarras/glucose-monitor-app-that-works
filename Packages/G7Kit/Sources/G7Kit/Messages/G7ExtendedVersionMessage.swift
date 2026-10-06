// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// The original file carries no copyright header of its own.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/DexcomG7ExtendedVersionMessage.swift @ 7.1.0 (0370937)
// Changes: parser only (the lifetime policy is in Session/G7SensorLifetime.swift); reads [UInt8].

import Foundation

/// The `0x52` extended-version response on Write_Control. The request is the single byte `52`
/// with no CRC (DexcomTransmitterOpCode.swift:65-67, CGMG7Transmitter.swift:1373).
///
///     offset size field                                         source
///     0      1    opcode 0x52                                    DexcomG7ExtendedVersionMessage.swift:33
///     1      1    status (not decoded)
///     2      4    session length in s, INCLUDING the 12 h grace  :14-15, :36
///     6      2    warm-up duration in s                          :17-18, :37
///     8      4    algorithm version                              :38
///     12     1    hardware version                               :39
///     13     2    "max lifetime days" (12 for 10-day; NOT the session length)  :26-28, :40
///
/// Captured 10-day response: `5200c0d70d00540600020404ff0c00` → 907 200 s (10.5 days), 1 620 s
/// (27 min) warm-up (xDrip Tests/DexcomG7CalibrationTests.swift:231-239; the same vector is in
/// LoopKit G7SensorKitTests/ExtendedVersionMessageTests.swift:14-22).
struct G7ExtendedVersionMessage: Equatable {
    static let minimumLength = 15

    let sessionLength: TimeInterval
    let warmUpDuration: TimeInterval
    let algorithmVersion: UInt32
    let hardwareVersion: UInt8
    let maxLifetimeDays: UInt16

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        // Accept a longer response (forward-compatible) but require every understood field (:31-33).
        guard bytes.count >= Self.minimumLength, bytes[0] == G7Opcode.extendedVersion.rawValue else { return nil }
        sessionLength = TimeInterval(G7Bytes.uint32(bytes, at: 2))
        warmUpDuration = TimeInterval(G7Bytes.uint16(bytes, at: 6))
        algorithmVersion = G7Bytes.uint32(bytes, at: 8)
        hardwareVersion = bytes[12]
        maxLifetimeDays = G7Bytes.uint16(bytes, at: 13)
    }
}
