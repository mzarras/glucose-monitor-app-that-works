import GlucoseCore
import GRDB
import XCTest
@testable import GlucoseStore

/// S4: LOW/HIGH are stored and returned as flags, never as 40/400 or any other number.
final class ValueFlagTests: XCTestCase {
    func test_S4_lowAndHighRoundTripAsFlags() async throws {
        let store = try GlucoseStore.productionInMemory()
        let low = sensorReading(at: 0, .belowRange, trendRate: nil)
        let high = sensorReading(at: 300, .aboveRange, trendRate: nil)
        _ = try await store.insert([low, high])

        let stored = try await store.readings(from: referenceInstant, to: referenceInstant.addingTimeInterval(600))
        XCTAssertEqual(stored.map(\.value), [.belowRange, .aboveRange])
        XCTAssertEqual(stored.map(\.value.numericMgdl), [nil, nil])
    }

    func test_S4_flagsAreStoredWithNoNumber() async throws {
        let store = try GlucoseStore.productionInMemory()
        _ = try await store.insert([
            sensorReading(at: 0, .belowRange, trendRate: nil),
            sensorReading(at: 300, .aboveRange, trendRate: nil),
            importedReading(at: 1_000, .belowRange),
            importedReading(at: 2_000, .aboveRange),
        ])

        let (kinds, numbers) = try await store.writer.read { db -> ([String], [Int?]) in
            let rows = try Row.fetchAll(db, sql: "SELECT valueKind, mgdl FROM reading ORDER BY date")
            return (rows.map { $0["valueKind"] }, rows.map { $0["mgdl"] })
        }
        XCTAssertEqual(kinds, ["belowRange", "aboveRange", "belowRange", "aboveRange"])
        XCTAssertEqual(numbers, [nil, nil, nil, nil])
    }

    func test_S4_boundaryNumbersStayNumbers() async throws {
        let store = try GlucoseStore.productionInMemory()
        _ = try await store.insert([sensorReading(at: 0, .mgdl(40)), sensorReading(at: 300, .mgdl(400))])
        let stored = try await store.readings(from: referenceInstant, to: referenceInstant.addingTimeInterval(600))
        XCTAssertEqual(stored.map(\.value), [.mgdl(40), .mgdl(400)], "a real 40 or 400 is not turned into a flag either")
    }

    func test_S4_schemaRejectsAFlagWithANumber() async throws {
        let store = try GlucoseStore.productionInMemory()
        for (kind, mgdl) in [("belowRange", 40), ("aboveRange", 400)] as [(String, Int)] {
            do {
                try await store.writer.write { db in
                    try db.execute(sql: """
                        INSERT INTO reading (id, date, valueKind, mgdl, trendRate, isBackfill, sourceKind, importOrigin, sensorSerial)
                        VALUES ('x', 0, ?, ?, NULL, 0, 'sensor', NULL, 'S')
                        """, arguments: [kind, mgdl])
                }
                XCTFail("\(kind) with mgdl \(mgdl) must violate the CHECK constraint")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
            }
        }
    }

    func test_S4_schemaRejectsANumericReadingWithoutANumber() async throws {
        let store = try GlucoseStore.productionInMemory()
        do {
            try await store.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO reading (id, date, valueKind, mgdl, trendRate, isBackfill, sourceKind, importOrigin, sensorSerial)
                    VALUES ('x', 0, 'mgdl', NULL, NULL, 0, 'sensor', NULL, 'S')
                    """)
            }
            XCTFail("valueKind 'mgdl' without a number must violate the CHECK constraint")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }
    }

    // MARK: Numeric range (PROGRESS.md D25)

    func test_S1_storeRefusesNumericValueOutsideSensorRange() async throws {
        for value in [39, 401, 0] {
            for implausible in [sensorReading(at: 600, .mgdl(value)), importedReading(at: 3_600, .mgdl(value))] {
                let store = try GlucoseStore.productionInMemory()
                // A valid reading in the same call: the whole batch is refused.
                do {
                    _ = try await store.insert([sensorReading(at: 0), implausible])
                    XCTFail("stored \(implausible.source) value \(value)")
                } catch let error as GlucoseReadingRepositoryError {
                    XCTAssertEqual(error, .implausibleValue(value))
                }
                let count = try await store.summary().readingCount
                XCTAssertEqual(count, 0, "nothing stored for \(implausible.source) value \(value)")
            }
        }
        #if DEBUG
        let replay = try GlucoseStore.replay()
        do {
            _ = try await replay.insert([replayReading(at: 0, .mgdl(401))])
            XCTFail("replay store stored 401")
        } catch let error as GlucoseReadingRepositoryError {
            XCTAssertEqual(error, .implausibleValue(401))
        }
        #endif
    }

    func test_S1_schemaRejectsNumericValueOutsideSensorRange() async throws {
        let store = try GlucoseStore.productionInMemory()
        for value in [39, 401, 0, -5, 4_095] {
            do {
                try await store.writer.write { db in
                    try db.execute(sql: """
                        INSERT INTO reading (id, date, valueKind, mgdl, trendRate, isBackfill, sourceKind, importOrigin, sensorSerial)
                        VALUES ('x', 0, 'mgdl', ?, NULL, 0, 'sensor', NULL, 'S')
                        """, arguments: [value])
                }
                XCTFail("schema accepted mgdl \(value)")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
            }
        }
    }
}

