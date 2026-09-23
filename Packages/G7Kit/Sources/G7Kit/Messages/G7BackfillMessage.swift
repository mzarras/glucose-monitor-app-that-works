// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// The original file carries no copyright header of its own.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/DexcomG7BackfillMessage.swift @ 7.1.0 (0370937)
// Changes: see "Sensor changes" below.

import Foundation

/// One 9-byte historical record received on the Backfill characteristic (F8083536).
///
///     offset size field                                           source
///     0      3    reading time, s since session start              see Sensor change 2
///     3      1    not decoded (0x00 in every capture)
///     4      2    glucose mg/dL in the low 12 bits; 0xFFFF = none   DexcomG7BackfillMessage.swift:27-37
///     6      1    algorithm state (G7AlgorithmState)                see Sensor change 3
///     7      1    flags; bit 0x10 = display-only value              see Sensor change 4
///     8      1    trend, signed tenths of mg/dL/min; 0x7F = none    DexcomG7BackfillMessage.swift:39-43
///
/// Sensor changes:
/// 1. No wall clock in the parser. xDrip4iOS computed `Date() - sensorAge + timestamp` in `init`;
///    here `G7SessionClock` converts the sensor timestamp using this connection's session start (S3).
/// 2. The timestamp is read as 3 bytes, per the layout in LoopKit G7SensorKit
///    G7CGMManager/G7BackfillMessage.swift:27-36 (`TTTTTT`, `data[0..<3]`). xDrip4iOS read 4 bytes
///    (:23); byte 3 is 0x00 in every captured record, so both agree on real data. Three bytes cover
///    194 days, far beyond a 10.5-day session.
/// 3. The algorithm state byte is decoded (G7SensorKit G7BackfillMessage.swift:48). xDrip4iOS
///    ignored it, which would let a warm-up or error record through; S2 needs it.
/// 4. Display-only is true if either reference's flag is set: G7SensorKit reads byte 7 bit 0x10
///    (:46; captured `f63d00008500061efe`, G7GlucoseMessageTests.swift:162-165), xDrip4iOS read the
///    glucose high nibble (:31). Taking either is the conservative superset (S1).
struct G7BackfillMessage: Equatable {
    static let length = 9

    /// Seconds since the session started, as the sensor reported it (S3: never adjusted).
    let sensorTimestamp: UInt32
    /// Bytes 4-5 exactly as sent (classified by `G7GlucoseRange.classify`, D31).
    let glucoseField: UInt16
    let glucoseRaw: UInt16?
    let algorithmState: G7AlgorithmState
    let trendRate: Double?
    let isDisplayOnly: Bool

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == Self.length else { return nil }
        sensorTimestamp = G7Bytes.uint24(bytes, at: 0)
        glucoseField = G7Bytes.uint16(bytes, at: 4)
        glucoseRaw = glucoseField == 0xFFFF ? nil : glucoseField & 0x0FFF
        algorithmState = G7AlgorithmState(rawValue: bytes[6])
        let flaggedByGlucoseNibble = glucoseField != 0xFFFF && (glucoseField & 0xF000) != 0
        isDisplayOnly = (bytes[7] & 0x10) != 0 || flaggedByGlucoseNibble
        trendRate = G7Trend.rate(fromByte: bytes[8])
    }
}
