// Original to Sensor (no ported code). Thin Swift wrapper over Sources/G7ECC (ported C).

import G7ECC

/// A raw affine P-256 point: big-endian X (32 bytes) || big-endian Y (32 bytes), no 0x04 prefix.
struct G7Point: Equatable {
    static let byteCount = 64
    let bytes: [UInt8]

    init?(_ bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    /// SEC1 uncompressed encoding `04 || X || Y`, used inside the zero-knowledge hash
    /// (DexcomG7AuthBridge.m:961-967).
    var uncompressed: [UInt8] { [0x04] + bytes }

    /// The X coordinate (the J-PAKE shared key is derived from it, DexcomG7AuthBridge.m:900-902).
    var x: [UInt8] { Array(bytes[0..<32]) }
}

/// A 32-byte big-endian P-256 scalar.
struct G7Scalar: Equatable {
    static let byteCount = 32
    let bytes: [UInt8]

    init?(_ bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }
}

/// Calls into the ported micro-ecc wrapper (DexcomG7ECC.c). Every function returns nil where the
/// C function reports failure (e.g. the point at infinity).
enum G7ECC {
    /// The standard P-256 generator G (SEC 2 / FIPS 186-4), as hard-coded in DexcomG7AuthBridge.m:969-986.
    static let generator = G7Point([
        0x6b, 0x17, 0xd1, 0xf2, 0xe1, 0x2c, 0x42, 0x47, 0xf8, 0xbc, 0xe6, 0xe5, 0x63, 0xa4, 0x40, 0xf2,
        0x77, 0x03, 0x7d, 0x81, 0x2d, 0xeb, 0x33, 0xa0, 0xf4, 0xa1, 0x39, 0x45, 0xd8, 0x98, 0xc2, 0x96,
        0x4f, 0xe3, 0x42, 0xe2, 0xfe, 0x1a, 0x7f, 0x9b, 0x8e, 0xe7, 0xeb, 0x4a, 0x7c, 0x0f, 0x9e, 0x16,
        0x2b, 0xce, 0x33, 0x57, 0x6b, 0x31, 0x5e, 0xce, 0xcb, 0xb6, 0x40, 0x68, 0x37, 0xbf, 0x51, 0xf5,
    ])! // Safe: a literal of exactly 64 bytes; `G7Point.init?` checks only the length.

    static func generateKeyPair() -> (privateKey: G7Scalar, publicKey: G7Point)? {
        var publicKey = [UInt8](repeating: 0, count: G7Point.byteCount)
        var privateKey = [UInt8](repeating: 0, count: G7Scalar.byteCount)
        guard DexcomG7ECCGenerateKeyPair(&publicKey, &privateKey) else { return nil }
        guard let scalar = G7Scalar(privateKey), let point = G7Point(publicKey) else { return nil }
        return (scalar, point)
    }

    static func isValid(_ point: G7Point) -> Bool {
        DexcomG7ECCIsValidPoint(point.bytes)
    }

    static func add(_ left: G7Point, _ right: G7Point) -> G7Point? {
        var result = [UInt8](repeating: 0, count: G7Point.byteCount)
        guard DexcomG7ECCPointAdd(left.bytes, right.bytes, &result) else { return nil }
        return G7Point(result)
    }

    static func subtract(_ left: G7Point, _ right: G7Point) -> G7Point? {
        var result = [UInt8](repeating: 0, count: G7Point.byteCount)
        guard DexcomG7ECCPointSubtract(left.bytes, right.bytes, &result) else { return nil }
        return G7Point(result)
    }

    static func multiply(_ point: G7Point, by scalar: G7Scalar) -> G7Point? {
        var result = [UInt8](repeating: 0, count: G7Point.byteCount)
        guard DexcomG7ECCPointMultiply(point.bytes, scalar.bytes, &result) else { return nil }
        return G7Point(result)
    }

    static func multiplyGenerator(by scalar: G7Scalar) -> G7Point? {
        var result = [UInt8](repeating: 0, count: G7Point.byteCount)
        guard DexcomG7ECCGeneratorMultiply(scalar.bytes, &result) else { return nil }
        return G7Point(result)
    }

    static func randomScalar() -> G7Scalar? {
        var result = [UInt8](repeating: 0, count: G7Scalar.byteCount)
        guard DexcomG7ECCScalarRandom(&result) else { return nil }
        return G7Scalar(result)
    }

    static func multiplyModN(_ left: G7Scalar, _ right: G7Scalar) -> G7Scalar {
        var result = [UInt8](repeating: 0, count: G7Scalar.byteCount)
        _ = DexcomG7ECCScalarMultiplyModN(left.bytes, right.bytes, &result) // always true (DexcomG7ECC.c:307-320)
        // Safe: `result` was created above with exactly `G7Scalar.byteCount` bytes and the C function
        // writes into that fixed buffer only; `G7Scalar.init?` checks nothing but the length.
        return G7Scalar(result)!
    }

    static func subtractModN(_ left: G7Scalar, _ right: G7Scalar) -> G7Scalar {
        var result = [UInt8](repeating: 0, count: G7Scalar.byteCount)
        _ = DexcomG7ECCScalarSubtractModN(left.bytes, right.bytes, &result) // always true (DexcomG7ECC.c:322-335)
        // Safe: fixed 32-byte buffer created above; `G7Scalar.init?` checks only the length.
        return G7Scalar(result)!
    }

    /// Reduces a 32-byte value (a SHA-256 digest) below the group order n.
    static func reduceModN(_ bytes: [UInt8]) -> G7Scalar {
        precondition(bytes.count == G7Scalar.byteCount)
        var result = [UInt8](repeating: 0, count: G7Scalar.byteCount)
        DexcomG7ECCScalarReduceModN(bytes, &result)
        // Safe: fixed 32-byte buffer created above; `G7Scalar.init?` checks only the length.
        return G7Scalar(result)!
    }

    /// Left-pads (or keeps the last 32 bytes of) arbitrary bytes into a big-endian scalar.
    static func scalar(fromBytes bytes: [UInt8]) -> G7Scalar {
        var result = [UInt8](repeating: 0, count: G7Scalar.byteCount)
        DexcomG7ECCScalarFromBytes(bytes, bytes.count, &result)
        // Safe: fixed 32-byte buffer created above (the C function left-pads or truncates into it);
        // `G7Scalar.init?` checks only the length.
        return G7Scalar(result)!
    }
}
