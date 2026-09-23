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

    /// Runs `body` `runs` times. The assertion uses the fastest run: this machine is shared (other
    /// builds run in parallel) and contention only ever adds time, so the minimum is the best
    /// estimate of the code's own cost. The median and slowest runs are printed alongside it.
    private func timeMilliseconds(runs: Int = 7, _ body: () -> Void) -> (best: Double, median: Double, worst: Double) {
        var samples: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<runs {
            let components = clock.measure(body).components
            samples.append(Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15)
        }
        let sorted = samples.sorted()
        return (sorted[0], sorted[sorted.count / 2], sorted[sorted.count - 1])
    }

    private func report(_ label: String, _ timing: (best: Double, median: Double, worst: Double)) {
        print(String(format: "GlucoseStats %@: best %.2f ms, median %.2f ms, worst %.2f ms (7 runs)",
                     label, timing.best, timing.median, timing.worst))
    }

    func testNinetyDaysOfStatisticsUnderFiftyMillisecondsOnHost() {
        let readings = Fixture.ninetyDays()
        XCTAssertEqual(readings.count, 25_920)
        let interval = DateInterval(start: Fixture.day0, duration: 90 * Fixture.day)

        var stats: PeriodStatistics?
        let timing = timeMilliseconds {
            stats = GlucoseStatistics.compute(readings: readings, interval: interval, options: Fixture.newYorkOptions)
        }
        report("90-day compute", timing)

        XCTAssertEqual(stats?.readingCount, 25_920)
        XCTAssertGreaterThan(stats?.hypoEvents.level2.count ?? 0, 0, "the fixture exercises the hypo detector")
        XCTAssertLessThan(timing.best, Self.hostBudgetMilliseconds)
    }

    func testNinetyDayComparisonUnderOneHundredMillisecondsOnHost() {
        // The Trends "90 D" row with its comparison: two 90-day periods from 180 days of readings.
        let readings = Fixture.ninetyDays() + Fixture.ninetyDays(from: Fixture.day0.addingTimeInterval(90 * Fixture.day))
        let now = Fixture.day0.addingTimeInterval(180 * Fixture.day - 1)

        var comparison: PeriodComparison?
        let timing = timeMilliseconds {
            comparison = GlucoseStatistics.compare(readings: readings, period: .ninetyDays, now: now, options: Fixture.utcOptions)
        }
        report("90-day comparison (2 × 90 days)", timing)

        XCTAssertEqual(comparison?.current.readingCount, 25_920)
        XCTAssertEqual(comparison?.previous.readingCount, 25_920)
        XCTAssertLessThan(timing.best, 2 * Self.hostBudgetMilliseconds)
    }
}
