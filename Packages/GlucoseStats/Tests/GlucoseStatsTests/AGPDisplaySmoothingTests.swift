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

    func testNeighbourWithAnyFlagIsDroppedForAllLinesSoLinesCannotCross() {
        // Reviewer probe. Bucket 9 = [LOW, LOW, 60, 60, 60]; bucket 10 = [90, 100, 101, 110, 120];
        // bucket 11 = [101 ×5].
        //   Per-line neighbour choice would give bucket 10 p25 = (2×100 + 101) / 3 = 100.33 but
        //   p50 = (60 + 2×101 + 101) / 4 = 90.75: p25 above p50, crossing lines.
        //   Bucket 9 holds a flag, so it is dropped for all five lines of bucket 10:
        //   p5 (180+101)/3 = 93.67, p25 (200+101)/3 = 100.33, p50 (202+101)/3 = 101, p75 (220+101)/3 = 107,
        //   p95 (240+101)/3 = 113.67.
        let buckets = (0..<96).map { index -> AGPBucket in
            switch index {
            case 9: return AGPBucket(startMinuteOfDay: 135, readingCount: 5, p5: .belowRange, p25: .belowRange, p50: .mgdl(60), p75: .mgdl(60), p95: .mgdl(60))
            case 10: return AGPBucket(startMinuteOfDay: 150, readingCount: 5, p5: .mgdl(90), p25: .mgdl(100), p50: .mgdl(101), p75: .mgdl(110), p95: .mgdl(120))
            case 11: return AGPBucket(startMinuteOfDay: 165, readingCount: 5, p5: .mgdl(101), p25: .mgdl(101), p50: .mgdl(101), p75: .mgdl(101), p95: .mgdl(101))
            default: return AGPBucket(startMinuteOfDay: index * 15, readingCount: 0, p5: nil, p25: nil, p50: nil, p75: nil, p95: nil)
            }
        }
        let smoothed = AGPDisplaySmoothing.smoothedForDisplay(AGPProfile(buckets: buckets))

        XCTAssertEqual(smoothed[10], AGPDisplayBucket(
            startMinuteOfDay: 150,
            p5: .mgdl(281.0 / 3.0), p25: .mgdl(301.0 / 3.0), p50: .mgdl(101), p75: .mgdl(107), p95: .mgdl(341.0 / 3.0)
        ))
        // Bucket 9 keeps its flags; its numeric lines use bucket 10 (bucket 8 is empty):
        //   p50 (2×60 + 101)/3 = 73.67, p75 (120 + 110)/3 = 76.67, p95 (120 + 120)/3 = 80.
        XCTAssertEqual(smoothed[9], AGPDisplayBucket(
            startMinuteOfDay: 135,
            p5: .belowRange, p25: .belowRange, p50: .mgdl(221.0 / 3.0), p75: .mgdl(230.0 / 3.0), p95: .mgdl(80)
        ))
    }

    func testSmoothedLinesNeverCrossOnNinetyDaysOfData() {
        // Every bucket of the 90-day fixture (with LOW/HIGH flags): p5 ≤ p25 ≤ p50 ≤ p75 ≤ p95 after
        // smoothing, ordering LOW below and HIGH above every number.
        func rank(_ value: AGPDisplayValue) -> Double {
            switch value {
            case .belowRange: return -Double.infinity
            case .aboveRange: return Double.infinity
            case .mgdl(let mgdl): return mgdl
            }
        }
        let period = Fixture.period(Fixture.ninetyDays(), DateInterval(start: Fixture.day0, duration: 90 * Fixture.day))
        for bucket in AGPDisplaySmoothing.smoothedForDisplay(AGPProfile(period)) {
            let lines = [bucket.p5, bucket.p25, bucket.p50, bucket.p75, bucket.p95].map { rank($0!) }
            XCTAssertEqual(lines, lines.sorted(), "bucket at minute \(bucket.startMinuteOfDay)")
        }
    }

    func testEmptyProfileStaysEmpty() {
        let smoothed = AGPDisplaySmoothing.smoothedForDisplay(AGPProfile(buckets: []))
        XCTAssertTrue(smoothed.isEmpty)
    }
}
