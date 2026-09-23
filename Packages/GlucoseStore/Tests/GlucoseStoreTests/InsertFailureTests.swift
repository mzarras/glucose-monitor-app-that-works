import GlucoseCore
import GRDB
import os
import XCTest
@testable import GlucoseStore

/// `insert` failing inside its transaction (after some rows of the batch were already written)
/// rolls everything back: nothing stored, nothing returned, no `changes()` yield.
final class InsertFailureTests: XCTestCase {
    /// Three sensor readings; the trigger below fires on the second, after the first is written.
    private let batch = [sensorReading(at: 0), sensorReading(at: 300), sensorReading(at: 600)]

    private func assertNothingStoredAndNoYield(_ store: inout GlucoseStore?, _ changes: AsyncStream<Void>) async throws {
        let count = try await store!.summary().readingCount
        XCTAssertEqual(count, 0, "the rows written before the failure were rolled back")
        store = nil
        var yields = 0
        for await _ in changes { yields += 1 }
        XCTAssertEqual(yields, 0, "a rolled-back write does not yield")
    }

    func test_S5_insertFailingMidBatchWithASQLErrorStoresNothing() async throws {
        var store: GlucoseStore? = try GlucoseStore.productionInMemory(now: testClock)
        let changes = store!.changes()
        let failingID = batch[1].id
        try await store!.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER fail_mid_batch BEFORE INSERT ON main.reading
                WHEN NEW.id = '\(failingID)'
                BEGIN SELECT RAISE(ABORT, 'injected failure'); END
                """)
        }

        do {
            _ = try await store!.insert(batch)
            XCTFail("expected the injected SQL error")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT, "RAISE(ABORT) reports SQLITE_CONSTRAINT")
            XCTAssertEqual(error.message, "injected failure")
        }
        try await assertNothingStoredAndNoYield(&store, changes)
    }

    func test_S5_insertCancelledMidBatchStoresNothing() async throws {
        var store: GlucoseStore? = try GlucoseStore.productionInMemory(now: testClock)
        let changes = store!.changes()
        let taskBox = OSAllocatedUnfairLock<Task<[GlucoseReading], any Error>?>(initialState: nil)
        let cancelledAtID = batch[0].id
        // A SQL function called by a trigger after the first row of the batch is written: it
        // cancels the inserting task, which makes GRDB interrupt the connection mid-transaction.
        try await store!.writer.write { db in
            db.add(function: DatabaseFunction("cancelInsertingTask", argumentCount: 0) { _ in
                taskBox.withLock { $0 }?.cancel()
                return nil
            })
            try db.execute(sql: """
                CREATE TEMP TRIGGER cancel_mid_batch AFTER INSERT ON main.reading
                WHEN NEW.id = '\(cancelledAtID)'
                BEGIN SELECT cancelInsertingTask(); END
                """)
        }

        let (start, startSignal) = AsyncStream.makeStream(of: Void.self)
        let batch = self.batch
        let inserting = Task { [store] in
            for await _ in start { break }          // wait until the handle is in the box
            return try await store!.insert(batch)
        }
        taskBox.withLock { $0 = inserting }
        startSignal.yield()

        do {
            let returned = try await inserting.value
            XCTFail("expected cancellation, got \(returned.count) readings")
        } catch {
            // Only the trigger's SQL function cancels the task, and it runs after the first row of
            // the batch is written, so this error proves the cancellation happened mid-batch.
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        taskBox.withLock { $0 = nil }
        try await assertNothingStoredAndNoYield(&store, changes)
    }
}
