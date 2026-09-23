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

    /// Migrates, then enforces the role on what is already stored:
    /// - production: deletes any `.replay`/`.mock` rows (a DEBUG build may have written them to the
    ///   same file before roles existed) and records how many (S6);
    /// - replay: refuses a file that holds `.sensor`/`.imported` rows (it is the wrong file).
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
        try migrator.migrate(writer)

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
            let liveRows = try writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reading WHERE sourceKind IN ('sensor', 'imported')") ?? 0
            }
            guard liveRows == 0 else {
                throw GlucoseStoreError.replayStoreFileContainsLiveData(rowCount: liveRows)
            }
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
    /// Throws `GlucoseReadingRepositoryError.sourceNotAllowed` (and writes nothing) if any reading's
    /// source is not allowed in this store's role.
    public func insert(_ readings: [GlucoseReading]) async throws -> [GlucoseReading] {
        if let refused = readings.first(where: { !role.allows($0.source) }) {
            throw GlucoseReadingRepositoryError.sourceNotAllowed(refused.source)
        }
        guard !readings.isEmpty else { return [] }
        let outcome = try await writer.write { db in
            try ReadingInsertion.insert(readings, in: db)
        }
        // Recorded after the commit, so a rolled-back batch never logs conflicts that did not happen.
        for conflict in outcome.conflicts {
            record("Kept stored reading \(conflict.id); a re-delivered copy differed in: \(conflict.differingColumns.joined(separator: ", "))")
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
            // Half-open [start, end): a reading exactly at `end` belongs to the next range.
            let rows = try Row.fetchCursor(db, sql: """
                SELECT \(ReadingRow.selectColumns) FROM reading
                WHERE date >= ? AND date < ?
                ORDER BY date, id
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
