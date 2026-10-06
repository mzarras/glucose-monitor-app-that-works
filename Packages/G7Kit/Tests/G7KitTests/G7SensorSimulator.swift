// Original to Sensor (no ported code).
//
// A test-only model of a G7 sensor in primary mode, written from docs/g7-protocol.md and the
// public J-PAKE specifications (RFC 8236 EC J-PAKE, RFC 8235 Schnorr NIZK, mbedTLS ecjpake's
// "client"/"server" identities and length-prefixed hash). Its J-PAKE side is written separately from
// G7JPAKEClient on purpose: it plays the sensor ("server", x3/x4) and computes the key from the
// other end of the equations, so a client-side mistake cannot be mirrored here. It shares only the
// micro-ecc primitives, which G7CryptoTests checks against CryptoKit.

import CryptoKit
import Foundation
@testable import G7Kit

final class G7SensorSimulator {
    enum OwnershipCompletion { case keepAlive0601, legacyBond }

    let pairingCode: String
    /// Confirmed keys by slot byte, as the sensor remembers them.
    var confirmedKeys: [UInt8: [UInt8]] = [:]
    var ownershipCompletion: OwnershipCompletion = .keepAlive0601
    /// Byte 2 the sensor sends in `05` after a successful short authentication.
    var shortAuthPairedByte: UInt8 = 0x01

    // Data served after authentication.
    var glucoseResponse: Data?
    var extendedVersionResponse: Data? = Fixture.tenDayExtendedVersion
    var calibrationResponse: Data?
    var boundsResponse: Data?
    var backfillFrames: [Data] = []
    /// Everything written to Write_Control, for assertions.
    private(set) var controlWrites: [Data] = []

    private(set) var sessionAuthenticated = false
    private var inbound: [UInt8] = []
    private var key: [UInt8]?
    private var fullBootstrap = false
    private var challenge: [UInt8] = []
    private var slot: UInt8 = 0
    private var proofChallenge: [UInt8] = []
    private var certificateLengths: [UInt8: Int] = [:]

    // J-PAKE server state.
    private var x3: G7Scalar?
    private var x4: G7Scalar?
    private var g1: G7Point?
    private var g2: G7Point?
    private var g3: G7Point?
    private var g4: G7Point?

    init(pairingCode: String) {
        self.pairingCode = pairingCode
    }

    /// A new physical connection: authentication is per connection; confirmed keys persist.
    func beginConnection() {
        sessionAuthenticated = false
        inbound = []
        key = nil
        fullBootstrap = false
        challenge = []
        proofChallenge = []
        certificateLengths = [:]
        (x3, x4, g1, g2, g3, g4) = (nil, nil, nil, nil, nil, nil)
    }

    /// The sensor's reaction to one write.
    func handleWrite(_ data: Data, to characteristic: G7Characteristic) -> [(G7Characteristic, Data)] {
        let bytes = [UInt8](data)
        switch characteristic {
        case .authStream:
            inbound += bytes
            return []
        case .receiveAuthentication:
            return handleAuthentication(bytes)
        case .writeControl:
            guard sessionAuthenticated else { return [] }
            controlWrites.append(data)
            switch bytes.first {
            case 0x4E: return glucoseResponse.map { [(.writeControl, $0)] } ?? []
            case 0x52: return extendedVersionResponse.map { [(.writeControl, $0)] } ?? []
            case 0x34: return calibrationResponse.map { [(.writeControl, $0)] } ?? []
            case 0x32: return boundsResponse.map { [(.writeControl, $0)] } ?? []
            default: return []
            }
        case .backfill, .communication:
            return []
        }
    }

    /// Enabling Backfill notifications makes the sensor send its records, then `59`.
    func notificationsEnabled(_ characteristic: G7Characteristic) -> [(G7Characteristic, Data)] {
        guard characteristic == .backfill, sessionAuthenticated else { return [] }
        return backfillFrames.map { (.backfill, $0) } + [(.writeControl, Data([0x59]))]
    }

    // MARK: - Authentication

