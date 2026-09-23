// Database schema (HANDOFF §4.4, S3, S4). See docs/storage.md for the column reference.
//
// Migrations are append-only: never edit or reorder a migration once it has shipped, because a
// device that already ran it will not run it again. Add a new `registerMigration` call instead.

import GRDB

enum StoreSchema {
    /// The one table. Referenced by the change observer and every query.
    static let readingTable = "reading"

    static let v1CreateReading = "v1-create-reading"
    static let v2MgdlRangeCheck = "v2-mgdl-range-check"

    /// Identifiers of every migration, in order. The migration test asserts this list.
    static let migrationIdentifiers = [v1CreateReading, v2MgdlRangeCheck]

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(v1CreateReading, migrate: createReadingTable)
        migrator.registerMigration(v2MgdlRangeCheck, migrate: addMgdlRangeCheck)
        return migrator
    }

    /// Rows that `v2-mgdl-range-check` will not carry over: numeric values outside 40...400. Such a
    /// number can only come from a parse fault (GlucoseValue.sensorReportableRange). Returns 0 once
    /// v2 has run. GlucoseStore reads this before migrating so it can record what was removed.
    static func rowsRemovedByV2(_ db: Database, migrator: DatabaseMigrator) throws -> Int {
        guard try db.tableExists(readingTable),
              try !migrator.appliedIdentifiers(db).contains(v2MgdlRangeCheck) else { return 0 }
        return try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM reading WHERE mgdl IS NOT NULL AND mgdl NOT BETWEEN 40 AND 400
            """) ?? 0
    }

    /// v1 (superseded by v2's table; kept unchanged because migrations are append-only).
    /// A rowid table on purpose: SQLite does not call the update hook for WITHOUT ROWID tables,
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

    /// v2 (PROGRESS.md D25): numeric values must lie in the sensor's reportable range, 40...400
    /// (GlucoseValue.sensorReportableRange). SQLite cannot add a CHECK to an existing table, so the
    /// table is rebuilt the standard way (https://www.sqlite.org/lang_altertable.html#otheralter):
    /// create the new table, copy the rows, drop the old table, rename, recreate the indexes.
    /// Rows with a number outside 40...400 are not copied (GlucoseStore records how many).
    ///
    /// This is the current schema; see docs/storage.md for the column reference.
    private static func addMgdlRangeCheck(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE reading_v2 (
                -- GlucoseReading.id, the S3 dedupe key.
                id TEXT NOT NULL PRIMARY KEY,
                -- UTC instant, seconds since 2001-01-01T00:00:00Z (Date.timeIntervalSinceReferenceDate).
                date REAL NOT NULL,
                -- 'mgdl' = a number; 'belowRange' = sensor LOW flag; 'aboveRange' = sensor HIGH flag.
                valueKind TEXT NOT NULL CHECK (valueKind IN ('mgdl', 'belowRange', 'aboveRange')),
                -- The number when valueKind = 'mgdl', NULL for LOW/HIGH (S4), and always 40...400.
                mgdl INTEGER
                    CHECK ((valueKind = 'mgdl') = (mgdl IS NOT NULL))
                    CHECK (mgdl IS NULL OR mgdl BETWEEN 40 AND 400),
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
        try db.execute(sql: """
            INSERT INTO reading_v2 (id, date, valueKind, mgdl, trendRate, isBackfill, sourceKind, importOrigin, sensorSerial)
            SELECT id, date, valueKind, mgdl, trendRate, isBackfill, sourceKind, importOrigin, sensorSerial
            FROM reading
            WHERE mgdl IS NULL OR mgdl BETWEEN 40 AND 400
            """)
        // Dropping the table drops its indexes too; they are recreated below, unchanged from v1.
        try db.execute(sql: "DROP TABLE reading")
        try db.execute(sql: "ALTER TABLE reading_v2 RENAME TO reading")
        try db.execute(sql: "CREATE INDEX reading_on_date ON reading(date, id)")
        try db.execute(sql: """
            CREATE INDEX reading_sensor_on_date ON reading(date, id)
            WHERE sourceKind = 'sensor'
            """)
    }
}
