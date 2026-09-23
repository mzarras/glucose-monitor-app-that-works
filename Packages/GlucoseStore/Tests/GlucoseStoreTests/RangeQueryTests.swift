import GlucoseCore
import GRDB
import XCTest
@testable import GlucoseStore

/// S1: queries return stored rows only. Gaps stay gaps; nothing is interpolated or synthesized.
final class RangeQueryTests: XCTestCase {
    private let minute: TimeInterval = 60

    func test_S1_rangeOverAGapReturnsOnlyStoredRows() async throws {
        let store = try GlucoseStore.productionInMemory(now: testClock)
        // Every 5 min from 0 to 30 min, then a gap, then every 5 min from 75 to 120 min.
        let before = stride(from: 0, through: 30, by: 5).map { sensorReading(at: TimeInterval($0) * minute, .mgdl(100 + $0)) }
        let after = stride(from: 75, through: 120, by: 5).map { sensorReading(at: TimeInterval($0) * minute, .mgdl(100 + $0)) }
        _ = try await store.insert(before + after)

        let stored = try await store.readings(from: referenceInstant, to: referenceInstant.addingTimeInterval(125 * minute))

        XCTAssertEqual(stored, before + after)
        XCTAssertEqual(stored.count, 7 + 10)
        let insideGap = stored.filter {
            $0.date > referenceInstant.addingTimeInterval(30 * minute) && $0.date < referenceInstant.addingTimeInterval(75 * minute)
        }
        XCTAssertEqual(insideGap, [], "no reading appears inside the gap")
    }

    func test_S1_rangeInsideAGapIsEmpty() async throws {
        let store = try GlucoseStore.productionInMemory(now: testClock)
        _ = try await store.insert([sensorReading(at: 0), sensorReading(at: 60 * minute)])
        let stored = try await store.readings(
            from: referenceInstant.addingTimeInterval(1),
            to: referenceInstant.addingTimeInterval(60 * minute)
        )
        XCTAssertEqual(stored, [])
    }

    func test_S1_latestLiveReadingIsTheNewestStoredSensorRow() async throws {
        let store = try GlucoseStore.productionInMemory(now: testClock)
        let empty = try await store.latestLiveReading()
        XCTAssertNil(empty, "an empty store has no latest reading")

        let old = sensorReading(at: 0, .mgdl(90))
        let newest = sensorReading(at: 45 * minute, .mgdl(150))
        let backfilled = sensorReading(at: 20 * minute, .mgdl(120), isBackfill: true)
        _ = try await store.insert([old, newest])
        _ = try await store.insert([backfilled])

        let latest = try await store.latestLiveReading()
        XCTAssertEqual(latest, newest, "backfill arriving later does not become the latest")
    }

    /// Equal dates (e.g. an old and a new sensor reporting the same instant) are ordered by the
    /// order they were stored — delivery order — never by id text ("S:10" sorts before "S:9").
    func test_latestLiveReadingOnEqualDatesIsTheReadingStoredLast() async throws {
        let date = referenceInstant.addingTimeInterval(600)
        let nine = GlucoseReading(id: "S:9", date: date, value: .mgdl(110), trendRate: nil, isBackfill: false, source: .sensor, sensorSerial: "S")
        let ten = GlucoseReading(id: "S:10", date: date, value: .mgdl(120), trendRate: nil, isBackfill: false, source: .sensor, sensorSerial: "S")

        for (first, second) in [(nine, ten), (ten, nine)] {
            // Separate calls and one call: both follow the order of delivery.
            let separate = try GlucoseStore.productionInMemory(now: testClock)
            _ = try await separate.insert([first])
            _ = try await separate.insert([second])
            let latestSeparate = try await separate.latestLiveReading()
            XCTAssertEqual(latestSeparate, second)

            let oneCall = try GlucoseStore.productionInMemory(now: testClock)
            _ = try await oneCall.insert([first, second])
            let latestOneCall = try await oneCall.latestLiveReading()
            XCTAssertEqual(latestOneCall, second)
            let range = try await oneCall.readings(from: referenceInstant, to: referenceInstant.addingTimeInterval(3_600))
            XCTAssertEqual(range, [first, second], "range queries use the same tie-break")
        }
    }

    func test_orderedQueriesNeedNoSortStep() async throws {
        let store = try GlucoseStore.productionInMemory(now: testClock)
        let plans = try await store.writer.read { db -> [String] in
            try [
                "SELECT * FROM reading WHERE date >= 0 AND date < 1 ORDER BY date, rowid",
                StoreRole.production.latestLiveReadingSQL,
                "SELECT * FROM reading ORDER BY date, rowid",
            ].map { sql in
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }.joined(separator: " | ")
            }
        }
        XCTAssertTrue(plans[0].contains("reading_on_date"), plans[0])
        XCTAssertTrue(plans[1].contains("reading_sensor_on_date"), plans[1])
        XCTAssertTrue(plans[2].contains("reading_on_date"), plans[2])
        for plan in plans {
            XCTAssertFalse(plan.contains("TEMP B-TREE"), "no sort step: \(plan)")
        }
    }

    func test_rangeIsHalfOpen() async throws {
        let store = try GlucoseStore.productionInMemory(now: testClock)
        let atStart = sensorReading(at: 0)
        let atEnd = sensorReading(at: 300)
        _ = try await store.insert([atStart, atEnd])

        let stored = try await store.readings(from: referenceInstant, to: referenceInstant.addingTimeInterval(300))
        XCTAssertEqual(stored, [atStart])
    }

    func test_rangeWithStartNotBeforeEndIsEmpty() async throws {
        let store = try GlucoseStore.productionInMemory(now: testClock)
        _ = try await store.insert([sensorReading(at: 0)])
        let same = try await store.readings(from: referenceInstant, to: referenceInstant)
        let reversed = try await store.readings(from: referenceInstant.addingTimeInterval(10), to: referenceInstant)
        XCTAssertEqual(same, [])
        XCTAssertEqual(reversed, [])
    }
}
