import XCTest
import GlucoseCore
@testable import GlucoseStats

/// Display-only smoothing of the AGP chart. S1 properties are in SafetyTests.
final class AGPDisplaySmoothingTests: XCTestCase {

    /// A profile whose every percentile in bucket `i` is `values[i]` (nil = empty bucket).
    private func profile(_ values: [Int: GlucoseValue]) -> AGPProfile {
        AGPProfile(buckets: (0..<96).map { index in
            let value = values[index]
            return AGPBucket(
                startMinuteOfDay: index * 15, readingCount: value == nil ? 0 : 1,
                p5: value, p25: value, p50: value, p75: value, p95: value
            )
        })
    }

    func testOneTwoOneWeightedAverageOfNeighbours() {
        // Buckets 9, 10, 11 = 100, 110, 130 → bucket 10 = (1×100 + 2×110 + 1×130) / 4 = 450 / 4 = 112.5.
        let smoothed = AGPDisplaySmoothing.smoothedForDisplay(profile([9: .mgdl(100), 10: .mgdl(110), 11: .mgdl(130)]))
        XCTAssertEqual(smoothed.count, 96)
        XCTAssertEqual(smoothed[10].p50, .mgdl(112.5))
        XCTAssertEqual(smoothed[10].p5, .mgdl(112.5))
        XCTAssertEqual(smoothed[10].startMinuteOfDay, 150)
    }

    func testMissingNeighbourIsLeftOutAndWeightsRenormalised() {
        // Bucket 9 empty: bucket 10 = (2×110 + 1×130) / 3 = 350 / 3 = 116.666…
        // Bucket 11 (neighbours 110 and empty 12) = (1×110 + 2×130) / 3 = 370 / 3 = 123.333…
        let smoothed = AGPDisplaySmoothing.smoothedForDisplay(profile([10: .mgdl(110), 11: .mgdl(130)]))
        XCTAssertEqual(smoothed[10].p50, .mgdl(350.0 / 3.0))
        XCTAssertEqual(smoothed[11].p50, .mgdl(370.0 / 3.0))
    }

    func testFlagNeighbourIsLeftOutNotTreatedAsANumber() {
        // Bucket 9 is LOW. It is skipped (never read as 40): bucket 10 = (2×110 + 130) / 3 = 116.666…
        let smoothed = AGPDisplaySmoothing.smoothedForDisplay(profile([9: .belowRange, 10: .mgdl(110), 11: .mgdl(130)]))
        XCTAssertEqual(smoothed[10].p50, .mgdl(350.0 / 3.0))
        XCTAssertEqual(smoothed[9].p50, .belowRange)
    }

    func testFlagBucketsStayFlags() {
        let smoothed = AGPDisplaySmoothing.smoothedForDisplay(profile([20: .belowRange, 21: .mgdl(100), 22: .aboveRange]))
        XCTAssertEqual(smoothed[20].p50, .belowRange)
        XCTAssertEqual(smoothed[22].p95, .aboveRange)
        // Bucket 21 with both neighbours flagged: only its own value, 2×100 / 2 = 100.
        XCTAssertEqual(smoothed[21].p50, .mgdl(100))
    }

    func testWrapsAroundMidnight() {
        // Bucket 0's neighbours are 95 (23:45) and 1: (1×100 + 2×100 + 1×160) / 4 = 460 / 4 = 115.
        let smoothed = AGPDisplaySmoothing.smoothedForDisplay(profile([95: .mgdl(100), 0: .mgdl(100), 1: .mgdl(160)]))
        XCTAssertEqual(smoothed[0].p50, .mgdl(115))
        // Bucket 95's neighbours are 94 (empty) and 0: (2×100 + 1×100) / 3 = 100.
        XCTAssertEqual(smoothed[95].p50, .mgdl(100))
    }

    func testEmptyProfileStaysEmpty() {
        let smoothed = AGPDisplaySmoothing.smoothedForDisplay(AGPProfile(buckets: []))
        XCTAssertTrue(smoothed.isEmpty)
    }
}
