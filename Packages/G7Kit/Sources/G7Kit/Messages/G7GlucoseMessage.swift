//
//  DexcomG7GlucoseDataRxMessage.swift
//  xdrip
//
//  Created by Johan Degraeve on 19/02/2024.
//  Copyright © 2024 Johan Degraeve. All rights reserved.
//
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/DexcomG7GlucoseDataRxMessage.swift @ 7.1.0 (0370937)
// Changes: see "Sensor changes" below. The coexistence `0x31` message is not ported (primary only).

import Foundation

/// The 19-byte `0x4E` response to primary mode's GetData request, received on Write_Control.
///
///     offset size field                                              source
///     0      1    opcode 0x4E                                        DexcomG7GlucoseDataRxMessage.swift:66
///     1      1    response status; 0x00 = current reading            :70-73, CGMG7Transmitter.swift:1031-1053
///     2      4    sensor clock when sent, s since session start      :79-80 (see Sensor change 2)
///     6      2    sequence number                                    :75-77
///     8      1    not decoded (0x00 in every capture)                layout comment :54-64
///     9      1    not decoded (0x01 in every capture; "session=1")   G7SensorKit G7GlucoseMessageTests.swift:94-96
///     10     2    age: s from the reading to this transmission       :82-87
///     12     2    glucose mg/dL in the low 12 bits; 0xFFFF = none    :92-104
///     14     1    algorithm state (G7AlgorithmState)                 :114-121
///     15     1    trend, signed tenths of mg/dL/min; 0x7F = none     :123-128
///     16     2    predicted glucose, low 12 bits; 0xFFFF = none      :106-112
///     18     1    flags; bit 0x10 = display-only value               :98
///
/// Sensor changes:
/// 1. The parser reads no wall clock. xDrip4iOS set `timeStamp = Date() - age` inside `init`;
///    here the caller supplies the receipt time to `G7SessionClock` (S3, testable with a clock).
/// 2. Bytes 2-5 are the sensor clock at transmission, and the reading happened `age` seconds
///    earlier, so the reading's sensor timestamp is `sensorClock - age`. xDrip4iOS instead
///    treated bytes 2-5 as the reading time and added `age` to get the sensor age (:86-87).
///    Evidence for `sensorClock - age`: LoopKit G7SensorKit G7GlucoseMessage.swift:18 and :29-31,
///    and its captured pair in G7SensorKitTests/G7GlucoseMessageTests.swift:120-126 and :143-151:
///    live `4e00f9590200030200012a018f000610d9000f` (clock 154105, age 298, 143 mg/dL) and the
///    backfill copy of the same reading `cf5802008f00060f10` (timestamp 153807 = 154105 - 298).
///    The startup vectors (:40-77) likewise land on a 300 s grid only after subtracting age.
///    This matters for S3: with it, the live and backfill copies of a reading share one id.
/// 3. `glucoseField` keeps the 16-bit field; classifying it (no value, LOW/HIGH, number: S4, D31)
///    is in `G7GlucoseRange`. `isDisplayOnly` is kept for the S1 decision in `G7ReadingPipeline`.
struct G7GlucoseMessage: Equatable {
    static let length = 19

    /// Byte 1. Non-zero means the frame is a status reply that may carry a cached, old value;
    /// it is never published as a reading (CGMG7Transmitter.swift:1031-1053).
    let responseStatus: UInt8
    /// Bytes 2-5: the sensor's session clock when this message was sent (seconds since the
    /// session started). This is the sensor-reported session age at receipt (S3).
    let sensorClock: UInt32
    let sequence: UInt16
    /// Bytes 10-11: seconds between the reading and this transmission.
    let age: UInt16
    /// Bytes 12-13 exactly as sent (classified by `G7GlucoseRange.classify`, D31).
    let glucoseField: UInt16
    /// Bytes 12-13 masked with 0x0FFF, or nil for the 0xFFFF "no value" sentinel.
    let glucoseRaw: UInt16?
    let algorithmState: G7AlgorithmState
    /// Byte 15 as mg/dL per minute (signed tenths), or nil for the 0x7F sentinel.
    let trendRate: Double?
    let predictedRaw: UInt16?
    /// Byte 18 bit 0x10: the value is display-only (calibration-related), see G7ReadingPipeline.
    let isDisplayOnly: Bool

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.length, bytes[0] == G7Opcode.glucose.rawValue else { return nil }
        responseStatus = bytes[1]
        sensorClock = G7Bytes.uint32(bytes, at: 2)
        sequence = G7Bytes.uint16(bytes, at: 6)
        age = G7Bytes.uint16(bytes, at: 10)
        glucoseField = G7Bytes.uint16(bytes, at: 12)
        glucoseRaw = glucoseField == 0xFFFF ? nil : glucoseField & 0x0FFF
        algorithmState = G7AlgorithmState(rawValue: bytes[14])
        trendRate = G7Trend.rate(fromByte: bytes[15])
        let predictedField = G7Bytes.uint16(bytes, at: 16)
        predictedRaw = predictedField == 0xFFFF ? nil : predictedField & 0x0FFF
        isDisplayOnly = glucoseRaw != nil && (bytes[18] & 0x10) != 0
    }

    /// The reading's own time in seconds since session start: `sensorClock - age` (Sensor change 2).
    /// Nil when `age > sensorClock`, which no valid message can report.
    var readingSensorTimestamp: UInt32? {
        let age = UInt32(age)
        return sensorClock >= age ? sensorClock - age : nil
    }
}

/// The trend byte shared by `0x4E` (byte 15) and backfill records (byte 8).
enum G7Trend {
    /// Signed tenths of mg/dL per minute; 0x7F means "no trend".
    /// DexcomG7GlucoseDataRxMessage.swift:123-128, DexcomG7BackfillMessage.swift:39-43.
    static func rate(fromByte byte: UInt8) -> Double? {
        byte == 0x7F ? nil : Double(Int8(bitPattern: byte)) / 10
    }
}
