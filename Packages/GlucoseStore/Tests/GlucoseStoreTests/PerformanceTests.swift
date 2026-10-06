import GlucoseCore
import XCTest
@testable import GlucoseStore

/// HANDOFF §4.4: fast range queries over 90+ days of 5-minute data, with 2 years stored.
/// Numbers are printed and recorded in docs/storage.md. Bounds are deliberately loose so a debug
/// build on a slow CI host still passes; the printed numbers are what matters.
final class PerformanceTests: XCTestCase {
    private let day: TimeInterval = 86_400

    func test_twoYearsOfFiveMinuteDataThenQuery90Days() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await GlucoseStore.production(at: directory.appendingPathComponent("perf.sqlite"), now: testClock)

        // 730 days × 288 readings/day = 210 240 rows: the first 720 days as imported history in
        // 7-day batches (the Nightscout import pages in 7-day windows, HANDOFF §4.5 step 1), the
        // last 10 days as sensor readings in 1-day batches (backfill-sized). Values cycle through
        // the whole range, including LOW/HIGH flags.
        let perDay = 288
        let totalDays = 730
        let importedDays = 720
        func value(_ index: Int) -> GlucoseValue {
            switch index % 400 {
            case 0: return .belowRange
            case 1: return .aboveRange
            default: return .mgdl(40 + index % 361)
            }
        }
        let clock = ContinuousClock()
        var inserted = 0
        let insertDuration = try await clock.measure {
            for week in stride(from: 0, to: importedDays, by: 7) {
                let batch = (week * perDay ..< min(week + 7, importedDays) * perDay).map { index in
                    importedReading(at: TimeInterval(index) * 300, value(index))
                }
                inserted += try await store.insert(batch).count
            }
            for day in importedDays ..< totalDays {
                let batch = (day * perDay ..< (day + 1) * perDay).map { index in
                    sensorReading(at: TimeInterval(index) * 300, value(index))
                }
                inserted += try await store.insert(batch).count
            }
        }
        XCTAssertEqual(inserted, totalDays * perDay)

        let end = referenceInstant.addingTimeInterval(TimeInterval(totalDays) * day)
        let start = end.addingTimeInterval(-90 * day)
        var ninetyDays: [GlucoseReading] = []
        let queryDuration = try await clock.measure {
            ninetyDays = try await store.readings(from: start, to: end)
        }
        XCTAssertEqual(ninetyDays.count, 90 * perDay)

        var latest: GlucoseReading?
        let latestColdDuration = try await clock.measure {
            latest = try await store.latestLiveReading()
        }
        XCTAssertEqual(latest?.date, end.addingTimeInterval(-300))
        // Second call: the reader connection is open and the schema cached, as in the running app.
        let latestDuration = try await clock.measure {
            latest = try await store.latestLiveReading()
        }

        var summary: StoreSummary?
        let summaryDuration = try await clock.measure {
            summary = try await store.summary()
        }

        let csv = directory.appendingPathComponent("perf.csv")
        let exportDuration = try await clock.measure {
            _ = try await store.exportCSV(to: csv)
        }
        let csvBytes = (try FileManager.default.attributesOfItem(atPath: csv.path)[.size] as? NSNumber)?.int64Value ?? 0

        print("""
            PERF GlucoseStore: insert \(inserted) rows in 7-day batches: \(insertDuration)
            PERF GlucoseStore: readings(from:to:) 90 days (\(ninetyDays.count) rows): \(queryDuration)
            PERF GlucoseStore: latestLiveReading(): first call \(latestColdDuration), warm \(latestDuration)
            PERF GlucoseStore: summary(): \(summaryDuration), file size \(summary?.fileSizeBytes ?? -1) bytes
            PERF GlucoseStore: exportCSV all rows: \(exportDuration), \(csvBytes) bytes
            """)

        XCTAssertLessThan(queryDuration, .seconds(1), "90-day range query")
        XCTAssertLessThan(latestDuration, .milliseconds(50), "latestLiveReading uses the partial index")
    }
}
