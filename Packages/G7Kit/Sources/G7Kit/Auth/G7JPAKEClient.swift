// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// The original file carries no copyright header of its own.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/DexcomG7AuthBridge.m @ 7.1.0 (0370937)
// Changes: Objective-C → Swift. Only the J-PAKE part of the bridge is here (the AES challenge,
// certificates and proof signing are in sibling files). Randomness is injectable for tests. The
// 6-digit pairing-code branch (DexcomG7AuthBridge.m:926-929) is dropped: G7 codes are 4 digits.
// Key persistence is not here: the caller confirms and stores the key (G7CredentialStore).

import CryptoKit
import Foundation

/// The client ("Alice") side of the G7 J-PAKE exchange on P-256.
///
/// The exchange is standard EC J-PAKE (RFC 8236) with Schnorr zero-knowledge proofs (RFC 8235),
/// the same construction and party identities as mbedTLS `ecjpake` ("client" / "server"):
///
///     phase 0: sensor sends G3 + ZKP(x3), we send G1 = G·x1 + ZKP(x1)        control `0A 01`
///     phase 1: sensor sends G4 + ZKP(x4), we send G2 = G·x2 + ZKP(x2)        control `0A 02`
///     phase 2: sensor sends B = (G1+G2+G3)·(x4·s) + ZKP,
///              we send A = (G1+G3+G4)·(x2·s) + ZKP, then the `0x02` auth request
///     key:     K = (B − G4·(x2·s))·x2;  sharedKey = SHA-256(K.x)[0..<16]
///
/// where s is the pairing code as a big-endian integer of its ASCII bytes.
/// Sources: DexcomG7AuthBridge.m:351-450 (phases), :678-728 (packet), :730-802 (validation),
/// :804-858 (round 3), :860-903 (key), :905-935 (password scalar), :937-967 (hash).
///
/// Every J-PAKE payload is 160 bytes: public point (64) || proof point V (64) || proof scalar r (32)
/// (DexcomG7AuthBridge.m:51, :643-676).
final class G7JPAKEClient {
    static let payloadLength = 160

    enum Failure: Error, Equatable {
        case invalidPairingCode
        case randomnessUnavailable
        case malformedPayload
        case invalidPoint
        case proofDidNotValidate(phase: UInt8)
        case missingEarlierRound
        case arithmeticFailed
        case unexpectedPhase(UInt8)
    }

    struct PhaseResult: Equatable {
        /// Our 160-byte payload for this phase, to be sent on Auth_Stream in 20-byte chunks.
        let payload: [UInt8]
        /// Phases 0 and 1: `0A 01` / `0A 02`. Phase 2: nil (the caller sends the `0x02` auth request).
        let controlPacket: Data?
        /// Phase 2 only: the candidate 16-byte shared key. Not trusted until the sensor confirms
        /// ownership (`06 01` or `08 01`), DexcomG7AuthBridge.m:557-562.
        let candidateSharedKey: [UInt8]?
    }

    /// Party identities hashed into every proof: ASCII "client" (us) and "server" (the sensor).
    /// DexcomG7AuthBridge.m:46-49 (validated against Juggluco's captured round-1 vector there).
    static let clientIdentity: [UInt8] = Array("client".utf8)
    static let serverIdentity: [UInt8] = Array("server".utf8)

    private let password: G7Scalar
    private let randomScalar: () -> G7Scalar?
    private let x1: G7Scalar
    private let g1: G7Point
    private let x2: G7Scalar
    private let g2: G7Point
    private var remoteG3: G7Point?
    private var remoteG4: G7Point?

