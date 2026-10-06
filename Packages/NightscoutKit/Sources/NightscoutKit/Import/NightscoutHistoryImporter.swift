// Original to Sensor (no ported code).
// First-run history import from the owner's Nightscout (HANDOFF §4.5 step 1, steps 3–4).
//
// Walks backwards from the moment the plan started in 7-day windows, newest first, so the most
// useful history lands first. Each window is fetched (paging inside the window if needed), mapped
// to `.imported(.nightscout)` readings, handed to `GlucoseReadingRepository.insert` (which applies
// id dedupe and the ±150 s rule against every stored reading, so near-duplicates from two
// Nightscout uploaders collapse there), and then checkpointed. Imported readings feed charts and
// stats only (S6); nothing here touches Trio, alerts, or uploaders.

import Foundation
import GlucoseCore

public enum NightscoutImportError: Error, Sendable, Equatable, CustomStringConvertible {
    case alreadyRunning
    case nightscout(NightscoutClientError)
    /// More than one page of entries share a single millisecond; paging cannot make progress.
    case pageTooDense(atMilliseconds: Int64)
    case repository(String)
    case checkpoint(String)

    public var description: String {
        switch self {
        case .alreadyRunning: return "A Nightscout import is already running"
        case .nightscout(let error): return error.description
        case .pageTooDense(let ms): return "Too many Nightscout entries at \(ms) ms to page through"
        case .repository(let message): return "Could not store imported readings: \(message)"
        case .checkpoint(let message): return "Could not save import progress: \(message)"
        }
    }
}

