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
}
