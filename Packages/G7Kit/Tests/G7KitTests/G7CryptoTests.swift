// Original to Sensor (no ported code).

import CryptoKit
import XCTest
@testable import G7Kit

/// No captured J-PAKE vectors exist in xDrip4iOS or G7SensorKit (xDrip's comment mentions a
/// Juggluco round-1 vector that is not in the repository). So: the P-256 primitives are checked
/// against CryptoKit (known answers), AES against published vectors, and the J-PAKE exchange
/// round-trips against the independently written server in G7SensorSimulator.
final class G7ECCTests: XCTestCase {
    private func scalar(_ value: UInt8) -> G7Scalar {
        G7Scalar([UInt8](repeating: 0, count: 31) + [value])!
    }

    /// CryptoKit derives the public key G·k for a raw private scalar k.
    private func cryptoKitPublicPoint(_ k: G7Scalar) throws -> G7Point {
        let key = try P256.Signing.PrivateKey(rawRepresentation: k.bytes)
        return G7Point(Array(key.publicKey.rawRepresentation))!
    }

    func test_generatorMultiplyMatchesCryptoKit() throws {
        XCTAssertEqual(G7ECC.multiplyGenerator(by: scalar(1)), G7ECC.generator)
        XCTAssertEqual(try cryptoKitPublicPoint(scalar(1)), G7ECC.generator, "hard-coded G is the P-256 generator")
        for _ in 0..<8 {
            let key = P256.Signing.PrivateKey()
            let k = G7Scalar(Array(key.rawRepresentation))!
            XCTAssertEqual(G7ECC.multiplyGenerator(by: k), G7Point(Array(key.publicKey.rawRepresentation)))
            XCTAssertEqual(G7ECC.multiply(G7ECC.generator, by: k), G7Point(Array(key.publicKey.rawRepresentation)))
        }
    }

    func test_pointAddSubtractMatchScalarArithmetic() throws {
        let g5 = try cryptoKitPublicPoint(scalar(5)), g7 = try cryptoKitPublicPoint(scalar(7))
        XCTAssertEqual(G7ECC.add(g5, g7), try cryptoKitPublicPoint(scalar(12)))
        XCTAssertEqual(G7ECC.subtract(g7, g5), try cryptoKitPublicPoint(scalar(2)))
        XCTAssertEqual(G7ECC.add(g5, g5), try cryptoKitPublicPoint(scalar(10)), "doubling path")
        XCTAssertNil(G7ECC.subtract(g5, g5), "point at infinity is reported as failure")
    }

    func test_scalarArithmeticModN() throws {
        let a = G7ECC.randomScalar()!, b = G7ECC.randomScalar()!
        // G·(a·b) == (G·a)·b and G·(a − b) + G·b == G·a.
        XCTAssertEqual(G7ECC.multiplyGenerator(by: G7ECC.multiplyModN(a, b)), G7ECC.multiply(G7ECC.multiplyGenerator(by: a)!, by: b))
        XCTAssertEqual(G7ECC.add(G7ECC.multiplyGenerator(by: G7ECC.subtractModN(a, b))!, G7ECC.multiplyGenerator(by: b)!), G7ECC.multiplyGenerator(by: a))
        // n + 5 reduces to 5 (n = P-256 group order, SEC 2).
        let nPlus5 = Data(hex: "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632556")
        XCTAssertEqual(G7ECC.reduceModN([UInt8](nPlus5)), scalar(5))
        XCTAssertEqual(G7ECC.scalar(fromBytes: Array("1234".utf8)), G7Scalar([UInt8](repeating: 0, count: 28) + [0x31, 0x32, 0x33, 0x34]))
    }

    func test_pointValidationAndKeyPairs() throws {
        XCTAssertTrue(G7ECC.isValid(G7ECC.generator))
        var offCurve = G7ECC.generator.bytes
        offCurve[63] ^= 0x01
        XCTAssertFalse(G7ECC.isValid(G7Point(offCurve)!))
        let pair = try XCTUnwrap(G7ECC.generateKeyPair())
        XCTAssertEqual(G7ECC.multiplyGenerator(by: pair.privateKey), pair.publicKey)
        XCTAssertNil(G7Point([0x01]))
        XCTAssertNil(G7Scalar([0x01]))
    }
}