public actor NightscoutHistoryImporter {
    /// HANDOFF §4.5 step 1: "paged by date … in 7-day windows".
    public static let windowLength: TimeInterval = 7 * 86_400
    /// `count` per request. A 7-day window at the G7's 5-minute cadence holds 2016 readings; 3000
    /// leaves room for a second uploader's copies before a window needs a second page.
    public static let defaultPageSize = 3_000
    /// "Everything" never walks below the Unix epoch (entries there are not real readings).
    static let earliestPossibleDate = Date(timeIntervalSince1970: 0)

    private let site: NightscoutSite
    private let client: NightscoutClient
    private let repository: any GlucoseReadingRepository
    private let checkpoints: any NightscoutImportCheckpointStore
    private let clock: any WallClock
    private let log: any DiagnosticLog
    private let pageSize: Int
    private var isRunning = false

    public init(
        site: NightscoutSite,
        credentials: any CredentialStore,
        repository: any GlucoseReadingRepository,
        checkpoints: any NightscoutImportCheckpointStore,
        transport: any HTTPTransport = URLSessionTransport(),
        clock: any WallClock = SystemWallClock(),
        log: any DiagnosticLog = NullDiagnosticLog(),
        pageSize: Int = NightscoutHistoryImporter.defaultPageSize
    ) {
        self.site = site
        self.client = NightscoutClient(site: site, credentials: credentials, transport: transport)
        self.repository = repository
        self.checkpoints = checkpoints
        self.clock = clock
        self.log = log
        self.pageSize = max(1, pageSize)
    }

    /// Runs (or resumes) the import for `scope` and returns the final progress.
    ///
    /// Resumable: continues from the saved checkpoint when it belongs to the same site and scope.
    /// Idempotent: a finished plan returns immediately without network access; re-importing the
    /// same history (e.g. after `reset()`) stores nothing new because readings are keyed by
    /// `importedID` and the repository inserts-or-ignores.
    @discardableResult
    public func run(
        scope: NightscoutImportScope = .default,
        onProgress: @Sendable (NightscoutImportProgress) -> Void = { _ in }
    ) async throws -> NightscoutImportProgress {
        guard !isRunning else { throw NightscoutImportError.alreadyRunning }
        isRunning = true
        defer { isRunning = false }

        var checkpoint = try await loadOrStartPlan(scope: scope)
        onProgress(NightscoutImportProgress(checkpoint: checkpoint))
        record("Nightscout import \(checkpoint.isFinished ? "already finished" : "running") for \(scope)")

        do {
            while !checkpoint.isFinished {
                try Task.checkCancellation()
                try await importNextWindow(&checkpoint)
                try await save(checkpoint)
                onProgress(NightscoutImportProgress(checkpoint: checkpoint))
            }
        } catch {
            record("Nightscout import stopped: \(error)")
            throw error
        }
        record("Nightscout import finished: \(checkpoint.readingsImported) readings, down to \(checkpoint.completedDownTo)")
        return NightscoutImportProgress(checkpoint: checkpoint)
    }

    /// The same as `run`, as a stream of progress values. Cancelling the consumer cancels the import
    /// (the checkpoint keeps what finished).
    public nonisolated func progressStream(scope: NightscoutImportScope = .default) -> AsyncThrowingStream<NightscoutImportProgress, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(scope: scope) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Forgets the checkpoint; the next `run` starts a new plan ending "now".
    public func reset() async throws {
        do {
            try await checkpoints.clearCheckpoint()
        } catch {
            throw NightscoutImportError.checkpoint(String(describing: error))
        }
    }

    // MARK: - Plan

    private func loadOrStartPlan(scope: NightscoutImportScope) async throws -> NightscoutImportCheckpoint {
        let saved: NightscoutImportCheckpoint?
        do {
            saved = try await checkpoints.loadCheckpoint()
        } catch {
            // An unreadable checkpoint only costs re-fetching; the repository keeps the import idempotent.
            record("Nightscout import checkpoint unreadable, starting over: \(error)")
            saved = nil
        }
        let now = clock.now()
        if let saved, saved.site == site, saved.scope == scope {
            if Self.isPlausible(saved, now: now) { return saved }
            record("Nightscout import checkpoint has implausible dates, starting over")
        }
        let planEnd = now
        let planStart: Date?
        switch scope {
        case .lastDays(let days): planStart = planEnd.addingTimeInterval(-Double(max(0, days)) * 86_400)
        case .everything: planStart = nil
        }
        let fresh = NightscoutImportCheckpoint(
            site: site, scope: scope, planEnd: planEnd, planStart: planStart,
            completedDownTo: planEnd, readingsImported: 0, readingsSkippedByStore: 0, skipped: [:], isFinished: false
        )
        try await save(fresh)
        return fresh
    }

    /// A stored checkpoint's dates must lie between 1970 and a year from now, in order — anything
    /// else is a corrupted or hand-edited value, and converting it to epoch milliseconds could
    /// trap. A year of slack keeps a plan that started while the phone's clock was wrong (hours or
    /// days ahead) resumable (D33).
    static func isPlausible(_ checkpoint: NightscoutImportCheckpoint, now: Date) -> Bool {
        let latest = now.addingTimeInterval(365 * 86_400)
        let range = earliestPossibleDate...latest
        guard range.contains(checkpoint.planEnd), range.contains(checkpoint.completedDownTo),
              checkpoint.completedDownTo <= checkpoint.planEnd else { return false }
        if let planStart = checkpoint.planStart {
            return range.contains(planStart) && planStart <= checkpoint.planEnd
        }
        return true
    }

    // MARK: - One window

    private func importNextWindow(_ checkpoint: inout NightscoutImportCheckpoint) async throws {
        let upper = checkpoint.completedDownTo
        let floor = max(checkpoint.planStart ?? Self.earliestPossibleDate, Self.earliestPossibleDate)
        guard upper > floor else {
            checkpoint.isFinished = true
            return
        }
        let lower = max(floor, upper.addingTimeInterval(-Self.windowLength))

        let entries = try await fetchWindow(lowerMs: milliseconds(lower), upperMs: milliseconds(upper))
        var readingsByID: [String: GlucoseReading] = [:]
        // Windows never reach past the plan end, but the phone's clock may have been corrected
        // backwards since the plan started (or an uploader's clock was ahead): D33.
        let now = clock.now()
        for entry in entries {
            switch NightscoutEntryMapper.map(entry, now: now) {
            case .reading(let reading): readingsByID[reading.id] = reading
            case .skipped(let reason): checkpoint.skipped[reason, default: 0] += 1
            }
        }
        if !readingsByID.isEmpty {
            let readings = readingsByID.values.sorted { $0.date < $1.date }
            do {
                let stored = try await repository.insert(readings)
                checkpoint.readingsImported += stored.count
                checkpoint.readingsSkippedByStore += readings.count - stored.count
            } catch {
                throw NightscoutImportError.repository(String(describing: error))
            }
        }
        checkpoint.completedDownTo = lower
        if let planStart = checkpoint.planStart, lower <= planStart {
            checkpoint.isFinished = true
            return
        }

        // "Everything": after an empty window, jump over the gap to the newest older entry, or stop
        // when there is none. The probe proves `[newest + 1 ms, lower)` holds no sgv entries.
        if checkpoint.planStart == nil, entries.isEmpty {
            let newest: NightscoutEntry?
            do {
                newest = try await client.newestSGVEntry(beforeMs: milliseconds(lower))
            } catch {
                throw NightscoutImportError.nightscout(error)
            }
            guard let newest else {
                checkpoint.isFinished = true
                return
            }
            // The probe asked for `date < lower`; an answer without such a numeric date breaks
            // that contract. Stop loudly (the checkpoint keeps what finished) rather than guess.
            let lowerMs = Double(milliseconds(lower))
            guard let newestMs = newest.date, newestMs.isFinite, newestMs > 0, newestMs < lowerMs else {
                throw NightscoutImportError.nightscout(.malformedResponse("the newest older entry has no usable date below the requested bound"))
            }
            checkpoint.completedDownTo = Date(timeIntervalSince1970: (newestMs.rounded(.down) + 1) / 1000)
        }
    }

    /// All sgv entries with `lowerMs <= date < upperMs`. Nightscout returns newest first and at most
    /// `count`, so a full page means there may be more below its oldest entry: the next page ends
    /// just after that oldest `date` (inclusive of it, so entries sharing that millisecond are not
    /// lost; the repeats are removed by `_id` here and by reading id in the repository).
    private func fetchWindow(lowerMs: Int64, upperMs: Int64) async throws -> [NightscoutEntry] {
        var entries: [NightscoutEntry] = []
        var seenIDs: Set<String> = []
        var pageUpperMs = upperMs
        while true {
            let page: [NightscoutEntry]
            do {
                page = try await client.sgvEntries(lowerMs: lowerMs, upperMs: pageUpperMs, count: pageSize)
            } catch {
                throw NightscoutImportError.nightscout(error)
            }
            for entry in page {
                if let id = entry.id {
                    guard seenIDs.insert(id).inserted else { continue }
                }
                entries.append(entry)
            }
            guard page.count >= pageSize else { return entries }
            // Paging only trusts dates inside the window it asked for: a malformed `date` (NaN,
            // ±inf, 1e300, negative, text) is skipped by the mapper and never reaches the Int64
            // conversion below, which is therefore always in range (fail closed, never trap).
            let inWindow = page.compactMap(\.date).filter { $0.isFinite && $0 >= Double(lowerMs) && $0 < Double(pageUpperMs) }
            guard let oldest = inWindow.min() else {
                throw NightscoutImportError.nightscout(.malformedResponse("a full page without a date inside the requested range"))
            }
            let nextUpperMs = Int64(oldest.rounded(.down)) + 1
            guard nextUpperMs < pageUpperMs else { throw NightscoutImportError.pageTooDense(atMilliseconds: nextUpperMs - 1) }
            pageUpperMs = nextUpperMs
        }
    }

    // MARK: - Helpers

    private func save(_ checkpoint: NightscoutImportCheckpoint) async throws {
        do {
            try await checkpoints.saveCheckpoint(checkpoint)
        } catch {
            throw NightscoutImportError.checkpoint(String(describing: error))
        }
    }

    private func milliseconds(_ date: Date) -> Int64 {
        GlucoseReading.epochMilliseconds(date)
    }

    private func record(_ message: String) {
        log.record(DiagnosticEvent(date: clock.now(), category: .importer, message: message))
    }
}
