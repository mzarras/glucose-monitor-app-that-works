import XCTest
import GlucoseCore
@testable import GlucoseStats

final class RangeDistributionTests: XCTestCase {

    private func distribution(_ values: [GlucoseValue]) -> RangeDistribution {
        RangeDistribution(Fixture.period(Fixture.series(values), Fixture.interval(minutes: 1_440)))
    }

    func testBoundaryValuesFallInConsensusBins() {
        // 10 readings, n = 10:
        //   < 54        53                   1 → 1/10 = 10 %
        //   54–69       54, 69               2 → 20 %
        //   70–180      70, 140, 141, 180    4 → 40 %
        //   181–250     181, 250             2 → 20 %
        //   > 250       251                  1 → 10 %
        //   tight 70–140: 70, 140            2 → 20 %
        //   below 70 = 1 + 2 = 3 → 30 %;  above 180 = 2 + 1 = 3 → 30 %
        let result = distribution(Fixture.mg(53, 54, 69, 70, 140, 141, 180, 181, 250, 251))

        XCTAssertEqual(result.readingCount, 10)
        XCTAssertEqual(result.veryLow, RangeShare(count: 1, percent: 10))
        XCTAssertEqual(result.low, RangeShare(count: 2, percent: 20))
        XCTAssertEqual(result.inRange, RangeShare(count: 4, percent: 40))
        XCTAssertEqual(result.high, RangeShare(count: 2, percent: 20))
        XCTAssertEqual(result.veryHigh, RangeShare(count: 1, percent: 10))
        XCTAssertEqual(result.tightRange, RangeShare(count: 2, percent: 20))
        XCTAssertEqual(result.below70, RangeShare(count: 3, percent: 30))
        XCTAssertEqual(result.above180, RangeShare(count: 3, percent: 30))
    }

    func testDenominatorIncludesLowAndHighFlags() {
        // [LOW, 100, 120, HIGH]: n = 4. In range 2/4 = 50 %; LOW → < 54 (25 %); HIGH → > 250 (25 %).
        let result = distribution([.belowRange, .mgdl(100), .mgdl(120), .aboveRange])

        XCTAssertEqual(result.readingCount, 4)
        XCTAssertEqual(result.inRange, RangeShare(count: 2, percent: 50))
        XCTAssertEqual(result.veryLow, RangeShare(count: 1, percent: 25))
        XCTAssertEqual(result.veryHigh, RangeShare(count: 1, percent: 25))
        XCTAssertEqual(result.tightRange, RangeShare(count: 2, percent: 50))
    }

    func testPercentagesAreUnroundedFractionsTimesHundred() {
        // [100, 100, 200]: in range 2/3 × 100 = 66.666… %, high 1/3 × 100 = 33.333… %.
        let result = distribution(Fixture.mg(100, 100, 200))
        XCTAssertEqual(result.inRange.percent!, 200.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(result.high.percent!, 100.0 / 3.0, accuracy: 1e-12)
    }

    func testEmptyInputHasCountsButNoPercentages() {
        let result = distribution([])
        XCTAssertEqual(result.readingCount, 0)
        for band in GlucoseBand.allCases {
            XCTAssertEqual(result.share(of: band), RangeShare(count: 0, percent: nil))
        }
        XCTAssertEqual(result.tightRange, RangeShare(count: 0, percent: nil))
        XCTAssertEqual(result.below70, RangeShare(count: 0, percent: nil))
        XCTAssertEqual(result.above180, RangeShare(count: 0, percent: nil))
    }

    func testAllHighIsHundredPercentVeryHigh() {
        let result = distribution([.aboveRange, .aboveRange, .aboveRange])
        XCTAssertEqual(result.veryHigh, RangeShare(count: 3, percent: 100))
        XCTAssertEqual(result.above180, RangeShare(count: 3, percent: 100))
        XCTAssertEqual(result.inRange, RangeShare(count: 0, percent: 0))
        XCTAssertEqual(result.tightRange, RangeShare(count: 0, percent: 0))
    }

    func testShareOfBandMatchesNamedFields() {
        let result = distribution(Fixture.mg(40, 60, 100, 200, 300))
        XCTAssertEqual(result.share(of: .veryLow), result.veryLow)
        XCTAssertEqual(result.share(of: .low), result.low)
        XCTAssertEqual(result.share(of: .inRange), result.inRange)
        XCTAssertEqual(result.share(of: .high), result.high)
        XCTAssertEqual(result.share(of: .veryHigh), result.veryHigh)
        // Each 1/5 = 20 %.
        XCTAssertEqual(result.low, RangeShare(count: 1, percent: 20))
    }
}
