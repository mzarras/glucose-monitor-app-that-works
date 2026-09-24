// Original to Sensor (no ported code).

import XCTest
@testable import G7Kit

final class G7BytesTests: XCTestCase {
    func test_littleEndianReadersAndWriters() {
        let bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        XCTAssertEqual(G7Bytes.uint16(bytes, at: 0), 0x0201)
        XCTAssertEqual(G7Bytes.uint24(bytes, at: 0), 0x030201)
        XCTAssertEqual(G7Bytes.uint32(bytes, at: 0), 0x04030201)
        XCTAssertEqual(G7Bytes.littleEndian(UInt16(0x0201)), [0x01, 0x02])
        XCTAssertEqual(G7Bytes.littleEndian(UInt32(0x04030201)), bytes)
        XCTAssertEqual(G7Bytes.bigEndian(UInt32(0x04030201)), [0x04, 0x03, 0x02, 0x01])
    }
}
