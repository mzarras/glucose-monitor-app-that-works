// Original to Sensor (no ported code). Test vectors are data from Mbed TLS (cited below).

import XCTest
@testable import G7Kit

/// Known-answer tests against the Mbed TLS EC J-PAKE self-test (Mbed TLS v3.6.2, commit 107ea89,
/// `library/ecjpake.c:838-977`, Apache-2.0 OR GPL-2.0-or-later; vendor-ref/mbedtls). Mbed TLS uses the
/// same construction the G7 uses (docs/g7-protocol.md §3.3): P-256, SHA-256, identities "client" and
/// "server", 4-byte big-endian length-prefixed uncompressed points in the proof hash, h mod n,
/// r = v − x·h, and PMS = SHA-256(K.x). Its messages are TLS-encoded (`41 04 X Y` points,
/// `20 r` scalars); the helpers below unpack them into the G7's raw 160-byte payloads.
final class G7JPAKEKnownAnswerTests: XCTestCase {
    private static let password = hex("7468726561646a70616b6574657374") // "threadjpaketest"
    private static let x1 = hex("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f21")
    private static let x2 = hex("6162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f81")
    private static let x3 = hex("6162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f81")
    private static let x4 = hex("c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe1")
    private static let cliOne = hex(
        "4104accf0106ef858fa2d919331346805a78b58bbad0b844e5c7892879146187dd2666ada781bb7f111372251a891062"
            + "1f634df128ac48e381fd6ef9060731f694a441041dd0bd5d4566c9bed9ce7de701b5e82e08e84b730466018ab903c79e"
            + "b982172236c0c1728ae4bf73610d34de44246ef3d9c05a2236fb66a6583d7449308babce2072fe16662992e9235c2500"
            + "2f11b15087b82738e03c945bf7a2995dda1e98345841047ea6e3a4487037a9e0dbd79262b2cc273e779930fc18409ac5"
            + "361c5fe669d702e147790aeb4ce7fd6575ab0f6c7fd1c335939aa863ba37ec91b7e32bb013bb2b4104a49558d32ed1eb"
            + "fc1816af4ff09b55fcb4ca47b2a02d1e7caf1179ea3fe1395b22b861964016fabaf72c975695d93d4df0e5197fe9f040"
            + "634ed59764937787be20bc4deebbf9b8d60a335f046ca3aa941e45864c7cadef9cf75b3d8b010e443ef0"
    )
    private static let srvOne = hex(
        "41047ea6e3a4487037a9e0dbd79262b2cc273e779930fc18409ac5361c5fe669d702e147790aeb4ce7fd6575ab0f6c7f"
            + "d1c335939aa863ba37ec91b7e32bb013bb2b410409f85b3d20ebd7885ce464c08d056d6428fe4dd9287aa365f131f436"
            + "0ff386d846898bc4b41583c2a5197f65d78742746c12a5ec0a4ffe2f270a750a1d8fb51620934d74eb43e54df424fd96"
            + "306c0117bf131afabf90a9d33d1198d905193735144104190a07700ffa4be6ae1d79ee0f06aeb544cd5addaabedf70f8"
            + "623321332c54f355f0fbfec783ed359e5d0bf7377a0fc4ea7ace473c9c112b41ccd41ac56a56124104360a1cea33fce6"
            + "41156458e0a4eac219e96831e6aebc88b3f3752f93a0281d1bf1fb106051db9694a8d6e862a5ef1324a3d9e27894f1ee"
            + "4f7c59199965a8dd4a2091847d2d22df3ee55faa2a3fb33fd2d1e055a07a7c61ecfb8d80ec00c2c9eb12"
    )
    /// `03 0017` (named curve secp256r1) then the server's round-two key.
    private static let srvTwo = hex(
        "03001741040fb22b1d5d1123e0ef9feb9d8a2e590a1f4d7ced2c2b06586e8f2a16d4eb2fda4328a20b07d8fd667654ca"
            + "18c54e32a333a0845451e926ee8804fd7af0aaa7a641045516ea3e54a0d5d8b2ce786b38d383370029a5dbe4459c9dd6"
            + "01b408a24ae6465c8ac905b9eb03b5d3691c139ef83f1cd4200f6c9cd4ec392218a59ed243d3c820ff724a9a70b88cb8"
            + "6f20b434c6865aa1cd7906dd7c9bce3525f508276f26836c"
    )
    private static let cliTwo = hex(
        "410469d54ee85e90ce3f1246742de507e939e81d1dc1c5cb988b58c310c9fdd9524d93720b45541c83ee8841191da7ce"
            + "d86e3312d43623c1d63e74989aba4affd1ee4104077e8c31e20e6bedb760c13593e69f15be85c27d68cd09ccb8c41836"
            + "08917c5c3d409fac39fefee82f7292d36f0d23e055913f45a52b85dd8a2052e9e129bb4d200f011f19483535a6e89a58"
            + "0c9b0003baf21462ece91a82cc38dbdcae60d9c54c"
    )
    /// PMS = SHA-256(K.x); the G7 shared key is its first 16 bytes (DexcomG7AuthBridge.m:900-902).
    private static let pms = hex("f3d47f599844db92a569bbe7981e39d931fd743bf22e98f9b438f719d3c4f351")

    private static func hex(_ string: String) -> [UInt8] { [UInt8](Data(hex: string)) }

