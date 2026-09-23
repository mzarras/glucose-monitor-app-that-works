import XCTest
import GlucoseCore
@testable import GlucoseStats

/// HANDOFF §6: all statistics for 90 days must compute in < 100 ms on device-class hardware.
/// The host Mac is faster than a phone, so the host assertion is stricter (< 50 ms). The measured
/// numbers are printed so they can be recorded in docs/statistics.md.
///
/// What is asserted: the **thread CPU time** of the timed call (`CLOCK_THREAD_CPUTIME_ID`), best of
/// 7 runs. Wall-clock time also counts time the thread spends waiting for a core, and this project
/// runs many builds and test suites in parallel on one machine, so wall clock made the gate flaky
/// (one run measured 77–95 ms wall for ~21 ms of work). CPU time counts only the work. Wall clock is
/// still printed alongside.
///
/// `swift test` builds without optimisation (and `scripts/check.sh` adds coverage instrumentation),
/// so these timings are pessimistic compared with the app's Release build.
final class PerformanceTests: XCTestCase {

    private static let hostBudgetMilliseconds = 50.0

    private struct Timing {
        var cpuBest: Double
        var cpuMedian: Double
        var wallBest: Double
        var wallMedian: Double
    }

    /// CPU time consumed by the calling thread so far, in milliseconds.
    private func threadCPUMilliseconds() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) * 1_000 + Double(time.tv_nsec) / 1_000_000
    }

    private func timed(runs: Int = 7, _ body: () -> Void) -> Timing {
        var cpu: [Double] = []
        var wall: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<runs {
            let cpuStart = threadCPUMilliseconds()
            let wallStart = clock.now
            body()
            let wallElapsed = (clock.now - wallStart).components
            cpu.append(threadCPUMilliseconds() - cpuStart)
            wall.append(Double(wallElapsed.seconds) * 1_000 + Double(wallElapsed.attoseconds) / 1e15)
        }
        cpu.sort()
        wall.sort()
        return Timing(cpuBest: cpu[0], cpuMedian: cpu[runs / 2], wallBest: wall[0], wallMedian: wall[runs / 2])
    }

    private func report(_ label: String, _ timing: Timing) {
        print(String(format: "GlucoseStats %@: CPU best %.2f ms, median %.2f ms; wall best %.2f ms, median %.2f ms (7 runs)",
                     label, timing.cpuBest, timing.cpuMedian, timing.wallBest, timing.wallMedian))
    }

    func testNinetyDaysOfStatisticsUnderFiftyMillisecondsOnHost() {
        let readings = Fixture.ninetyDays()
        XCTAssertEqual(readings.count, 25_920)
        let interval = DateInterval(start: Fixture.day0, duration: 90 * Fixture.day)

        var stats: PeriodStatistics?
        let timing = timed {
            stats = GlucoseStatistics.compute(readings: readings, interval: interval, options: Fixture.newYorkOptions)
        }
        report("90-day compute", timing)

        XCTAssertEqual(stats?.readingCount, 25_920)
        XCTAssertGreaterThan(stats?.hypoEvents.level2.count ?? 0, 0, "the fixture exercises the hypo detector")
        XCTAssertLessThan(timing.cpuBest, Self.hostBudgetMilliseconds)
    }

    func testNinetyDayComparisonUnderOneHundredMillisecondsOnHost() {
        // The Trends "90 D" row with its comparison: two 90-day periods from 180 days of readings.
        let readings = Fixture.ninetyDays() + Fixture.ninetyDays(from: Fixture.day0.addingTimeInterval(90 * Fixture.day))
        let now = Fixture.day0.addingTimeInterval(180 * Fixture.day - 1)

        var comparison: PeriodComparison?
        let timing = timed {
            comparison = GlucoseStatistics.compare(readings: readings, period: .ninetyDays, now: now, options: Fixture.utcOptions)
        }
        report("90-day comparison (2 × 90 days)", timing)

        XCTAssertEqual(comparison?.current.readingCount, 25_920)
        XCTAssertEqual(comparison?.previous.readingCount, 25_920)
        XCTAssertLessThan(timing.cpuBest, 2 * Self.hostBudgetMilliseconds)
    }
}
