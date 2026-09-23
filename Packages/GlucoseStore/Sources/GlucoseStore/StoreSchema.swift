// Database schema (HANDOFF §4.4, S3, S4). See docs/storage.md for the column reference.
//
// Migrations are append-only: never edit or reorder a migration once it has shipped, because a
// device that already ran it will not run it again. Add a new `registerMigration` call instead.

import GRDB

enum StoreSchema {
    /// The one table. Referenced by the change observer and every query.
    static let readingTable = "reading"

    /// Identifiers of every migration, in order. The migration test asserts this list.
    static let migrationIdentifiers = ["v1-create-reading"]

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-create-reading", migrate: createReadingTable)
        return migrator
    }

    /// v1. A rowid table on purpose: SQLite does not call the update hook for WITHOUT ROWID tables,
    /// and GRDB's transaction observer (which drives `changes()`) is built on that hook.
    private static func createReadingTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE reading (
                -- GlucoseReading.id, the S3 dedupe key: "<serial>:<sensor seconds>" for sensor
                -- readings, "imported:<origin>:<epoch-ms>" for imported history.
                id TEXT NOT NULL PRIMARY KEY,
                -- UTC instant as seconds since 2001-01-01T00:00:00Z, i.e. exactly the Double that
                -- Foundation's Date stores (timeIntervalSinceReferenceDate), so the round trip is
                -- bit-exact and no time zone is involved. Readable form:
                --   datetime(date + 978307200, 'unixepoch')
                date REAL NOT NULL,
                -- 'mgdl' = a number; 'belowRange' = sensor LOW flag; 'aboveRange' = sensor HIGH flag.
                valueKind TEXT NOT NULL CHECK (valueKind IN ('mgdl', 'belowRange', 'aboveRange')),
                -- The number when valueKind = 'mgdl'. NULL for LOW/HIGH: a flag is never stored as
                -- 40 or 400 (S4). The CHECK makes the two columns agree.
                mgdl INTEGER CHECK ((valueKind = 'mgdl') = (mgdl IS NOT NULL)),
                -- mg/dL per minute exactly as reported; NULL when not reported.
                trendRate REAL,
                -- 1 when the reading arrived through backfill (it keeps its original date, S3).
                isBackfill INTEGER NOT NULL CHECK (isBackfill IN (0, 1)),
                -- ReadingSource case: 'sensor' | 'imported' | 'replay' | 'mock' (S6).
                sourceKind TEXT NOT NULL CHECK (sourceKind IN ('sensor', 'imported', 'replay', 'mock')),
                -- ImportOrigin raw value, present exactly when sourceKind = 'imported'.
                importOrigin TEXT
                    CHECK ((sourceKind = 'imported') = (importOrigin IS NOT NULL))
                    CHECK (importOrigin IS NULL OR importOrigin IN ('nightscout', 'clarityCSV')),
                -- Transmitter/sensor serial; empty string when unknown.
                sensorSerial TEXT NOT NULL
            )
            """)
        // Range queries (ORDER BY date, id), retention purge and the ±150 s import rule all filter
        // or sort on date; id is the tie-break, so ordered range scans need no sort step.
        try db.execute(sql: "CREATE INDEX reading_on_date ON reading(date, id)")
        // latestLiveReading() in a production store: newest sensor row. A partial index holds only
        // sensor rows, so the query reads one index entry even when newer imported rows exist.
        try db.execute(sql: """
            CREATE INDEX reading_sensor_on_date ON reading(date, id)
            WHERE sourceKind = 'sensor'
            """)
    }
}
