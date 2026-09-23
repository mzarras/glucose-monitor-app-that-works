import GlucoseCore
import GRDB
import XCTest
@testable import GlucoseStore

final class MigrationTests: XCTestCase {
    func test_migratesAnEmptyDatabaseToTheCurrentSchema() async throws {
        let store = try GlucoseStore.productionInMemory()
        let (applied, columns, indexes) = try await store.writer.read { db in
            (
                try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"),
                try db.columns(in: "reading").map { "\($0.name) \($0.type) \($0.isNotNull ? "NOT NULL" : "NULL")" },
                try db.indexes(on: "reading").map { "\($0.name)(\($0.columns.joined(separator: ",")))" }
            )
        }
        XCTAssertEqual(applied, StoreSchema.migrationIdentifiers)
        XCTAssertEqual(columns, [
            "id TEXT NOT NULL",
            "date REAL NOT NULL",
            "valueKind TEXT NOT NULL",
            "mgdl INTEGER NULL",
            "trendRate REAL NULL",
            "isBackfill INTEGER NOT NULL",
            "sourceKind TEXT NOT NULL",
            "importOrigin TEXT NULL",
            "sensorSerial TEXT NOT NULL",
        ])
        XCTAssertEqual(indexes.sorted(), ["reading_on_date(date,id)", "reading_sensor_on_date(date,id)", "sqlite_autoindex_reading_1(id)"])
        let liveIndexSQL = try await store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'reading_sensor_on_date'")
        }
        XCTAssertTrue(liveIndexSQL?.contains("WHERE sourceKind = 'sensor'") == true, liveIndexSQL ?? "nil")
        let idIsUnique = try await store.writer.read { db in try db.table("reading", hasUniqueKey: ["id"]) }
        XCTAssertTrue(idIsUnique)
    }

    func test_reopeningAFileKeepsItsDataAndDoesNotMigrateAgain() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("readings.sqlite")
        let reading = sensorReading(at: 300)

        do {
            let store = try await GlucoseStore.production(at: url)
            _ = try await store.insert([reading])
        }
        let reopened = try await GlucoseStore.production(at: url)
        let latest = try await reopened.latestLiveReading()
        XCTAssertEqual(latest, reading)
        let applied = try await reopened.writer.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
        }
        XCTAssertEqual(applied, StoreSchema.migrationIdentifiers)
    }

    func test_refusesADatabaseWrittenByANewerAppVersion() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("readings.sqlite")

        do {
            let store = try await GlucoseStore.production(at: url)
            try await store.writer.write { db in
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99-from-the-future')")
            }
        }
        do {
            _ = try await GlucoseStore.production(at: url)
            XCTFail("expected databaseFromNewerAppVersion")
        } catch let error as GlucoseStoreError {
            XCTAssertEqual(error, .databaseFromNewerAppVersion(unknownMigrations: ["v99-from-the-future"]))
        }
    }
}
