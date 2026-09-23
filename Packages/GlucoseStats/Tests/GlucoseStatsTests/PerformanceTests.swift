import XCTest
import GlucoseCore
@testable import GlucoseStats

/// HANDOFF §6: all statistics for 90 days must compute in < 100 ms on device-class hardware.
/// The host Mac is faster than a phone, so the host assertion is stricter (< 50 ms). The measured
/// numbers are printed so they can be recorded in docs/statistics.md.
///
/// `swift test` builds without optimisation (and `scripts/check.sh` adds coverage instrumentation),
/// so these timings are pessimistic compared with the app's Release build.
final class PerformanceTests: XCTestCase {

    private static let hostBudgetMilliseconds = 50.0

    private func medianMilliseconds(runs: Int = 5, _ body: () -> Void) -> (median: Double, all: [Double]) {
        var samples: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<runs {
            let elapsed = clock.measure(body)
            let components = elapsed.components
            samples.append(Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15)
        }
        let sorted = samples.sorted()
        return (sorted[sorted.count / 2], samples)
    }

    func testNinetyDaysOfStatisticsUnderFiftyMillisecondsOnHost() {
        let readings = Fixture.ninetyDays()
        XCTAssertEqual(readings.count, 25_920)
        let interval = DateInterval(start: Fixture.day0, duration: 90 * Fixture.day)

        var stats: PeriodStatistics?
        let timing = medianMilliseconds {
            stats = GlucoseStatistics.compute(readings: readings, interval: interval, options: Fixture.newYorkOptions)
        }
        print(String(format: "GlucoseStats 90-day compute: median %.2f ms over 5 runs %@", timing.median,
                     timing.all.map { String(format: "%.2f", $0) }.description))

        XCTAssertEqual(stats?.readingCount, 25_920)
        XCTAssertGreaterThan(stats?.hypoEvents.level2.count ?? 0, 0, "the fixture exercises the hypo detector")
        XCTAssertLessThan(timing.median, Self.hostBudgetMilliseconds)
    }

    func testNinetyDayComparisonUnderOneHundredMillisecondsOnHost() {
        // The Trends "90 D" row with its comparison: two 90-day periods from 180 days of readings.
        let readings = Fixture.ninetyDays() + Fixture.ninetyDays(from: Fixture.day0.addingTimeInterval(90 * Fixture.day))
        let now = Fixture.day0.addingTimeInterval(180 * Fixture.day - 1)

        var comparison: PeriodComparison?
        let timing = medianMilliseconds {
            comparison = GlucoseStatistics.compare(readings: readings, period: .ninetyDays, now: now, options: Fixture.utcOptions)
        }
        print(String(format: "GlucoseStats 90-day comparison (2 × 90 days): median %.2f ms over 5 runs %@", timing.median,
                     timing.all.map { String(format: "%.2f", $0) }.description))

        XCTAssertEqual(comparison?.current.readingCount, 25_920)
        XCTAssertEqual(comparison?.previous.readingCount, 25_920)
        XCTAssertLessThan(timing.median, 2 * Self.hostBudgetMilliseconds)
    }
}