final class G7ChallengeHashTests: XCTestCase {
    /// FIPS-197 Appendix C.1 AES-128 known answer.
    func test_aes128KnownAnswer() {
        let key = [UInt8](Data(hex: "000102030405060708090a0b0c0d0e0f"))
        let plain = [UInt8](Data(hex: "00112233445566778899aabbccddeeff"))
        XCTAssertEqual(G7ChallengeHash.aes128ECBEncrypt(plain, key: key), [UInt8](Data(hex: "69c4e0d86a7b0430d8cdb78070b4c55a")))
        XCTAssertNil(G7ChallengeHash.aes128ECBEncrypt([0x00], key: key))
    }

    /// Same construction as G6 authentication: LoopKit CGMBLEKit TransmitterIDTests.swift:14-17,
    /// key "00" + "123456" + "00" + "123456" (Transmitter.swift:413-415).
    func test_challengeHashKnownAnswer() {
        let key = Array("0012345600123456".utf8)
        XCTAssertEqual(G7ChallengeHash.hash([UInt8](Data(hex: "0123456789abcdef")), key: key), [UInt8](Data(hex: "e60d4a7999b0fbb2")))
        XCTAssertNil(G7ChallengeHash.hash([0x01], key: key))
        XCTAssertNil(G7ChallengeHash.hash([UInt8](repeating: 0, count: 8), key: [0x01]))
    }
}

final class G7JPAKETests: XCTestCase {
    func test_pairingCodeMustBeFourAsciiDigits() {
        XCTAssertTrue(G7PairingCode.isValid("0123"))
        XCTAssertFalse(G7PairingCode.isValid("123"))
        XCTAssertFalse(G7PairingCode.isValid("12345"))
        XCTAssertFalse(G7PairingCode.isValid("12a4"))
        XCTAssertFalse(G7PairingCode.isValid("١٢٣٤"), "Arabic-Indic digits pass xDrip4iOS's isNumber check but are not ASCII")
        XCTAssertThrowsError(try G7JPAKEClient(pairingCode: "12"))
    }

    /// Our client against the simulator's server: both ends must derive the same 16-byte key.
    func test_roundTripDerivesTheSensorsKey() throws {
        let sensor = G7SensorSimulator(pairingCode: "4817")
        let link = FakeLink()
        let session = G7AuthSession(link: link, slot: .mobileApp, pairingCode: "4817", savedKey: nil)
        let delegate = RecordingAuthDelegate()
        session.delegate = delegate
        let driver = LinkDriver(link: link, sensor: sensor,
                                deliverNotify: { characteristic, enabled, _ in session.notificationStateChanged(for: characteristic, isNotifying: enabled) },
                                deliverValue: { characteristic, value in
                                    if characteristic == .authStream { session.receiveAuthStream(value) } else { session.receiveAuthentication(value) }
                                })
        session.begin()
        driver.pump()
        let key = try XCTUnwrap(delegate.authenticatedKeys.first ?? nil)
        XCTAssertEqual(key.count, 16)
        XCTAssertEqual(sensor.confirmedKeys[0x02], key, "sensor and client agree on the key, confirmed for slot 2")
    }

    func test_tamperedProofIsRejected() throws {
        let client = try G7JPAKEClient(pairingCode: "1234")
        // A valid server packet whose proof scalar is altered by one bit.
        let x = G7ECC.randomScalar()!, publicKey = G7ECC.multiplyGenerator(by: x)!
        let v = G7ECC.randomScalar()!, proofPoint = G7ECC.multiplyGenerator(by: v)!
        let h = G7SensorSimulator.hash(base: G7ECC.generator, v: proofPoint, x: publicKey, identity: Array("server".utf8))
        var r = G7ECC.subtractModN(v, G7ECC.multiplyModN(h, x)).bytes
        XCTAssertNoThrow(try G7JPAKEClient(pairingCode: "1234").handle(phase: 0, remotePayload: publicKey.bytes + proofPoint.bytes + r))
        r[31] ^= 0x01
        XCTAssertThrowsError(try client.handle(phase: 0, remotePayload: publicKey.bytes + proofPoint.bytes + r)) { error in
            XCTAssertEqual(error as? G7JPAKEClient.Failure, .proofDidNotValidate(phase: 0))
        }
    }

    func test_proofWithClientIdentityIsRejected() throws {
        // A proof made for the other role must not validate as the sensor's (identity is hashed in).
        let x = G7ECC.randomScalar()!, publicKey = G7ECC.multiplyGenerator(by: x)!
        let v = G7ECC.randomScalar()!, proofPoint = G7ECC.multiplyGenerator(by: v)!
        let h = G7SensorSimulator.hash(base: G7ECC.generator, v: proofPoint, x: publicKey, identity: Array("client".utf8))
        let r = G7ECC.subtractModN(v, G7ECC.multiplyModN(h, x)).bytes
        XCTAssertThrowsError(try G7JPAKEClient(pairingCode: "1234").handle(phase: 0, remotePayload: publicKey.bytes + proofPoint.bytes + r))
    }

