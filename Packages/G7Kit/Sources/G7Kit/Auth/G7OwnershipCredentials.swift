// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// DexcomG7AuthBridge.m and DexcomG7ProofSigner.swift carry no copyright header of their own.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/DexcomG7AuthBridge.m @ 7.1.0 (0370937)
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/DexcomG7ProofSigner.swift @ 7.1.0 (0370937)
// Changes: constants as byte arrays; the CryptoKit signer is called directly instead of through
// NSClassFromString/objc_msgSend (DexcomG7AuthBridge.m:463-495).

import CryptoKit
import Foundation

/// Fixed client credentials for the G7 ownership (certificate + proof-of-possession) exchange.
///
/// These are the same public constants Juggluco and xDrip+ send ("KEKS" parts A, B, C);
/// DexcomG7AuthBridge.m:36-44 and :140-143 ("conventional DER/raw-scalar hex, exactly as sent by
/// Juggluco"). They are not secrets of this app: every open-source G7 primary implementation ships
/// them. Part A is a DER X.509 CA certificate, part B a DER X.509 client certificate issued by it,
/// part C the raw P-256 private scalar for part B's public key (a test checks that match).
/// The sensor does not appear to check part B's validity dates (notAfter is 2025-04-13 and
/// xDrip4iOS 7.1.0 still pairs); if Dexcom ever starts to, pairing will fail loudly at the
/// certificate phase, never silently.
enum G7OwnershipCredentials {
    /// Sent in certificate phase 0 (DexcomG7AuthBridge.m:39-40, :263-331).
    static let certificatePartA: [UInt8] = hexBytes([
        "308201EA3082018FA00302010202142F3C52B6EB08701046D45D78CE81784C9DFE5240300A06082A8648CE3D04030230",
        "133111300F06035504030C084445583030504731301E170D3230313033303135353930345A170D333531303237313535",
        "3930345A30133111300F06035504030C0844455830335047313059301306072A8648CE3D020106082A8648CE3D030107",
        "03420004FB1ACA21D8AEEC9A4EB51F85304953D977A1AD569799250FF863987F42A3CD9FA4FF571EB568BC6C396277C3",
        "DCB51DEDAEE85513C80A5C4435538A19F5A96348A381C03081BD300F0603551D130101FF040530030101FF301F060355",
        "1D230418301680149E0F1E36F3F276A701FE8E883A6E26A635BD6AFC305A0603551D1F04533051304FA034A032863068",
        "7474703A2F2F63726C2E64702E736161732E7072696D656B65792E636F6D2F63726C2F44455830305047312E63726CA2",
        "17A41530133111300F06035504030C084445583030504731301D0603551D0E0416041488F61E81BC4B17F05C6B1BE299",
        "1D60087CCEDD79300E0603551D0F0101FF040403020186300A06082A8648CE3D0403020349003046022100AA69CD897E",
        "C663AF5F9E158187DF6851FF0756F00C401624564F81A19F5A0785022100DAEBB9FDB163B731EB0661F1C0A1932871A5",
        "0E399AD1C6F519EABD4C9E7BA013",
    ])

    /// Sent in certificate phase 1 (DexcomG7AuthBridge.m:41-42).
    static let certificatePartB: [UInt8] = hexBytes([
        "308201CD30820174A003020102021419052FCC17530BFA56E49DCAFCDACF853CE5BA73300A06082A8648CE3D04030230",
        "133111300F06035504030C084445583033504731301E170D3233303431343130323831345A170D323530343133313032",
        "3831335A303A3138303606035504030C2F30312C303030302C303330304C514543437A4142417741412C63696F696533",
        "56625132686C5A4D6A64556D357267413059301306072A8648CE3D020106082A8648CE3D030107034200045118C35E9E",
        "41E7E0654FEE801C52A9C5DFC510EF09597D5CCA8461E4AF9C666714834F2BC903F16FABFC45755B0183F1A09745CDFF",
        "CB4E2F799E50BED9A6B58CA37F307D300C0603551D130101FF04023000301F0603551D2304183016801488F61E81BC4B",
        "17F05C6B1BE2991D60087CCEDD79301D0603551D250416301406082B0601050507030206082B06010505070301301D06",
        "03551D0E04160414D309E75C0725412D7A7922E3AACFB27F7EBD6BE0300E0603551D0F0101FF0404030205A0300A0608",
        "2A8648CE3D0403020347003044022048D4868CF393D9044101B6F07FD68D7F0642805F85DA74E2FE9DE8DD3507F02702",
        "201CD1BF7C6C7EDD59435E324925FCF0EBB3CAE2110D79407C77AA3B93B7BC04CB",
    ])

    /// Raw P-256 private scalar for part B's key, used only to sign the sensor's proof challenge
    /// (DexcomG7AuthBridge.m:43-44, :471).
    static let proofPrivateScalar: [UInt8] = hexBytes([
        "007CFBD596F6E74477B8C0E9F6F7A174275E101EF6BF7D18CAF01181D127B579",
    ])

    /// Certificate bytes for phase 0 or 1; phase 2 has none (DexcomG7AuthBridge.m:299-331).
    static func certificate(forPhase phase: UInt8) -> [UInt8]? {
        switch phase {
        case 0: return certificatePartA
        case 1: return certificatePartB
        case 2: return []
        default: return nil
        }
    }

    /// ECDSA P-256 over SHA-256(challenge), returned as the fixed 64-byte `r || s` the wire
    /// expects (DexcomG7ProofSigner.swift:17-24). CryptoKit's signature is randomized, so two
    /// calls differ; both verify against part B's public key.
    static func proofSignature(forChallenge challenge: [UInt8]) throws -> [UInt8] {
        let key = try P256.Signing.PrivateKey(rawRepresentation: proofPrivateScalar)
        let digest = SHA256.hash(data: challenge)
        return Array(try key.signature(for: digest).rawRepresentation)
    }

    private static func hexBytes(_ lines: [String]) -> [UInt8] {
        let hex = Array(lines.joined().utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = 0
        while index + 1 < hex.count {
            bytes.append(nibble(hex[index]) << 4 | nibble(hex[index + 1]))
            index += 2
        }
        return bytes
    }

    private static func nibble(_ ascii: UInt8) -> UInt8 {
        switch ascii {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return ascii - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return ascii - UInt8(ascii: "A") + 10
        default: preconditionFailure("G7OwnershipCredentials: invalid hex constant")
        }
    }
}
