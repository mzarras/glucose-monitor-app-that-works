// The insert rules (S3 dedupe, HANDOFF §4.5 step 3 as clarified in GlucoseReadingRepository.swift).
// Runs inside one write transaction owned by GlucoseStore.insert, so either every statement below
// commits or none does.

import Foundation
import GlucoseCore
import GRDB

enum ReadingInsertion {
    /// HANDOFF §4.5 step 3 "±2.5 min", defined by the repository contract as |Δt| ≤ 150 s,
    /// inclusive: two readings exactly 150 s apart overlap; 151 s apart do not.
    static let overlapWindow: TimeInterval = 150

    /// How far a re-delivered copy's date may be from the stored one and still count as the same
    /// delivery. A G7 reading's date is the phone clock at connection time minus the sensor-reported
    /// session age, re-derived at every connection from a 1-second sensor clock (S3; see
    /// LiveReadingGate.futureTolerance), so a backfilled copy of a reading already stored live can
    /// land a second or so away. Inclusive.
    static let benignDateDifference: TimeInterval = 2

    /// Checks the whole batch before anything is written, so a refused batch stores nothing:
    /// 1. every source is allowed in the store's role (PROGRESS.md D20);
    /// 2. every numeric value is inside `GlucoseValue.sensorReportableRange`, 40...400 (D25): a
    ///    number outside it can only come from a parse fault, and storing it would put it in charts
    ///    and stats (S1). The schema CHECK (migration v2) enforces the same range as a backstop.
    static func validate(_ readings: [GlucoseReading], role: StoreRole) throws(GlucoseReadingRepositoryError) {
        if let refused = readings.first(where: { !role.allows($0.source) }) {
            throw .sourceNotAllowed(refused.source)
        }
        for reading in readings {
            if case .mgdl(let value) = reading.value, !GlucoseValue.sensorReportableRange.contains(value) {
                throw .implausibleValue(value)
            }
        }
    }

    /// A re-delivered reading whose id is already stored but whose content differs.
    struct Conflict: Sendable, Equatable {
        let id: String
        let differingColumns: [String]
    }

    struct Outcome: Sendable {
        /// Newly stored readings still present at commit, ascending by date (ties broken by id).
        var inserted: [GlucoseReading] = []
        /// Same id already stored with a real difference (value, trend rate, source, serial, or a
        /// date more than `benignDateDifference` away). The stored row was kept.
        var conflicts: [Conflict] = []
        /// Same id already stored, differing only in `isBackfill` and/or by ≤ 2 s in date: the
        /// expected shape of a backfilled copy of a live reading. The stored row was kept.
        var benignRedeliveryCount = 0
        /// Imported rows deleted because a sensor reading landed within the overlap window.
        var replacedImportedCount = 0
        /// Imported readings not stored because another reading lies within the overlap window.
        var skippedImportedCount = 0
    }

    /// Applies the rules to each reading, in ascending date order (ties by id) so they hold within
    /// one batch exactly as across batches:
    ///
    /// 1. Same id already stored → nothing is written; the stored row wins (S3: dedupe by
    ///    sensor-reported timestamp). A difference only in `isBackfill` and/or ≤ 2 s in date is
    ///    counted as a benign re-delivery; any other difference is reported as a conflict.
    /// 2. `.imported` → skipped when any stored reading of any source lies within ±150 s.
    /// 3. Otherwise the row is inserted.
    /// 4. `.sensor` → deletes `.imported` rows within ±150 s, including any stored earlier in
    ///    this same batch (those are removed from the returned list too).
    ///
    /// `.replay` and `.mock` readings get rules 1 and 3 only.
    static func insert(_ readings: [GlucoseReading], in db: Database) throws -> Outcome {
        var outcome = Outcome()
        var insertedRows: [ReadingRow] = []
        let ordered = readings.map(ReadingRow.init).sorted { ($0.date, $0.id) < ($1.date, $1.id) }

        for row in ordered {
            if let stored = try fetchRow(id: row.id, db) {
                if stored == row {
                    // Identical re-delivery: nothing to note.
                } else if stored.isBenignRedelivery(of: row, maximumDateDifference: benignDateDifference) {
                    outcome.benignRedeliveryCount += 1
                } else {
                    outcome.conflicts.append(Conflict(id: row.id, differingColumns: stored.differingColumns(from: row)))
                }
                continue
            }

            let isImported = row.sourceKind == "imported"
            if isImported, try anyRowExists(near: row.date, db) {
                outcome.skippedImportedCount += 1
                continue
            }

            try insertRow(row, db)
            insertedRows.append(row)

            if row.sourceKind == "sensor" {
                let removed = try deleteImportedRows(near: row.date, db)
                outcome.replacedImportedCount += removed.count
                insertedRows.removeAll { removed.contains($0.id) }
            }
        }

        // Already ascending: rows were appended in date order and only removals happened since.
        outcome.inserted = try insertedRows.map { try $0.reading() }
        return outcome
    }

    private static func fetchRow(id: String, _ db: Database) throws -> ReadingRow? {
        let statement = try db.cachedStatement(sql: "SELECT \(ReadingRow.selectColumns) FROM reading WHERE id = ?")
        return try Row.fetchOne(statement, arguments: [id]).map(ReadingRow.init(row:))
    }

    /// Plain INSERT: the id was just checked to be absent, and inside the write transaction nothing
    /// else can add it. Any constraint violation (duplicate id, CHECK, NOT NULL) throws and rolls
    /// back the whole batch (S5); nothing is ignored silently.
    private static func insertRow(_ row: ReadingRow, _ db: Database) throws {
        try db.cachedStatement(sql: """
            INSERT INTO reading (\(ReadingRow.selectColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """).execute(arguments: row.insertArguments)
    }

    /// Any stored reading, any source, within ±150 s. BETWEEN is inclusive at both ends, which is
    /// what makes exactly 150 s an overlap.
    private static func anyRowExists(near date: Double, _ db: Database) throws -> Bool {
        let statement = try db.cachedStatement(sql: """
            SELECT EXISTS (
                SELECT 1 FROM reading
                WHERE date BETWEEN ? AND ?
            )
            """)
        return try Bool.fetchOne(statement, arguments: [date - overlapWindow, date + overlapWindow]) ?? false
    }

    /// Deletes imported rows within ±150 s and returns their ids.
    private static func deleteImportedRows(near date: Double, _ db: Database) throws -> Set<String> {
        let bounds: StatementArguments = [date - overlapWindow, date + overlapWindow]
        let ids = try String.fetchSet(db.cachedStatement(sql: """
            SELECT id FROM reading
            WHERE sourceKind = 'imported'
              AND date BETWEEN ? AND ?
            """), arguments: bounds)
        guard !ids.isEmpty else { return [] }
        try db.cachedStatement(sql: """
            DELETE FROM reading
            WHERE sourceKind = 'imported'
              AND date BETWEEN ? AND ?
            """).execute(arguments: bounds)
        return ids
    }
}
