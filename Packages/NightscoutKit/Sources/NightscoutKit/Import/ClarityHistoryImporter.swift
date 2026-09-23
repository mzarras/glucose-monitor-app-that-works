// Stores a parsed Clarity export (HANDOFF §4.5 steps 2–4). Imported readings feed charts and stats
// only (S6). Idempotent: readings are keyed by `importedID(origin: .clarityCSV, …)` and the
// repository inserts-or-ignores, so importing the same (or an overlapping) file again stores
// nothing new. A whole file is parsed before anything is stored; storage is batched so an
// interrupted import simply re-runs.

import Foundation
import GlucoseCore

public struct ClarityImportProgress: Sendable, Equatable {
    /// Readings newly stored so far.
    public let readingsImported: Int
    /// Readings the repository did not store (already present, or within ±150 s of a stored reading).
    public let readingsSkippedByStore: Int
    /// Readings handed to the repository so far (stored or already present).
    public let readingsProcessed: Int
    public let readingsTotal: Int
    /// Date range of the readings processed so far, `nil` before the first batch.
    public let coveredFrom: Date?
    public let coveredTo: Date?
}

public struct ClarityImportResult: Sendable, Equatable {
    public let parse: ClarityParseResult
    /// Readings newly stored by this import.
    public let readingsImported: Int
    /// Parsed readings the repository did not store (already present, or within ±150 s of a stored
    /// reading, e.g. overlap with a Nightscout import or with sensor data).
    public let readingsSkippedByStore: Int
    public let coveredFrom: Date?
    public let coveredTo: Date?
}

public struct ClarityHistoryImporter: Sendable {
    /// One week of 5-minute readings per repository call.
    public static let defaultBatchSize = 2_016

    private let repository: any GlucoseReadingRepository
    private let clock: any WallClock
    private let log: any DiagnosticLog
    private let batchSize: Int

    public init(
        repository: any GlucoseReadingRepository,
        clock: any WallClock = SystemWallClock(),
        log: any DiagnosticLog = NullDiagnosticLog(),
        batchSize: Int = ClarityHistoryImporter.defaultBatchSize
    ) {
        self.repository = repository
        self.clock = clock
        self.log = log
        self.batchSize = max(1, batchSize)
    }

    /// Parses `data` as a Clarity export recorded in `timeZone` and stores its readings.
    public func importExport(
        _ data: Data,
        timeZone: TimeZone = .current,
        onProgress: @Sendable (ClarityImportProgress) -> Void = { _ in }
    ) async throws(ClarityImportError) -> ClarityImportResult {
        let parsed = try ClarityExportParser.parse(data, timeZone: timeZone, now: clock.now())
        let sorted = parsed.readings.sorted { $0.date < $1.date }
        var imported = 0
        var processed = 0
        var start = 0
        while start < sorted.count {
            let batch = Array(sorted[start..<min(start + batchSize, sorted.count)])
            do {
                imported += try await repository.insert(batch).count
            } catch {
                record("Clarity import stopped after \(processed) readings: \(error)")
                throw .repository(String(describing: error))
            }
            processed += batch.count
            start += batch.count
            onProgress(ClarityImportProgress(
                readingsImported: imported, readingsSkippedByStore: processed - imported, readingsProcessed: processed, readingsTotal: sorted.count,
                coveredFrom: sorted.first?.date, coveredTo: batch.last?.date
            ))
        }
        record("Clarity import: \(parsed.egvRows) EGV rows, \(imported) new readings, "
            + "\(sorted.count - imported) skipped by the store, "
            + "\(parsed.rejectedNonexistentLocalTime) nonexistent and \(parsed.rejectedAmbiguousLocalTime) ambiguous local times, "
            + "\(parsed.rejectedInvalidTimestamp) bad timestamps, \(parsed.rejectedInvalidValue) bad values, "
            + "\(parsed.rejectedFutureDated) in the future")
        return ClarityImportResult(
            parse: parsed, readingsImported: imported, readingsSkippedByStore: sorted.count - imported,
            coveredFrom: sorted.first?.date, coveredTo: sorted.last?.date
        )
    }

    private func record(_ message: String) {
        log.record(DiagnosticEvent(date: clock.now(), category: .importer, message: message))
    }
}
