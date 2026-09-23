import XCTest
@testable import GlucoseCore

final class TrendArrowTests: XCTestCase {
    func test_mapping_boundaries() {
        let cases: [(Double?, TrendArrow)] = [
            (nil, .notComputable), (.nan, .notComputable), (.infinity, .notComputable),
            (0, .flat), (0.99, .flat), (-0.99, .flat),
            (1, .fortyFiveUp), (1.99, .fortyFiveUp), (-1, .fortyFiveDown), (-1.99, .fortyFiveDown),
            (2, .singleUp), (3, .singleUp), (-2, .singleDown), (-3, .singleDown),
            (3.01, .doubleUp), (10, .doubleUp), (-3.01, .doubleDown), (-10, .doubleDown),
        ]
        for (rate, expected) in cases {
            XCTAssertEqual(TrendArrow(rate: rate), expected, "rate \(String(describing: rate))")
        }
    }

    func test_nightscoutDirections_areTheNightscoutNames() {
        XCTAssertEqual(TrendArrow.allCases.map(\.nightscoutDirection), [
            "DoubleUp", "SingleUp", "FortyFiveUp", "Flat", "FortyFiveDown", "SingleDown", "DoubleDown", "NOT COMPUTABLE",
        ])
    }
}
