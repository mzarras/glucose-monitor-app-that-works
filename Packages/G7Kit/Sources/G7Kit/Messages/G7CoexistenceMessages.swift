//
//  DexcomG7GlucoseDataRxMessage.swift
//  xdrip
//
//  Created by Johan Degraeve on 19/02/2024.
//  Copyright © 2024 Johan Degraeve. All rights reserved.
//
// DexcomTransmitterTimeRxMessage.swift carries no copyright header of its own.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/DexcomG7GlucoseDataRxMessage.swift @ 7.1.0 (0370937)
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/DexcomTransmitterTimeRxMessage.swift @ 7.1.0 (0370937)
// CGMBLEKit lineage: CGMBLEKit/Messages/GlucoseRxMessage.swift (LoopKit CGMBLEKit, formerly xDripG5;
//   MIT, Packages/G7Kit/licenses/CGMBLEKit-LICENSE), the G6 layout these G7 frames share;
//   compared with loopandlearn/CGMBLEKit @ 98fae79 (Trio submodule).
// CGMBLEKit lineage: CGMBLEKit/Messages/TransmitterTimeRxMessage.swift (LoopKit CGMBLEKit, formerly xDripG5;
//   MIT, Packages/G7Kit/licenses/CGMBLEKit-LICENSE), the G6 layout these G7 frames share;
//   compared with loopandlearn/CGMBLEKit @ 98fae79 (Trio submodule).
// Changes: xDrip4iOS's `G7CoexistenceGlucoseMessage` (DexcomG7GlucoseDataRxMessage.swift:138-157)
// and `DexcomTransmitterTimeRxMessage` with CGMBLEKit's checks added (CRC, status, display-only
// bits, trend, "no session" value); no wall clock in the parsers (the pair is dated by the caller);
// the join of CGMG7Transmitter.swift:1082-1102 expressed in sensor time (`G7ObservedGlucosePair`).

import Foundation

/// `0x31`: the sensor's glucose response to the Dexcom app's `30` request, observed in listen mode
/// (D45) and never requested by this app. 16 bytes, G6 layout:
///
///     offset size field                                          source
///     0      1    opcode 0x31                                    DexcomG7GlucoseDataRxMessage.swift:149
///     1      1    status; 0x00 = OK                              CGMBLEKit GlucoseRxMessage.swift:61
///     2      4    sequence                                       :62
///     6      4    reading time, transmitter clock (s)            DexcomG7GlucoseDataRxMessage.swift:155; CGMBLEKit :28
///     10     2    glucose in the low 12 bits; any of the high    :153; CGMBLEKit :33-34
///                 4 bits set = display-only
///     12     1    algorithm state                                :154; CGMBLEKit :38
///     13     1    trend, signed tenths of mg/dL/min;             CGMBLEKit :42, Glucose.swift:101-107
///                 0x7F and 0x80 = none
///     14     2    CRC-16 XModem of bytes 0-13, little-endian     CGMBLEKit :53 (`isCRCValid`)
///
/// Captured G7 example (xDrip Tests/DexcomG7CalibrationTests.swift:345-350):
/// `31008eaf0000335bd7009900060582be` = 153 mg/dL, state OK, at transmitter time 14 113 587.
struct G7CoexistenceGlucoseMessage: Equatable {
    static let length = 16

    let status: UInt8
    let sequence: UInt32
    /// Transmitter clock at the reading (not session time; see `G7TransmitterTimeMessage`).
    let readingTransmitterTime: UInt32
    /// Bytes 10-11 exactly as sent; `G7GlucoseRange` classifies the low 12 bits (S4, D31).
    let glucoseField: UInt16
    let isDisplayOnly: Bool
    let algorithmState: G7AlgorithmState
    let trendRate: Double?

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        // CRC: a garbled frame on the shared link is dropped, never decoded (CGMBLEKit :53).
        guard bytes.count == Self.length, bytes[0] == G7Opcode.coexistenceGlucose.rawValue,
              G7CRC16.isValid(bytes) else { return nil }
        status = bytes[1]
        sequence = G7Bytes.uint32(bytes, at: 2)
        readingTransmitterTime = G7Bytes.uint32(bytes, at: 6)
        glucoseField = G7Bytes.uint16(bytes, at: 10)
        isDisplayOnly = glucoseField != 0xFFFF && (glucoseField & 0xF000) != 0
        algorithmState = G7AlgorithmState(rawValue: bytes[12])
        let trend = Int8(bitPattern: bytes[13])
        trendRate = trend == .max || trend == .min ? nil : Double(trend) / 10
    }
}