    private func handleAuthentication(_ bytes: [UInt8]) -> [(G7Characteristic, Data)] {
        switch bytes.first {
        case 0x0A: return pakePhase(bytes[1])
        case 0x02: return authRequest(token: Array(bytes[1..<9]), slot: bytes[9])
        case 0x04: return challengeAnswer(Array(bytes[1..<9]))
        case 0x0B: return certificatePhase(bytes)
        case 0x0C:
            proofChallenge = G7Random.bytes(16)
            return [(.receiveAuthentication, Data([0x0C, 0x00] + proofChallenge))] + stream(G7Random.bytes(64))
        case 0x0D:
            guard verifyProofSignature() else { return [] }
            return [(.receiveAuthentication, Data([0x0D, 0x00]))]
        case 0x06:
            switch ownershipCompletion {
            case .keepAlive0601:
                confirmedKeys[slot] = key
                return [(.receiveAuthentication, Data([0x06, 0x01]))]
            case .legacyBond:
                return [(.receiveAuthentication, Data([0x06, 0x00]))]
            }
        case 0x07:
            confirmedKeys[slot] = key
            return [(.receiveAuthentication, Data([0x07, 0x00])), (.receiveAuthentication, Data([0x08, 0x01]))]
        default:
            return []
        }
    }

    private func pakePhase(_ phase: UInt8) -> [(G7Characteristic, Data)] {
        let generator = G7ECC.generator
        switch phase {
        case 0:
            fullBootstrap = true
            let pair3 = G7ECC.generateKeyPair()!, pair4 = G7ECC.generateKeyPair()!
            (x3, g3, x4, g4) = (pair3.privateKey, pair3.publicKey, pair4.privateKey, pair4.publicKey)
            return [(.receiveAuthentication, Data([0x0A, 0x00, 0x00]))] + stream(proof(x3!, g3!, base: generator))
        case 1:
            g1 = take160(verifyingBase: generator)
            return [(.receiveAuthentication, Data([0x0A, 0x00, 0x01]))] + stream(proof(x4!, g4!, base: generator))
        case 2:
            g2 = take160(verifyingBase: generator)
            // B = (G1 + G2 + G3)·(x4·s), RFC 8236 §3 (Bob's round 2).
            let base = G7ECC.add(G7ECC.add(g1!, g2!)!, g3!)!
            let x4s = G7ECC.multiplyModN(x4!, password)
            let b = G7ECC.multiply(base, by: x4s)!
            return [(.receiveAuthentication, Data([0x0A, 0x00, 0x02]))] + stream(proof(x4s, b, base: base))
        default:
            return []
        }
    }

    private func authRequest(token: [UInt8], slot: UInt8) -> [(G7Characteristic, Data)] {
        self.slot = slot
        if fullBootstrap {
            // Alice's A over base G1 + G3 + G4; K = (A − G2·(x4·s))·x4; key = SHA-256(K.x)[0..<16].
            let base = G7ECC.add(G7ECC.add(g1!, g3!)!, g4!)!
            guard let a = take160(verifyingBase: base) else { return [(.receiveAuthentication, Data([0x05, 0x00, 0x02]))] }
            let x4s = G7ECC.multiplyModN(x4!, password)
            let k = G7ECC.multiply(G7ECC.subtract(a, G7ECC.multiply(g2!, by: x4s)!)!, by: x4!)!
            key = Array(Array(SHA256.hash(data: k.x))[0..<16])
        } else {
            key = confirmedKeys[slot]
        }
        challenge = G7Random.bytes(8)
        let tokenHash = key.flatMap { G7ChallengeHash.hash(token, key: $0) } ?? [UInt8](repeating: 0, count: 8)
        return [(.receiveAuthentication, Data([0x03] + tokenHash + challenge))]
    }

    private func challengeAnswer(_ hash: [UInt8]) -> [(G7Characteristic, Data)] {
        guard let key, G7ChallengeHash.hash(challenge, key: key) == hash else {
            return [(.receiveAuthentication, Data([0x05, 0x02, 0x02]))]
        }
        if fullBootstrap {
            return [(.receiveAuthentication, Data([0x05, 0x01, 0x02]))]
        }
        sessionAuthenticated = shortAuthPairedByte != 0x02
        return [(.receiveAuthentication, Data([0x05, 0x01, shortAuthPairedByte]))]
    }