    /// One TLS ECJPAKEKeyKP: `41 04 X(64)`, `41 04 V(64)`, `len r` → the G7's 160-byte payload.
    private struct KeyKP {
        let x: G7Point
        let v: G7Point
        let r: G7Scalar
        var payload: [UInt8] { x.bytes + v.bytes + r.bytes }
    }

    private static func keyKPs(_ bytes: [UInt8], skipping prefix: Int = 0) -> [KeyKP] {
        var offset = prefix
        var result: [KeyKP] = []
        func point() -> G7Point {
            precondition(bytes[offset] == 0x41 && bytes[offset + 1] == 0x04)
            defer { offset += 66 }
            return G7Point(Array(bytes[(offset + 2)..<(offset + 66)]))!
        }
        while offset < bytes.count {
            let x = point()
            let v = point()
            let length = Int(bytes[offset])
            let r = Array(bytes[(offset + 1)..<(offset + 1 + length)])
            offset += 1 + length
            result.append(KeyKP(x: x, v: v, r: G7Scalar([UInt8](repeating: 0, count: 32 - length) + r)!))
        }
        return result
    }

    private func verify(_ keyKP: KeyKP, base: G7Point, identity: String) -> Bool {
        G7JPAKEClient.verifyProof(G7JPAKEClient.Packet(publicKey: keyKP.x, proofPoint: keyKP.v, proofScalar: keyKP.r),
                                  base: base, party: Array(identity.utf8))
    }

    /// Our proof verification (hash layout, identities, reduction, equation) accepts every proof
    /// Mbed TLS produced, and rejects them under the wrong identity.
    func test_ourProofCheckAcceptsMbedTLSProofs() throws {
        let client = Self.keyKPs(Self.cliOne)
        let server = Self.keyKPs(Self.srvOne)
        let serverTwo = try XCTUnwrap(Self.keyKPs(Self.srvTwo, skipping: 3).first)
        let clientTwo = try XCTUnwrap(Self.keyKPs(Self.cliTwo).first)
        XCTAssertEqual(client.count, 2)
        XCTAssertEqual(server.count, 2)
        for keyKP in client { XCTAssertTrue(verify(keyKP, base: G7ECC.generator, identity: "client")) }
        for keyKP in server { XCTAssertTrue(verify(keyKP, base: G7ECC.generator, identity: "server")) }
        XCTAssertFalse(verify(client[0], base: G7ECC.generator, identity: "server"))
        // Round two: server base X1 + X2 + X3, client base X1 + X3 + X4 (RFC 8236 §3).
        let serverBase = try XCTUnwrap(G7ECC.add(try XCTUnwrap(G7ECC.add(client[0].x, client[1].x)), server[0].x))
        let clientBase = try XCTUnwrap(G7ECC.add(try XCTUnwrap(G7ECC.add(client[0].x, server[0].x)), server[1].x))
        XCTAssertTrue(verify(serverTwo, base: serverBase, identity: "server"))
        XCTAssertTrue(verify(clientTwo, base: clientBase, identity: "client"))
        // The public points are G·x for the published private scalars.
        XCTAssertEqual(G7ECC.multiplyGenerator(by: G7Scalar(Self.x1)!), client[0].x)
        XCTAssertEqual(G7ECC.multiplyGenerator(by: G7Scalar(Self.x2)!), client[1].x)
        XCTAssertEqual(G7ECC.multiplyGenerator(by: G7Scalar(Self.x3)!), server[0].x)
        XCTAssertEqual(G7ECC.multiplyGenerator(by: G7Scalar(Self.x4)!), server[1].x)
    }

    /// Our client, given Mbed TLS's x1 and x2 and fed the server's messages as the G7's three phases,
    /// produces the same round-two point as Mbed TLS's client and the same premaster secret.
    func test_ourClientDerivesMbedTLSPremasterSecret() throws {
        var keys = [Self.x1, Self.x2].map { G7Scalar($0)! }
        let client = try G7JPAKEClient(
            passwordBytes: Self.password,
            keyPair: {
                let x = keys.removeFirst()
                return (x, G7ECC.multiplyGenerator(by: x)!)
            },
            randomScalar: G7ECC.randomScalar
        )
        let server = Self.keyKPs(Self.srvOne)
        let serverTwo = try XCTUnwrap(Self.keyKPs(Self.srvTwo, skipping: 3).first)
        let expectedClient = Self.keyKPs(Self.cliOne)
        let expectedClientTwo = try XCTUnwrap(Self.keyKPs(Self.cliTwo).first)

        let phase0 = try client.handle(phase: 0, remotePayload: server[0].payload)
        XCTAssertEqual(Array(phase0.payload[0..<64]), expectedClient[0].x.bytes)
        let phase1 = try client.handle(phase: 1, remotePayload: server[1].payload)
        XCTAssertEqual(Array(phase1.payload[0..<64]), expectedClient[1].x.bytes)
        let phase2 = try client.handle(phase: 2, remotePayload: serverTwo.payload)
        XCTAssertEqual(Array(phase2.payload[0..<64]), expectedClientTwo.x.bytes, "A = (X1+X3+X4)·(x2·s)")
        XCTAssertEqual(phase2.candidateSharedKey, Array(Self.pms[0..<16]))
    }
}
