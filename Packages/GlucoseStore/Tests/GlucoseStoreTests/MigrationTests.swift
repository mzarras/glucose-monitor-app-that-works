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

    /// Builds a database at the v1 schema only (as a build from before v2 left it) and writes rows
    /// directly, including numbers v1 still allowed but v2 does not.
    private func makeV1Database(at url: URL, rows: [(id: String, date: Double, kind: String, mgdl: Int?, source: String, origin: String?)]) throws {
        let queue = try DatabaseQueue(path: url.path)
        try StoreSchema.makeMigrator().migrate(queue, upTo: StoreSchema.v1CreateReading)
        try queue.write { db in
            for row in rows {
                try db.execute(sql: """
                    INSERT INTO reading (id, date, valueKind, mgdl, trendRate, isBackfill, sourceKind, importOrigin, sensorSerial)
                    VALUES (?, ?, ?, ?, 0.2, 0, ?, ?, 'S')
                    """, arguments: [row.id, row.date, row.kind, row.mgdl, row.source, row.origin])
            }
        }
        try queue.close()
    }

    func test_migratesAV1DatabaseAddingTheRangeCheck() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("readings.sqlite")
        let base = referenceInstant.timeIntervalSinceReferenceDate
        try makeV1Database(at: url, rows: [
            ("S:0", base, "mgdl", 110, "sensor", nil),
            ("S:300", base + 300, "belowRange", nil, "sensor", nil),
            ("imported:nightscout:1", base - 3_600, "mgdl", 40, "imported", "nightscout"),
            ("imported:nightscout:2", base - 3_300, "mgdl", 400, "imported", "nightscout"),
            ("bad:0", base + 600, "mgdl", 0, "sensor", nil),
            ("bad:39", base + 900, "mgdl", 39, "sensor", nil),
            ("bad:401", base + 1_200, "mgdl", 401, "imported", "clarityCSV"),
        ])

        let log = RecordingDiagnosticLog()
        let store = try await GlucoseStore.production(at: url, diagnostics: log, now: { referenceInstant })

        let applied = try await store.writer.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid") }
        XCTAssertEqual(applied, ["v1-create-reading", "v2-mgdl-range-check"])
        let ids = try await store.writer.read { db in try String.fetchAll(db, sql: "SELECT id FROM reading ORDER BY date") }
        XCTAssertEqual(ids, ["imported:nightscout:1", "imported:nightscout:2", "S:0", "S:300"], "valid rows kept, implausible rows removed")
        let kept = try await store.readings(from: referenceInstant.addingTimeInterval(-86_400), to: referenceInstant.addingTimeInterval(86_400))
        XCTAssertEqual(kept.map(\.value), [.mgdl(40), .mgdl(400), .mgdl(110), .belowRange], "kept rows unchanged")
        XCTAssertEqual(kept.map(\.trendRate), [0.2, 0.2, 0.2, 0.2])
        XCTAssertEqual(log.recorded.map(\.message), [
            "Migration v2-mgdl-range-check removed 3 stored reading(s) with a number outside 40...400 (parse faults, S1)",
        ])

        let indexes = try await store.writer.read { db in try db.indexes(on: "reading").map(\.name).sorted() }
        XCTAssertEqual(indexes, ["reading_on_date", "reading_sensor_on_date", "sqlite_autoindex_reading_1"])
        do {
            try await store.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO reading (id, date, valueKind, mgdl, trendRate, isBackfill, sourceKind, importOrigin, sensorSerial)
                    VALUES ('late', 0, 'mgdl', 401, NULL, 0, 'sensor', NULL, 'S')
                    """)
            }
            XCTFail("the v2 CHECK is not in force")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }
        let latest = try await store.latestLiveReading()
        XCTAssertEqual(latest?.id, "S:300")
    }

    func test_migratingACleanV1DatabaseRecordsNothing() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("readings.sqlite")
        try makeV1Database(at: url, rows: [("S:0", referenceInstant.timeIntervalSinceReferenceDate, "mgdl", 110, "sensor", nil)])
        let log = RecordingDiagnosticLog()
        let store = try await GlucoseStore.production(at: url, diagnostics: log)
        XCTAssertEqual(log.recorded, [])
        let count = try await store.summary().readingCount
        XCTAssertEqual(count, 1)
    }
}

