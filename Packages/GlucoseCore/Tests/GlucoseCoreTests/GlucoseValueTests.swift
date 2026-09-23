import XCTest
@testable import GlucoseCore

final class GlucoseValueTests: XCTestCase {
    func test_S4_lowAndHighFlagsHaveNoNumericValue() {
        XCTAssertNil(GlucoseValue.belowRange.numericMgdl)
        XCTAssertNil(GlucoseValue.aboveRange.numericMgdl)
        XCTAssertEqual(GlucoseValue.mgdl(40).numericMgdl, 40)
    }

    func test_S4_flagsLandInTheExtremeBins() {
        XCTAssertEqual(GlucoseValue.belowRange.band, .veryLow)
        XCTAssertEqual(GlucoseValue.aboveRange.band, .veryHigh)
    }

    func test_bandBoundaries() {
        let cases: [(Int, GlucoseBand)] = [
            (40, .veryLow), (53, .veryLow), (54, .low), (69, .low), (70, .inRange), (180, .inRange),
            (181, .high), (250, .high), (251, .veryHigh), (400, .veryHigh),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(GlucoseValue.mgdl(value).band, expected, "\(value)")
        }
    }
}