/// `0x25`: the sensor's transmitter-time response to the Dexcom app's `24` request, observed in
/// listen mode only. 16 bytes, G6 layout:
///
///     offset size field                                          source
///     0      1    opcode 0x25                                    DexcomTransmitterTimeRxMessage.swift:15
///     1      1    status; 0x00 = OK                              CGMBLEKit TransmitterTimeRxMessage.swift:33
///     2      4    transmitter clock now (s)                      DexcomTransmitterTimeRxMessage.swift:17; CGMBLEKit :34
///     6      4    session start, transmitter clock (s);          :21; CGMBLEKit :35, :14-21
///                 0xFFFFFFFF = no session
///     10     4    not decoded (01000000 in the capture)
///     14     2    CRC-16 XModem of bytes 0-13, little-endian     CGMBLEKit :25 (`isCRCValid`)
///
/// Captured G7 example (xDrip Tests/DexcomG7CalibrationTests.swift:352-357):
/// `25003e5bd700f0ccd30001000000a0f2` = clock 14 113 598, session start 13 880 560. The G7
/// transmitter clock is not session time (here 163 days vs. a 2.7-day session), so readings are put in
/// session time as `transmitter time - session start` (xDrip4iOS CGMG7Transmitter.swift:1090-1091).
struct G7TransmitterTimeMessage: Equatable {
    static let length = 16
    /// CGMBLEKit TransmitterTimeRxMessage.swift:14.
    static let noSession = UInt32.max

    let status: UInt8
    let currentTransmitterTime: UInt32
    let sessionStartTransmitterTime: UInt32

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == Self.length, bytes[0] == G7Opcode.transmitterTime.rawValue,
              G7CRC16.isValid(bytes) else { return nil }
        status = bytes[1]
        currentTransmitterTime = G7Bytes.uint32(bytes, at: 2)
        sessionStartTransmitterTime = G7Bytes.uint32(bytes, at: 6)
    }

    /// A session is running and started before now (CGMBLEKit TransmitterTimeRxMessage.swift:20-21).
    var hasSession: Bool {
        sessionStartTransmitterTime != Self.noSession && sessionStartTransmitterTime <= currentTransmitterTime
    }
}

/// An observed `0x31` joined with the observed `0x25` of the same connection (either order,
/// CGMG7Transmitter.swift:1064-1102), expressed in session time like `0x4E`:
/// - `sensorClock` = transmitter clock now − session start, at the `0x25`'s receipt;
/// - `readingSensorTimestamp` = reading's transmitter time − session start.
/// Hypothesis to verify on device (docs/g7-protocol.md §14): this equals `0x4E`'s `sensorClock - age`
/// for the same reading, so ids match primary mode. A disagreement shows up as a clock mismatch
/// (the anchor check), never as wrong dates silently.
struct G7ObservedGlucosePair: G7GlucoseReport, Equatable {
    let glucose: G7CoexistenceGlucoseMessage
    let clock: G7TransmitterTimeMessage

    /// Nil when the `0x25` reports no running session: then there is no session time to use.
    init?(glucose: G7CoexistenceGlucoseMessage, clock: G7TransmitterTimeMessage) {
        guard clock.hasSession else { return nil }
        self.glucose = glucose
        self.clock = clock
    }

    /// Either half's non-zero status makes the pair a status reply (never published or anchored).
    var responseStatus: UInt8 { glucose.status != 0 ? glucose.status : clock.status }
    var sensorClock: UInt32 { clock.currentTransmitterTime - clock.sessionStartTransmitterTime }
    var readingAge: UInt32 {
        clock.currentTransmitterTime >= glucose.readingTransmitterTime
            ? clock.currentTransmitterTime - glucose.readingTransmitterTime : .max
    }
    var readingSensorTimestamp: UInt32? {
        let reading = glucose.readingTransmitterTime
        guard reading >= clock.sessionStartTransmitterTime, reading <= clock.currentTransmitterTime else { return nil }
        return reading - clock.sessionStartTransmitterTime
    }
    var glucoseField: UInt16 { glucose.glucoseField }
    var algorithmState: G7AlgorithmState { glucose.algorithmState }
    var trendRate: Double? { glucose.trendRate }
    var isDisplayOnly: Bool { glucose.isDisplayOnly }
}
