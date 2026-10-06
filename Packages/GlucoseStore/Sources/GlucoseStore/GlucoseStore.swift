// GRDB-backed reading storage (HANDOFF §4.4, §4.5). Schema and rules: docs/storage.md.
// Factories (and the production / replay roles): GlucoseStore+Opening.swift.
// Retention, summary and CSV export: GlucoseStore+Maintenance.swift.
//
// Threading: every method is nonisolated and async. GRDB runs writes on its serial writer queue
// and reads on its reader pool, so no SQL runs on the main actor; the UI observes `changes()` and
// reads with `readings(from:to:)`.

import Foundation
import GlucoseCore
import GRDB

public final class GlucoseStore: GlucoseReadingRepository {
    /// The database file, or nil for an in-memory store.
    public let databaseURL: URL?

    /// Which readings this store accepts. Fixed for the store's life.
    let role: StoreRole
    /// Internal (not private) so `@testable` tests can check raw column values with SQL.
    let writer: any DatabaseWriter
    let diagnostics: any DiagnosticLog
    let now: @Sendable () -> Date
    private let broadcaster = ChangeBroadcaster()

    /// Enforces the role on what is already stored, and migrates:
    /// - replay: refuses a file that holds `.sensor`/`.imported` rows (it is the wrong file). This
    ///   check runs before migrating, so refusing a production file changes nothing in it;
    /// - production: after migrating, deletes any `.replay`/`.mock` rows (a DEBUG build from before
    ///   roles existed may have written them to the same file) and records how many (S6).
    init(
        role: StoreRole,
        writer: any DatabaseWriter,
        databaseURL: URL?,
        diagnostics: any DiagnosticLog,
        now: @escaping @Sendable () -> Date
    ) throws {
        self.role = role
        self.writer = writer
        self.databaseURL = databaseURL
        self.diagnostics = diagnostics
        self.now = now

        let migrator = StoreSchema.makeMigrator()
        let unknownMigrations = try writer.read { db in
            try migrator.appliedIdentifiers(db).subtracting(migrator.migrations).sorted()
        }
        guard unknownMigrations.isEmpty else {
            throw GlucoseStoreError.databaseFromNewerAppVersion(unknownMigrations: unknownMigrations)
        }
        #if DEBUG
        if role == .replay {
            // Read-only, before any migration: a production file must come out of this untouched.
            let liveRows = try writer.read { db -> Int in
                guard try db.tableExists(StoreSchema.readingTable) else { return 0 }
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reading WHERE sourceKind IN ('sensor', 'imported')") ?? 0
            }
            guard liveRows == 0 else {
                throw GlucoseStoreError.replayStoreFileContainsLiveData(rowCount: liveRows)
            }
        }
        #endif
        let removedByV2 = try writer.read { db in try StoreSchema.rowsRemovedByV2(db, migrator: migrator) }
        try migrator.migrate(writer)
        if removedByV2 > 0 {
            diagnostics.record(DiagnosticEvent(
                date: now(), category: .store,
                message: "Migration \(StoreSchema.v2MgdlRangeCheck) removed \(removedByV2) stored reading(s) with a number outside 40...400 (parse faults, S1)"
            ))
        }

        switch role {
        case .production:
            let removed = try writer.write { db in
                try db.execute(sql: "DELETE FROM reading WHERE sourceKind IN ('replay', 'mock')")
                return db.changesCount
            }
            if removed > 0 {
                diagnostics.record(DiagnosticEvent(
                    date: now(), category: .store,
                    message: "Removed \(removed) replay/mock reading(s) from the production database on open (S6)"
                ))
            }
        #if DEBUG
        case .replay:
            break // checked before migrating, above
        #endif
        }

        // Held by GRDB for the lifetime of the database connection.
        let broadcaster = self.broadcaster
        writer.add(
            transactionObserver: ReadingTableObserver(onCommitWithChanges: { broadcaster.broadcast() }),
            extent: .databaseLifetime
        )
    }

    deinit {
        // Ends every `changes()` stream so observers' loops finish.
        broadcaster.finishAll()
    }

    // MARK: - GlucoseReadingRepository

    /// See `GlucoseReadingRepository.insert` and `ReadingInsertion.insert` for the rules.
    /// One write transaction per call: either the whole batch is applied or nothing is.
    ///
    /// Throws, and writes nothing from the batch, if any reading's source is not allowed in this
    /// store's role, a numeric value is outside 40...400, a trend rate is not finite, or a date is
    /// later than the store's clock + 60 s. See `ReadingInsertion.validate`. Returns the newly
    /// stored readings exactly as passed. If the write itself fails (SQL error, task cancellation),
    /// the transaction rolls back, nothing is stored and `changes()` does not yield.
    public func insert(_ readings: [GlucoseReading]) async throws -> [GlucoseReading] {
        try ReadingInsertion.validate(readings, role: role, now: now())
        guard !readings.isEmpty else { return [] }
        let outcome = try await writer.write { db in
            try ReadingInsertion.insert(readings, in: db)
        }
        // Recorded after the commit, so a rolled-back batch never logs conflicts that did not happen.
        for conflict in outcome.conflicts {
            record("Kept stored reading \(conflict.id); a re-delivered copy differed in: \(conflict.differingColumns.joined(separator: ", "))")
        }
        if outcome.benignRedeliveryCount > 0 {
            record("Ignored \(outcome.benignRedeliveryCount) re-delivered reading(s) already stored (differing only in isBackfill and/or by ≤ 2 s in date)")
        }
        if outcome.replacedImportedCount > 0 {
            record("Removed \(outcome.replacedImportedCount) imported reading(s) within ±150 s of new sensor readings")
        }
        return outcome.inserted
    }

    public func readings(from start: Date, to end: Date) async throws -> [GlucoseReading] {
        guard start < end else { return [] }
        let bounds: StatementArguments = [start.timeIntervalSinceReferenceDate, end.timeIntervalSinceReferenceDate]
        return try await writer.read { db in
            // Half-open [start, end): a reading exactly at `end` belongs to the next range. Equal
            // dates in storage order (rowid), read straight from reading_on_date(date).
            let rows = try Row.fetchCursor(db, sql: """
                SELECT \(ReadingRow.selectColumns) FROM reading
                WHERE date >= ? AND date < ?
                ORDER BY date, rowid
                """, arguments: bounds)
            var result: [GlucoseReading] = []
            while let row = try rows.next() {
                result.append(try ReadingRow(row: row).reading())
            }
            return result
        }
    }

    /// Newest `.sensor` reading (production) or newest `.replay`/`.mock` reading (replay store);
    /// never `.imported` (S6). SQL: `StoreRole.latestLiveReadingSQL`.
    public func latestLiveReading() async throws -> GlucoseReading? {
        let sql = role.latestLiveReadingSQL
        return try await writer.read { db in
            let row = try Row.fetchOne(db, sql: sql)
            return try row.map { try ReadingRow(row: $0).reading() }
        }
    }

    public func changes() -> AsyncStream<Void> {
        broadcaster.makeStream()
    }

    // MARK: - Diagnostics

    func record(_ message: String) {
        diagnostics.record(DiagnosticEvent(date: now(), category: .store, message: message))
    }
}
