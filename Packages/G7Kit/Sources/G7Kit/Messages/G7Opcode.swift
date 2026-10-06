//
//  Opcode.swift
//  xDripG5
//
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/DexcomTransmitterOpCode.swift @ 7.1.0 (0370937)
// CGMBLEKit lineage: CGMBLEKit/Opcode.swift (LoopKit CGMBLEKit, formerly xDripG5;
//   MIT, Packages/G7Kit/licenses/CGMBLEKit-LICENSE), reached through xDrip4iOS;
//   compared with loopandlearn/CGMBLEKit @ 98fae79 (Trio submodule).
// Changes: reduced to the opcodes G7 primary mode uses; 0x02 added (xDrip4iOS builds it inline
// in DexcomG7AuthBridge.m); every value annotated with the file:line that sends or parses it.

/// First byte of every G7 control message this package sends or parses.
enum G7Opcode: UInt8 {
    /// G7 authentication request: `02 || token(8) || slot(1)`.
    /// xDrip4iOS DexcomG7AuthBridge.m:203-218 (`makeAuthRequest`, opcode literal 0x02).
    case authRequest = 0x02
    /// Sensor reply to 0x02: `03 || tokenHash(8) || challenge(8)`.
    /// DexcomTransmitterOpCode.swift:14, AuthRequestRxMessage.swift:16-27.
    case authChallenge = 0x03
    /// Our answer to the challenge: `04 || AES hash(8)`. DexcomG7AuthBridge.m:256-260.
    case authChallengeResponse = 0x04
    /// Sensor authentication status: `05 || authenticated || paired`.
    /// DexcomTransmitterOpCode.swift:16, AuthChallengeRxMessage.swift:16-27.
    case authStatus = 0x05
    /// Keep-alive; `06 19` is sent after the ownership proof, `06 01` / `06 00` come back.
    /// DexcomTransmitterOpCode.swift:17, DexcomG7AuthSession.swift:292 and :480-489.
    case keepAlive = 0x06
    /// Legacy bond request `07` and its `07 00` echo. DexcomTransmitterOpCode.swift:18,
    /// PairRequestTxMessage.swift:13-16, DexcomG7AuthSession.swift:319-324.
    case bondRequest = 0x07
    /// `08 01` final legacy-bond acknowledgement. DexcomTransmitterOpCode.swift:19,
    /// DexcomG7AuthSession.swift:326-334.
    case pairConfirmation = 0x08
    /// J-PAKE phase control. DexcomTransmitterOpCode.swift:23, DexcomG7AuthSession.swift:264-272.
    case pakeExchange = 0x0A
    /// Certificate exchange control. DexcomTransmitterOpCode.swift:24, DexcomG7AuthSession.swift:534-564.
    case certificateExchange = 0x0B
    /// Proof-of-possession challenge. DexcomTransmitterOpCode.swift:25, DexcomG7AuthSession.swift:594-605.
    case proofOfPossession = 0x0C
    /// Ownership proof status `0D 00 02` (sent) / `0D ..` (received).
    /// DexcomTransmitterOpCode.swift:26, DexcomG7AuthSession.swift:284-292 and :624.
    case authProofStatus = 0x0D
    /// Listen mode (D45) only, observed, never sent: the sensor's 16-byte transmitter-time response
    /// to the Dexcom app's `24` request. DexcomTransmitterOpCode.swift:35 (transmitterTimeRx),
    /// CGMG7Transmitter.swift:1004, CGMBLEKit Opcode.swift:30.
    case transmitterTime = 0x25
    /// Listen mode (D45) only, observed, never sent: the sensor's 16-byte glucose response to the
    /// Dexcom app's `30` request. DexcomTransmitterOpCode.swift:44 (glucoseRx), CGMG7Transmitter.swift:1002,
    /// CGMBLEKit Opcode.swift:37.
    case coexistenceGlucose = 0x31
    /// Calibration bounds request `32` / 20-byte record. DexcomTransmitterOpCode.swift:45,
    /// CGMG7Transmitter.swift:1746, DexcomG7CalibrationMessages.swift:235-252.
    case calibrationBounds = 0x32
    /// Calibration command (9 bytes with CRC) / 4-byte response. DexcomTransmitterOpCode.swift:47,
    /// DexcomG7CalibrationMessages.swift:15-22 and :149-164.
    case calibrate = 0x34
    /// Primary-mode GetData request `4E` / 19-byte glucose response.
    /// DexcomTransmitterOpCode.swift:59 ("also used for G7"), CGMG7Transmitter.swift:1636.
    case glucose = 0x4E
    /// Extended version request `52` / 15-byte response (session length, warm-up).
    /// DexcomTransmitterOpCode.swift:65-67, CGMG7Transmitter.swift:1373.
    case extendedVersion = 0x52
    /// Sent by the sensor on Write_Control when backfill is complete.
    /// DexcomTransmitterOpCode.swift:69-70, CGMG7Transmitter.swift:1010-1012.
    case backfillFinished = 0x59
}
