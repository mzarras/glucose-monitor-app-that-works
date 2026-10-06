import GlucoseCore
import GlucoseStore
import WidgetCore
import XCTest
@testable import Sensor

/// Phase 3: the app's own work on a long history, end to end, on the simulator — a production-role
/// GlucoseStore on disk (the app's database code path), the store fetch, GlucoseStats and the
/// view-state mapping exactly as `AppModel` runs them.
///
/// Dataset: a reading every 5 minutes for 181 days (52 128 readings) — the Trends 90 D fetch window
/// once a person has six months of history (90 D, the 90 D it is compared with, 24 h of hypo
/// context). Twice the ~26k of a 90-day store, so the budgets hold for the larger case.
///
/// Each measurement is the median of 7 runs (the machine may be busy with other builds); a failure
/// message names the median, the best and the budget. Budgets are for the Debug build on the
/// simulator; a device Release build is several times faster (docs/statistics.md).
final class NinetyDayPerformanceTests: XCTestCase {
    static let days = 181
    static let runs = 7

    /// Budgets (Debug, simulator), each well inside what a person would notice.
    static let trendsNinetyDaysBudget: TimeInterval = 0.5     // fetch 181 days + compare + AGP + mapping
    static let nowChartBudget: TimeInterval = 0.1             // fetch 48 h + chart + "today so far"
    /// One drag update = one hit test; it must fit easily in a 120 Hz frame (8.3 ms).
    static let scrubPerHitBudget: TimeInterval = 0.002

    nonisolated(unsafe) private static var store: GlucoseStore?
    nonisolated(unsafe) private static var now = Date()

    /// The seeded store, built once for the class (seeding takes a few seconds).
    private func seededStore() async throws -> GlucoseStore {
        if let store = Self.store { return store }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try await GlucoseStore.production(at: directory.appendingPathComponent("readings.sqlite"))
        let now = Date()
        let start = now.addingTimeInterval(-Double(Self.days) * 86_400)
        var batch: [GlucoseReading] = []
        var date = start
        var index = 0
        while date < now {
            // A plausible day: 70–220 with a few lows and highs.
            let mgdl = 140 + Int(70 * sin(Double(index) / 37)) + (index % 997 == 0 ? -80 : 0)
            batch.append(sensorReading(date, .mgdl(min(400, max(40, mgdl)))))
            if batch.count == 4_000 {
                _ = try await store.insert(batch)
                batch.removeAll(keepingCapacity: true)
            }
            date = date.addingTimeInterval(300)
            index += 1
        }
        if !batch.isEmpty { _ = try await store.insert(batch) }
        Self.store = store
        Self.now = now
        return store
    }

    /// Median and best of `runs` timings of `work`.
    private func measure(_ work: () async throws -> Void) async rethrows -> (median: TimeInterval, best: TimeInterval) {
        try await work() // warm-up (caches, first decode), not counted
        var timings: [TimeInterval] = []
        for _ in 0..<Self.runs {
            let start = ContinuousClock.now
            try await work()
            let elapsed = ContinuousClock.now - start
            timings.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        }
        timings.sort()
        return (timings[timings.count / 2], timings[0])
    }

    private func report(_ name: String, _ result: (median: TimeInterval, best: TimeInterval), budget: TimeInterval) {
        let line = String(format: "%@: median %.2f ms, best %.2f ms (budget %.1f ms, %d runs)", name, result.median * 1_000, result.best * 1_000,
                          budget * 1_000, Self.runs)
        print("PERF " + line)
        XCTAssertLessThan(result.median, budget, line + ". If the machine was busy, re-run this suite alone before treating it as a regression.")
    }

    func test_storeHoldsTheDataset() async throws {
        let store = try await seededStore()
        let all = try await store.readings(from: .distantPast, to: .distantFuture)
        XCTAssertGreaterThanOrEqual(all.count, Self.days * 288 - 1)
    }

    /// Trends 90 D: fetch [previous start − 24 h, now) from the store, compare both periods, smooth
    /// the AGP, map to the view state — `AppModel.refreshTrends`'s work.
    func test_trendsNinetyDays() async throws {
        let store = try await seededStore()
        let now = Self.now
        let calendar = Calendar.current
        var state: TrendsViewState?
        let result = try await measure {
            let interval = TrendsMapping.fetchInterval(period: .ninetyDays, now: now, calendar: calendar)
            let readings = try await store.readings(from: interval.start, to: interval.end)
            state = TrendsMapping.make(period: .ninetyDays, readings: readings, now: now, calendar: calendar)
        }
        XCTAssertNotNil(state?.timeInRange)
        XCTAssertNotNil(state?.timeInRangeChange, "the previous 90 days are populated too")
        // For the record: how the time splits between the store fetch and the statistics.
        let interval = TrendsMapping.fetchInterval(period: .ninetyDays, now: now, calendar: calendar)
        var fetched: [GlucoseReading] = []
        let fetch = try await measure { fetched = try await store.readings(from: interval.start, to: interval.end) }
        let readings = fetched
        let compute = try await measure { try Task.checkCancellation(); _ = TrendsMapping.make(period: .ninetyDays, readings: readings, now: now, calendar: calendar) }
        print(String(format: "PERF Trends 90 D split: fetch %d readings median %.1f ms, statistics + AGP + mapping median %.1f ms",
                     readings.count, fetch.median * 1_000, compute.median * 1_000))
        guard case .percentiles(let buckets)? = state?.profile else { return XCTFail("expected an AGP") }
        XCTAssertEqual(buckets.count, 96)
        report("Trends 90 D (\(Self.days) days stored)", result, budget: Self.trendsNinetyDaysBudget)
    }

    /// Now: fetch the chart and "today so far" window and build both — `reloadRecentReadings`.
    func test_nowChartTwentyFourHours() async throws {
        let store = try await seededStore()
        let now = Self.now
        let calendar = Calendar.current
        var recent: NowMapping.Recent?
        let result = try await measure {
            let interval = NowMapping.fetchInterval(now: now, calendar: calendar)
            let readings = try await store.readings(from: interval.start, to: interval.end)
            recent = NowMapping.recent(readings, now: now, calendar: calendar)
        }
        XCTAssertGreaterThanOrEqual(recent?.chartPoints.count ?? 0, 287)
        report("Now chart 24 H + today so far", result, budget: Self.nowChartBudget)
    }

    /// Scrubbing the 24 H chart: one hit test per point of the chart's width (400), each selecting
    /// the nearest real reading (or a gap).
    func test_scrubHitTesting() async throws {
        let store = try await seededStore()
        let now = Self.now
        let readings = try await store.readings(from: now.addingTimeInterval(-86_400), to: now)
        let points = NowMapping.visibleChartPoints(readings.map(ChartPoint.init), now: now)
        var selected = 0
        let result = try await measure {
            try Task.checkCancellation()
            selected = 0
            for step in 0..<400 {
                let date = now.addingTimeInterval(-86_400 + Double(step) * 216)
                if ChartScrub.select(at: date, in: points).reading != nil { selected += 1 }
            }
        }
        XCTAssertEqual(selected, 400, "every position lands on a real reading (no gaps in this dataset)")
        report("Scrub: one hit test on 24 H (median of 400-test runs / 400)", (result.median / 400, result.best / 400), budget: Self.scrubPerHitBudget)
    }
}
