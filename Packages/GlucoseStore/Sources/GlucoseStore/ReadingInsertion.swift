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

    /// Checks the whole batch before anything is written, so a refused batch stores nothing. In
    /// this order:
    /// 1. every source is allowed in the store's role (PROGRESS.md D20) → `.sourceNotAllowed`;
    /// 2. every numeric value is inside `GlucoseValue.sensorReportableRange`, 40...400 (D25) →
    ///    `.implausibleValue`. The schema CHECK (migration v2) enforces the same range as a backstop;
    /// 3. every trend rate is finite or nil (D33) → `.nonFiniteTrendRate`. Never rewritten to nil:
    ///    the fault must stay visible to `LiveReadingGate`, and SQLite would store NaN as NULL;
    /// 4. no reading is dated later than `now + LiveReadingGate.futureTolerance` (60 s, inclusive)
    ///    (D33) → `.futureDated`. A future-dated row would become the current value (S5).
    /// Each can only come from a parse or clock fault; storing it would put it in charts, stats or
    /// the current value (S1, S5).
    static func validate(_ readings: [GlucoseReading], role: StoreRole, now: Date) throws(GlucoseReadingRepositoryError) {
        if let refused = readings.first(where: { !role.allows($0.source) }) {
            throw .sourceNotAllowed(refused.source)
        }
        for reading in readings {
            if case .mgdl(let value) = reading.value, !GlucoseValue.sensorReportableRange.contains(value) {
                throw .implausibleValue(value)
            }
        }
        if readings.contains(where: { $0.trendRate.map { !$0.isFinite } ?? false }) {
            throw .nonFiniteTrendRate
        }
        let latestAllowed = now.addingTimeInterval(LiveReadingGate.futureTolerance)
        if let future = readings.first(where: { $0.date > latestAllowed }) {
            throw .futureDated(future.date)
        }
    }

    /// A re-delivered reading whose id is already stored but whose content differs.
    struct Conflict: Sendable, Equatable {
        let id: String
        let differingColumns: [String]
    }

    struct Outcome: Sendable {
        /// Newly stored readings still present at commit, exactly as the caller passed them,
        /// ascending by date (equal dates in the order they were passed).
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

    /// Applies the rules to each reading, in ascending date order (equal dates in the order they
    /// were passed, so storage order — the tie-break everywhere — follows delivery order), so they
    /// hold within one batch exactly as across batches:
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
        var inserted: [GlucoseReading] = []
        let ordered = readings.enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)

        for reading in ordered {
            let row = ReadingRow(reading)
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
            inserted.append(reading)

            if row.sourceKind == "sensor" {
                let removed = try deleteImportedRows(near: row.date, db)
                outcome.replacedImportedCount += removed.count
                inserted.removeAll { removed.contains($0.id) }
            }
        }

        // Already ascending: appended in date order, only removals since. These are the caller's
        // own values, not rows read back (D33: returned exactly as passed).
        outcome.inserted = inserted
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