    /// - Parameters:
    ///   - pairingCode: the 4-digit code printed on the applicator.
    ///   - keyPair: source of (x, G·x); defaults to micro-ecc's CSPRNG-backed generator.
    ///   - randomScalar: source of proof nonces; defaults to micro-ecc's CSPRNG.
    convenience init(
        pairingCode: String,
        keyPair: () -> (privateKey: G7Scalar, publicKey: G7Point)? = G7ECC.generateKeyPair,
        randomScalar: @escaping () -> G7Scalar? = G7ECC.randomScalar
    ) throws(Failure) {
        guard G7PairingCode.isValid(pairingCode) else { throw .invalidPairingCode }
        // s = ASCII bytes of the code as a big-endian integer, left-padded to 32 bytes
        // (DexcomG7AuthBridge.m:915-934 via DexcomG7ECCScalarFromBytes).
        try self.init(passwordBytes: Array(pairingCode.utf8), keyPair: keyPair, randomScalar: randomScalar)
    }

    /// Any password up to 32 bytes, as a big-endian integer. Only the 4-digit initializer above is
    /// used for the sensor; this one exists so the mbedTLS self-test vectors (password
    /// "threadjpaketest") can be run as a known-answer test.
    init(
        passwordBytes: [UInt8],
        keyPair: () -> (privateKey: G7Scalar, publicKey: G7Point)?,
        randomScalar: @escaping () -> G7Scalar?
    ) throws(Failure) {
        guard !passwordBytes.isEmpty, passwordBytes.count <= G7Scalar.byteCount else { throw .invalidPairingCode }
        password = G7ECC.scalar(fromBytes: passwordBytes)
        guard let first = keyPair(), let second = keyPair() else { throw .randomnessUnavailable }
        x1 = first.privateKey
        g1 = first.publicKey
        x2 = second.privateKey
        g2 = second.publicKey
        self.randomScalar = randomScalar
    }

    /// Validates the sensor's payload for `phase` and returns ours (DexcomG7AuthBridge.m:351-450).
    func handle(phase: UInt8, remotePayload: [UInt8]) throws(Failure) -> PhaseResult {
        let remote = try Self.parse(remotePayload)
        switch phase {
        case 0:
            try validate(remote, base: G7ECC.generator, party: Self.serverIdentity, phase: phase)
            remoteG3 = remote.publicKey
            let ours = try makePacket(privateKey: x1, publicKey: g1, base: G7ECC.generator)
            return PhaseResult(payload: ours, controlPacket: G7PakeControl.request(phase: 1), candidateSharedKey: nil)
        case 1:
            try validate(remote, base: G7ECC.generator, party: Self.serverIdentity, phase: phase)
            remoteG4 = remote.publicKey
            let ours = try makePacket(privateKey: x2, publicKey: g2, base: G7ECC.generator)
            return PhaseResult(payload: ours, controlPacket: G7PakeControl.request(phase: 2), candidateSharedKey: nil)
        case 2:
            guard let g3 = remoteG3, let g4 = remoteG4 else { throw .missingEarlierRound }
            // B's base is G1 + G2 + G3 (DexcomG7AuthBridge.m:737-764).
            guard let g12 = G7ECC.add(g1, g2), let base = G7ECC.add(g12, g3) else { throw .arithmeticFailed }
            try validate(remote, base: base, party: Self.serverIdentity, phase: phase)
            // A = (G1 + G3 + G4)·(x2·s) with a proof over that base (DexcomG7AuthBridge.m:804-858).
            let x2s = G7ECC.multiplyModN(x2, password)
            guard let g13 = G7ECC.add(g1, g3), let g134 = G7ECC.add(g13, g4),
                  let publicA = G7ECC.multiply(g134, by: x2s) else { throw .arithmeticFailed }
            let ours = try makePacket(privateKey: x2s, publicKey: publicA, base: g134)
            // K = (B − G4·(x2·s))·x2; key = SHA-256(K.x)[0..<16] (DexcomG7AuthBridge.m:860-903).
            guard let g4x2s = G7ECC.multiply(g4, by: x2s),
                  let difference = G7ECC.subtract(remote.publicKey, g4x2s),
                  let keyPoint = G7ECC.multiply(difference, by: x2) else { throw .arithmeticFailed }
            let digest = Array(SHA256.hash(data: keyPoint.x))
            return PhaseResult(payload: ours, controlPacket: nil, candidateSharedKey: Array(digest[0..<16]))
        default:
            throw .unexpectedPhase(phase)
        }
    }

