import GlucoseCore
import GRDB
import XCTest
@testable import GlucoseStore

/// S6: the source (and import origin) survives storage exactly, so downstream gates can refuse
/// anything that is not `.sensor`. Imported rows must never come back as `.sensor`.
final class SourceTests: XCTestCase {
    private func reading(_ index: Int, source: ReadingSource) -> GlucoseReading {
        GlucoseReading(
            id: "source-test:\(index)", date: referenceInstant.addingTimeInterval(TimeInterval(index) * 600),
            value: .mgdl(100 + index), trendRate: nil, isBackfill: false, source: source, sensorSerial: "S"
        )
    }

    func test_S6_productionSourcesAndImportOriginsRoundTripExactly() async throws {
        let store = try GlucoseStore.productionInMemory()
        let sources: [ReadingSource] = [.sensor, .imported(.nightscout), .imported(.clarityCSV)]
        let readings = sources.enumerated().map { reading($0.offset, source: $0.element) }
        _ = try await store.insert(readings)

        let stored = try await store.readings(from: referenceInstant, to: referenceInstant.addingTimeInterval(86_400))
        XCTAssertEqual(stored.map(\.source), sources)
        XCTAssertEqual(stored, readings)
    }

    #if DEBUG
    func test_S6_replaySourcesRoundTripExactlyInTheReplayStore() async throws {
        let store = try GlucoseStore.replay()
        let readings = [reading(0, source: .replay), reading(1, source: .mock)]
        _ = try await store.insert(readings)

        let stored = try await store.readings(from: referenceInstant, to: referenceInstant.addingTimeInterval(86_400))
        XCTAssertEqual(stored.map(\.source), [.replay, .mock])
        XCTAssertEqual(stored, readings)
    }
    #endif

    func test_S6_importedRowsNeverComeBackAsSensor() async throws {
        let store = try GlucoseStore.productionInMemory()
        let imported = (0..<20).map { index in
            importedReading(at: TimeInterval(index) * 300, origin: index.isMultiple(of: 2) ? .nightscout : .clarityCSV)
        }
        _ = try await store.insert(imported)

        let stored = try await store.readings(from: referenceInstant, to: referenceInstant.addingTimeInterval(86_400))
        XCTAssertEqual(stored.count, 20)
        for reading in stored {
            XCTAssertFalse(reading.source.isLiveSensor, "\(reading.id) came back as \(reading.source)")
            XCTAssertNotEqual(reading.source, .sensor)
        }
        let latest = try await store.latestLiveReading()
        XCTAssertNil(latest, "imported history is never the current reading")

        let rawSourceKinds = try await store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT sourceKind FROM reading")
        }
        XCTAssertEqual(rawSourceKinds, ["imported"])
    }

    func test_S6_latestLiveReadingIgnoresImported() async throws {
        let store = try GlucoseStore.productionInMemory()
        let lastSensor = sensorReading(at: 0, .mgdl(140))
        // Imported history newer than the last sensor reading (e.g. an import run after the sensor
        // stopped, of readings another device uploaded to Nightscout).
        let newerImported = (1...50).map { importedReading(at: TimeInterval($0) * 300, .mgdl(60)) }
        _ = try await store.insert([lastSensor] + newerImported)

        let latest = try await store.latestLiveReading()
        XCTAssertEqual(latest, lastSensor)
    }

    func test_latestLiveReadingUsesThePartialIndex() async throws {
        let store = try GlucoseStore.productionInMemory()
        let plan = try await store.writer.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + StoreRole.production.latestLiveReadingSQL)
                .map { $0["detail"] as String }
                .joined(separator: " | ")
        }
        XCTAssertTrue(plan.contains("reading_sensor_on_date"), plan)
        XCTAssertFalse(plan.contains("TEMP B-TREE"), "no sort step: \(plan)")
    }

    func test_S6_schemaRejectsImportedRowWithoutOriginAndSensorRowWithOne() async throws {
        let store = try GlucoseStore.productionInMemory()
        for (sourceKind, origin) in [("imported", nil), ("sensor", "nightscout"), ("imported", "somethingElse")] as [(String, String?)] {
            do {
                try await store.writer.write { db in
                    try db.execute(sql: """
                        INSERT INTO reading (id, date, valueKind, mgdl, trendRate, isBackfill, sourceKind, importOrigin, sensorSerial)
                        VALUES ('x', 0, 'mgdl', 100, NULL, 0, ?, ?, 'S')
                        """, arguments: [sourceKind, origin])
                }
                XCTFail("sourceKind \(sourceKind) with importOrigin \(origin ?? "NULL") must be rejected")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
            }
        }
    }

    func test_unknownStoredValuesThrowInsteadOfGuessing() async throws {
        // Simulates a row written by a future version: decoding refuses rather than guessing.
        let row = ReadingRow(sensorReading(at: 0))
        var unknownSource = row
        unknownSource.sourceKind = "satellite"
        XCTAssertThrowsError(try unknownSource.reading()) { error in
            XCTAssertEqual(error as? GlucoseStoreError, .unreadableRow(id: row.id, column: "sourceKind/importOrigin"))
        }
        var unknownOrigin = row
        unknownOrigin.sourceKind = "imported"
        unknownOrigin.importOrigin = "libreview"
        XCTAssertThrowsError(try unknownOrigin.reading()) { error in
            XCTAssertEqual(error as? GlucoseStoreError, .unreadableRow(id: row.id, column: "importOrigin"))
        }
        var unknownValue = row
        unknownValue.valueKind = "belowRange"
        XCTAssertThrowsError(try unknownValue.reading()) { error in
            XCTAssertEqual(error as? GlucoseStoreError, .unreadableRow(id: row.id, column: "valueKind/mgdl"))
        }
    }
}