    func test_malformedPayloadsAndPhases() throws {
        let client = try G7JPAKEClient(pairingCode: "1234")
        XCTAssertThrowsError(try client.handle(phase: 0, remotePayload: [UInt8](repeating: 0, count: 100))) {
            XCTAssertEqual($0 as? G7JPAKEClient.Failure, .malformedPayload)
        }
        XCTAssertThrowsError(try client.handle(phase: 0, remotePayload: [UInt8](repeating: 1, count: 160))) {
            XCTAssertEqual($0 as? G7JPAKEClient.Failure, .invalidPoint)
        }
        let valid = G7ECC.generator.bytes + G7ECC.generator.bytes + [UInt8](repeating: 1, count: 32)
        XCTAssertThrowsError(try client.handle(phase: 2, remotePayload: valid)) {
            XCTAssertEqual($0 as? G7JPAKEClient.Failure, .missingEarlierRound)
        }
        XCTAssertThrowsError(try client.handle(phase: 7, remotePayload: valid)) {
            XCTAssertEqual($0 as? G7JPAKEClient.Failure, .unexpectedPhase(7))
        }
        XCTAssertThrowsError(try G7JPAKEClient(pairingCode: "1234", keyPair: { nil })) {
            XCTAssertEqual($0 as? G7JPAKEClient.Failure, .randomnessUnavailable)
        }
    }
}

final class G7OwnershipCredentialTests: XCTestCase {
    /// Part C must be the private key of the public key inside part B's certificate, otherwise the
    /// sensor could never verify our proof. The SubjectPublicKeyInfo prefix for P-256 is
    /// 3059 3013 0607 2a8648ce3d0201 0608 2a8648ce3d030107 034200 (RFC 5480).
    func test_proofKeyMatchesClientCertificate() throws {
        let spkiPrefix = [UInt8](Data(hex: "3059301306072a8648ce3d020106082a8648ce3d030107034200"))
        let partB = G7OwnershipCredentials.certificatePartB
        let start = try XCTUnwrap((0...(partB.count - spkiPrefix.count)).first { Array(partB[$0..<$0 + spkiPrefix.count]) == spkiPrefix })
        let certificateKey = Array(partB[(start + spkiPrefix.count)..<(start + spkiPrefix.count + 65)])
        let derived = try P256.Signing.PrivateKey(rawRepresentation: G7OwnershipCredentials.proofPrivateScalar).publicKey
        XCTAssertEqual(Array(derived.x963Representation), certificateKey)
    }

    func test_certificatesAreDERAndSignatureVerifies() throws {
        XCTAssertEqual(G7OwnershipCredentials.certificatePartA.count, 494)
        XCTAssertEqual(G7OwnershipCredentials.certificatePartB.count, 465)
        XCTAssertEqual(Array(G7OwnershipCredentials.certificatePartA.prefix(2)), [0x30, 0x82])
        XCTAssertEqual(G7OwnershipCredentials.certificate(forPhase: 2), [])
        XCTAssertNil(G7OwnershipCredentials.certificate(forPhase: 3))
        let challenge = [UInt8](repeating: 0x5A, count: 16)
        let signature = try G7OwnershipCredentials.proofSignature(forChallenge: challenge)
        XCTAssertEqual(signature.count, 64)
        let publicKey = try P256.Signing.PrivateKey(rawRepresentation: G7OwnershipCredentials.proofPrivateScalar).publicKey
        XCTAssertTrue(publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: SHA256.hash(data: challenge)))
    }
}

/// Records G7AuthSession callbacks.
final class RecordingAuthDelegate: G7AuthSessionDelegate {
    var authenticatedKeys: [[UInt8]?] = []
    var savedKeyRejected = 0
    var needsFullBootstrap = 0
    var failures: [G7AuthFailure] = []
    var logs: [String] = []

    func authSessionDidAuthenticate(newlyConfirmedKey: [UInt8]?) { authenticatedKeys.append(newlyConfirmedKey) }
    func authSessionDidRejectSavedKey() { savedKeyRejected += 1 }
    func authSessionNeedsFullBootstrap() { needsFullBootstrap += 1 }
    func authSessionDidFail(_ failure: G7AuthFailure) { failures.append(failure) }
    func authSessionLog(_ message: String) { logs.append(message) }
}