    // MARK: - Packets and proofs

    struct Packet: Equatable {
        let publicKey: G7Point
        let proofPoint: G7Point
        let proofScalar: G7Scalar
    }

    /// Splits a 160-byte payload and rejects off-curve points (DexcomG7AuthBridge.m:645-676).
    static func parse(_ payload: [UInt8]) throws(Failure) -> Packet {
        guard payload.count >= payloadLength else { throw .malformedPayload }
        guard let publicKey = G7Point(Array(payload[0..<64])),
              let proofPoint = G7Point(Array(payload[64..<128])),
              let proofScalar = G7Scalar(Array(payload[128..<160])) else { throw .malformedPayload }
        guard G7ECC.isValid(publicKey), G7ECC.isValid(proofPoint) else { throw .invalidPoint }
        return Packet(publicKey: publicKey, proofPoint: proofPoint, proofScalar: proofScalar)
    }

    /// Schnorr proof of knowledge of `privateKey` for `publicKey = base·privateKey`:
    /// v random, V = base·v, h = H(base, V, publicKey, "client"), r = v − h·privateKey (mod n).
    /// DexcomG7AuthBridge.m:678-728.
    private func makePacket(privateKey: G7Scalar, publicKey: G7Point, base: G7Point) throws(Failure) -> [UInt8] {
        guard let v = randomScalar() else { throw .randomnessUnavailable }
        guard let proofPoint = G7ECC.multiply(base, by: v) else { throw .arithmeticFailed }
        let h = Self.zeroKnowledgeHash(base: base, proofPoint: proofPoint, publicKey: publicKey, party: Self.clientIdentity)
        let r = G7ECC.subtractModN(v, G7ECC.multiplyModN(h, privateKey))
        return publicKey.bytes + proofPoint.bytes + r.bytes
    }

    /// Accepts the proof only if base·r + publicKey·h == V (DexcomG7AuthBridge.m:766-802).
    private func validate(_ packet: Packet, base: G7Point, party: [UInt8], phase: UInt8) throws(Failure) {
        guard Self.verifyProof(packet, base: base, party: party) else { throw .proofDidNotValidate(phase: phase) }
    }

    static func verifyProof(_ packet: Packet, base: G7Point, party: [UInt8]) -> Bool {
        let h = zeroKnowledgeHash(base: base, proofPoint: packet.proofPoint, publicKey: packet.publicKey, party: party)
        guard let left = G7ECC.multiply(base, by: packet.proofScalar),
              let right = G7ECC.multiply(packet.publicKey, by: h),
              let sum = G7ECC.add(left, right) else { return false }
        return sum == packet.proofPoint
    }

    /// h = SHA-256(len‖04‖base ‖ len‖04‖V ‖ len‖04‖X ‖ len‖party) mod n, each len a 4-byte
    /// big-endian length (DexcomG7AuthBridge.m:937-959).
    static func zeroKnowledgeHash(base: G7Point, proofPoint: G7Point, publicKey: G7Point, party: [UInt8]) -> G7Scalar {
        var input: [UInt8] = []
        for field in [base.uncompressed, proofPoint.uncompressed, publicKey.uncompressed, party] {
            input += G7Bytes.bigEndian(UInt32(field.count)) + field
        }
        return G7ECC.reduceModN(Array(SHA256.hash(data: input)))
    }
}

/// The 4-digit applicator pairing code (the J-PAKE password).
enum G7PairingCode {
    /// Exactly four ASCII digits, as xDrip4iOS requires (CGMG7Transmitter.swift:357, :504).
    static func isValid(_ code: String) -> Bool {
        code.utf8.count == 4 && code.utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
    }
}

extension G7Bytes {
    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}
