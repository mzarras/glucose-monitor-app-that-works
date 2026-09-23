// Retention purge, the Settings summary, and "Export all data (CSV)" (HANDOFF §4.5).

import Foundation
import GlucoseCore
import GRDB

extension GlucoseStore {
    /// Deletes readings (from every source) dated strictly before `policy.cutoff(now:)`, using the
    /// store's clock. `.forever` deletes nothing. Returns the number of rows deleted.
    ///
    /// The file does not shrink (SQLite reuses the freed pages for new rows); see docs/storage.md.
    @discardableResult
    public func purge(keeping policy: RetentionPolicy) async throws -> Int {
        guard let cutoff = policy.cutoff(now: now()) else { return 0 }
        let deleted = try await writer.write { db in
            try db.execute(sql: "DELETE FROM reading WHERE date < ?", arguments: [cutoff.timeIntervalSinceReferenceDate])
            return db.changesCount
        }
        if deleted > 0 {
            record("Retention (\(policy.rawValue)) removed \(deleted) reading(s) older than \(CSVExport.utcTimestamp(cutoff))")
        }
        return deleted
    }

    /// Row count, covered date range, and bytes on disk (database + -wal + -shm).
    public func summary() async throws -> StoreSummary {
        let (count, earliest, latest) = try await writer.read { db -> (Int, Double?, Double?) in
            let row = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS n, MIN(date) AS earliest, MAX(date) AS latest FROM reading")
            guard let row else { return (0, nil, nil) }
            return (row["n"], row["earliest"], row["latest"])
        }
        return StoreSummary(
            readingCount: count,
            earliest: earliest.map(Date.init(timeIntervalSinceReferenceDate:)),
            latest: latest.map(Date.init(timeIntervalSinceReferenceDate:)),
            fileSizeBytes: try databaseURL.map(Self.bytesOnDisk)
        )
    }

    private static func bytesOnDisk(_ databaseURL: URL) throws -> Int64 {
        var total: Int64 = 0
        for file in databaseFiles(for: databaseURL) where FileManager.default.fileExists(atPath: file.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            total += (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        return total
    }

    /// "Export all data (CSV)": streams every row, ascending by date, to `destination` in the
    /// format documented in CSVExport.swift and docs/storage.md. Memory use is constant: rows are
    /// read through a cursor and written in 64 KB chunks. The file is written next to the
    /// destination first and moved into place only when complete. Returns the number of rows.
    @discardableResult
    public func exportCSV(to destination: URL) async throws -> Int {
        try await writer.read { db in
            try CSVFileWriter.write(to: destination) { emit in
                let rows = try Row.fetchCursor(db, sql: "SELECT \(ReadingRow.selectColumns) FROM reading ORDER BY date, id")
                var count = 0
                while let row = try rows.next() {
                    try emit(CSVExport.line(for: try ReadingRow(row: row).reading()))
                    count += 1
                }
                return count
            }
        }
    }
}
