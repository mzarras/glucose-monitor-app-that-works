import GlucoseCore
import XCTest
@testable import GlucoseStore

/// `changes()` yields once after every committed write that changed rows, and never otherwise.
/// Counting technique: yields are buffered synchronously on commit, and releasing the store
/// finishes every stream, so iterating after release counts exactly what was yielded.
final class ChangesTests: XCTestCase {
    private func count(_ stream: AsyncStream<Void>) async -> Int {
        var count = 0
        for await _ in stream { count += 1 }
        return count
    }

    func test_yieldsOncePerCommittedWriteThatChangedRows() async throws {
        var store: GlucoseStore? = try GlucoseStore.productionInMemory(now: { referenceInstant.addingTimeInterval(200 * 86_400) })
        let stream = store!.changes()

        _ = try await store!.insert([sensorReading(at: 0), sensorReading(at: 300)]) // 1: new rows (one transaction)
        _ = try await store!.insert([sensorReading(at: 0)])                          // no change: duplicate id
        _ = try await store!.insert([])                                              // no write at all
        _ = try await store!.insert([sensorReading(at: 600)])                        // 2: new row
        _ = try await store!.insert([importedReading(at: 60)])                       // no change: skipped (overlaps sensor)
        _ = try await store!.purge(keeping: .forever)                                // no change
        _ = try await store!.purge(keeping: .days90)                                 // 3: deletes all three
        _ = try await store!.purge(keeping: .days90)                                 // no change: nothing left

        store = nil
        let yields = await count(stream)
        XCTAssertEqual(yields, 3)
    }

    func test_eachCallReturnsAnIndependentStream() async throws {
        var store: GlucoseStore? = try GlucoseStore.productionInMemory()
        let first = store!.changes()
        let second = store!.changes()
        _ = try await store!.insert([sensorReading(at: 0)])
        _ = try await store!.insert([sensorReading(at: 300)])
        store = nil
        let firstCount = await count(first)
        let secondCount = await count(second)
        XCTAssertEqual(firstCount, 2)
        XCTAssertEqual(secondCount, 2)
    }

    func test_rolledBackWriteDoesNotYield() async throws {
        struct Abort: Error {}
        var store: GlucoseStore? = try GlucoseStore.productionInMemory()
        let stream = store!.changes()
        do {
            try await store!.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO reading (id, date, valueKind, mgdl, trendRate, isBackfill, sourceKind, importOrigin, sensorSerial)
                    VALUES ('x', 0, 'mgdl', 100, NULL, 0, 'sensor', NULL, 'S')
                    """)
                throw Abort()
            }
            XCTFail("expected the write to throw")
        } catch is Abort {}
        let count = try await store!.summary().readingCount
        XCTAssertEqual(count, 0, "the insert was rolled back")
        store = nil
        let yields = await self.count(stream)
        XCTAssertEqual(yields, 0)
    }

    func test_cancelledConsumerIsRemoved() async throws {
        let store = try GlucoseStore.productionInMemory()
        let task = Task {
            for await _ in store.changes() {}
        }
        task.cancel()
        await task.value
        // Nothing to assert beyond "does not crash or leak into later broadcasts".
        _ = try await store.insert([sensorReading(at: 0)])
    }
}