    private func certificatePhase(_ bytes: [UInt8]) -> [(G7Characteristic, Data)] {
        let phase = bytes[1]
        certificateLengths[phase] = Int(G7Bytes.uint32(bytes, at: 2))
        // Our certificate for the previous phase must have arrived on Auth_Stream.
        if phase > 0, let expected = certificateLengths[phase - 1] {
            guard inbound.count >= expected else { return [] }
            inbound.removeFirst(expected)
        }
        let size: UInt32 = phase == 0 ? 30 : (phase == 1 ? 25 : 0)
        return [(.receiveAuthentication, Data([0x0B, 0x00, phase] + G7Bytes.littleEndian(size)))]
            + stream(G7Random.bytes(Int(size)))
    }

    private func verifyProofSignature() -> Bool {
        guard inbound.count >= 64 else { return false }
        let signature = Array(inbound[0..<64])
        inbound.removeFirst(64)
        let publicKey = try? P256.Signing.PrivateKey(rawRepresentation: G7OwnershipCredentials.proofPrivateScalar).publicKey
        guard let publicKey, let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        let valid = publicKey.isValidSignature(ecdsa, for: SHA256.hash(data: proofChallenge))
        if valid, ownershipCompletion == .keepAlive0601 || ownershipCompletion == .legacyBond {
            sessionAuthenticated = true
        }
        return valid
    }

    // MARK: - J-PAKE helpers (server side)

    private var password: G7Scalar {
        // s = ASCII digits as a big-endian integer (RFC 8236 leaves the encoding to the protocol).
        var bytes = [UInt8](repeating: 0, count: 32)
        let ascii = Array(pairingCode.utf8)
        bytes.replaceSubrange((32 - ascii.count)..<32, with: ascii)
        return G7Scalar(bytes)!
    }

    /// Schnorr NIZK (RFC 8235) with the server identity: V = base·v, r = v − h·x.
    private func proof(_ x: G7Scalar, _ publicKey: G7Point, base: G7Point) -> [UInt8] {
        let v = G7ECC.randomScalar()!
        let proofPoint = G7ECC.multiply(base, by: v)!
        let h = Self.hash(base: base, v: proofPoint, x: publicKey, identity: Array("server".utf8))
        let r = G7ECC.subtractModN(v, G7ECC.multiplyModN(h, x))
        return publicKey.bytes + proofPoint.bytes + r.bytes
    }

    /// Consumes a 160-byte client packet and checks its proof with the client identity.
    private func take160(verifyingBase base: G7Point) -> G7Point? {
        guard inbound.count >= 160 else { return nil }
        let packet = Array(inbound[0..<160])
        inbound.removeFirst(160)
        let x = G7Point(Array(packet[0..<64]))!
        let v = G7Point(Array(packet[64..<128]))!
        let r = G7Scalar(Array(packet[128..<160]))!
        let h = Self.hash(base: base, v: v, x: x, identity: Array("client".utf8))
        let check = G7ECC.add(G7ECC.multiply(base, by: r)!, G7ECC.multiply(x, by: h)!)
        return check == v ? x : nil
    }

    /// h = SHA-256 over (4-byte big-endian length ‖ value) for 04‖base, 04‖V, 04‖X, identity; mod n.
    static func hash(base: G7Point, v: G7Point, x: G7Point, identity: [UInt8]) -> G7Scalar {
        var input: [UInt8] = []
        for field in [[0x04] + base.bytes, [0x04] + v.bytes, [0x04] + x.bytes, identity] {
            let length = UInt32(field.count)
            input += [UInt8(length >> 24), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
            input += field
        }
        return G7ECC.reduceModN(Array(SHA256.hash(data: input)))
    }

    private func stream(_ bytes: [UInt8]) -> [(G7Characteristic, Data)] {
        stride(from: 0, to: bytes.count, by: 20).map { (.authStream, Data(bytes[$0..<min($0 + 20, bytes.count)])) }
    }
}
