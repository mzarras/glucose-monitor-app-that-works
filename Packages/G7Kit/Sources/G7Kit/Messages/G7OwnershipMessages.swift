// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// DexcomG7AuthSession.swift and DexcomG7AuthBridge.m carry no copyright header of their own.
// KeepAliveTxMessage.swift header: xDrip5, Created by Nathan Racklyeft on 11/23/15,
// Copyright © 2015 Nathan Racklyeft. All rights reserved.
// PairRequestTxMessage.swift header: BondRequestTxMessage.swift, xDrip5, Created by Nathan
// Racklyeft on 11/23/15, Copyright © 2015 Nathan Racklyeft. All rights reserved.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/DexcomG7AuthSession.swift @ 7.1.0 (0370937)
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/DexcomG7AuthBridge.m @ 7.1.0 (0370937)
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/KeepAliveTxMessage.swift @ 7.1.0 (0370937)
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/PairRequestTxMessage.swift @ 7.1.0 (0370937)
// CGMBLEKit lineage: CGMBLEKit/Messages/KeepAliveTxMessage.swift (LoopKit CGMBLEKit, formerly xDripG5;
//   MIT, Packages/G7Kit/licenses/CGMBLEKit-LICENSE), reached through xDrip4iOS;
//   compared with loopandlearn/CGMBLEKit @ 98fae79 (Trio submodule).
// CGMBLEKit lineage: CGMBLEKit/Messages/BondRequestTxMessage.swift (LoopKit CGMBLEKit, formerly xDripG5;
//   MIT, Packages/G7Kit/licenses/CGMBLEKit-LICENSE), reached through xDrip4iOS;
//   compared with loopandlearn/CGMBLEKit @ 98fae79 (Trio submodule).
// Changes: the control packets that xDrip4iOS builds and checks inline are named types here.

import Foundation

/// J-PAKE phase control on Receive_Authentication. The 160-byte payloads travel on Auth_Stream.
enum G7PakeControl {
    /// `0A <phase>`. Phase 0 opens J-PAKE (DexcomG7AuthBridge.m:200); `0A 01` and `0A 02` follow
    /// our round-1 and round-2 payloads (:390, :410). After phase 2 the next control packet is the
    /// `0x02` auth request instead (:432).
    static func request(phase: UInt8) -> Data {
        Data([G7Opcode.pakeExchange.rawValue, phase])
    }
}

/// The sensor's `0A 00 <phase>`: it has queued its 160-byte payload for `phase` on Auth_Stream.
/// Any other status byte is a rejection (DexcomG7AuthSession.swift:264-272).
struct G7PakeStatus: Equatable {
    let phase: UInt8

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 3, bytes[0] == G7Opcode.pakeExchange.rawValue, bytes[1] == 0x00 else { return nil }
        phase = bytes[2]
    }
}

/// Certificate exchange control: `0B <phase> <our certificate length, UInt32 little-endian>`.
/// Little-endian is required: "the previous big-endian request ... the transmitter accepted at the
/// write layer but immediately disconnected after" (DexcomG7AuthBridge.m:263-297, :291-295).
enum G7CertificateControl {
    static func request(phase: UInt8, certificateLength: UInt32) -> Data {
        Data([G7Opcode.certificateExchange.rawValue, phase] + G7Bytes.littleEndian(certificateLength))
    }
}

/// The sensor's `0B 00 <phase> <its certificate length, UInt32 LE>`; the certificate itself follows
/// on Auth_Stream (DexcomG7AuthSession.swift:534-564). Phase-order and size limits are checked by
/// `G7AuthSession`.
struct G7CertificateStatus: Equatable {
    let phase: UInt8
    let size: UInt32

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 7, bytes[0] == G7Opcode.certificateExchange.rawValue, bytes[1] == 0x00 else { return nil }
        phase = bytes[2]
        size = G7Bytes.uint32(bytes, at: 3)
    }
}

/// Proof of possession.
enum G7ProofControl {
    static let challengeLength = 16

    /// `0C || our random challenge(16)` (DexcomG7AuthBridge.m:333-349).
    static func challengeRequest(challenge: [UInt8]) -> Data {
        precondition(challenge.count == challengeLength, "proof challenge must be 16 bytes")
        return Data([G7Opcode.proofOfPossession.rawValue] + challenge)
    }

    /// `0D 00 02`, written after our 64-byte signature on Auth_Stream (DexcomG7AuthSession.swift:619-626).
    static let signatureSubmitted = Data([G7Opcode.authProofStatus.rawValue, 0x00, 0x02])
}

/// The sensor's `0C 00 <challenge(16)>` (exactly 18 bytes); its 64-byte proof follows on
/// Auth_Stream (DexcomG7AuthSession.swift:594-605, :617).
struct G7ProofChallenge: Equatable {
    let challenge: [UInt8]

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == 18, bytes[0] == G7Opcode.proofOfPossession.rawValue, bytes[1] == 0x00 else { return nil }
        challenge = Array(bytes[2..<18])
    }
}

/// Keep-alive after the ownership proof is accepted.
enum G7OwnershipKeepAlive {
    /// `06 19`: keep-alive request, 0x19 = 25 seconds (KeepAliveTxMessage.swift:11-19 appends the
    /// time byte; DexcomG7AuthSession.swift:292 sends 0x19).
    static let request = Data([G7Opcode.keepAlive.rawValue, 0x19])

    enum Outcome: Equatable {
        /// `06 01`: ownership complete; confirm the key (DexcomG7AuthSession.swift:297-306).
        case complete
        /// `06 00`: older firmware wants the explicit bond request (:308-313).
        case legacyBondRequired
        case ignore
    }

    /// DexcomG7AuthSession.swift:480-489 (`ownershipKeepAliveAction`).
    static func outcome(of data: Data) -> Outcome {
        switch [UInt8](data) {
        case [G7Opcode.keepAlive.rawValue, 0x01]: return .complete
        case [G7Opcode.keepAlive.rawValue, 0x00]: return .legacyBondRequired
        default: return .ignore
        }
    }
}

/// The legacy bond path after `06 00`: send `07`, expect `07 00`, then `08 01`.
enum G7LegacyBond {
    /// PairRequestTxMessage.swift:13-16 (a one-byte `07`).
    static let request = Data([G7Opcode.bondRequest.rawValue])

    /// DexcomG7AuthSession.swift:319-324.
    static func isBondRequestEcho(_ data: Data) -> Bool {
        [UInt8](data) == [G7Opcode.bondRequest.rawValue, 0x00]
    }

    /// DexcomG7AuthSession.swift:326-334: the final acknowledgement; only now is the key confirmed.
    static func isPairConfirmation(_ data: Data) -> Bool {
        [UInt8](data) == [G7Opcode.pairConfirmation.rawValue, 0x01]
    }
}
