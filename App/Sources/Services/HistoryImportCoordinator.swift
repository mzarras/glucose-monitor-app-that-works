// Runs one history import at a time (HANDOFF §4.5; docs/import.md) and keeps its progress for the
// onboarding and Settings screens. Imported readings go to the store only — never to the pipeline,
// Trio, alerts or uploads (S6): the importers write through `GlucoseReadingRepository.insert`
// directly, and the store's change notification refreshes charts.

import Foundation
import GlucoseCore
import NightscoutKit

@MainActor
final class HistoryImportCoordinator {
    private(set) var state: HistoryImportState?
    /// Called after every change of `state`; `finished` is true once the import ended (any way).
    var onChange: (@MainActor (_ state: HistoryImportState, _ finished: Bool) -> Void)?

    private var task: Task<Void, Never>?
    private let diagnostics: any DiagnosticLog

    init(diagnostics: any DiagnosticLog) {
        self.diagnostics = diagnostics
    }

    /// The last finished import from an earlier launch (shown until a new one starts).
    func restore(_ last: HistoryImportState) {
        guard state == nil else { return }
        state = last
    }

    /// An import that could not start (store not open, no site); shown like a failed import.
    func fail(origin: ImportOrigin, message: String) {
        guard !isRunning else { return }
        begin(origin)
        finish(.failed(message: message))
    }

    var isRunning: Bool { state?.isRunning ?? false }

    // MARK: - Nightscout

    func startNightscout(
        site: NightscoutSite,
        credentials: any CredentialStore,
        repository: any GlucoseReadingRepository,
        checkpoints: any NightscoutImportCheckpointStore,
        scope: NightscoutImportScope,
        transport: any HTTPTransport
    ) {
        guard !isRunning else { return }
        let importer = NightscoutHistoryImporter(
            site: site, credentials: credentials, repository: repository, checkpoints: checkpoints,
            transport: transport, log: diagnostics
        )
        begin(.nightscout)
        task = Task { [weak self] in
            do {
                for try await progress in importer.progressStream(scope: scope) {
                    self?.note(progress)
                }
                self?.finish(.finished)
            } catch is CancellationError {
                self?.finish(.cancelled)
            } catch {
                self?.finish(Task.isCancelled ? .cancelled : .failed(message: String(describing: error)))
            }
        }
    }

    private func note(_ progress: NightscoutImportProgress) {
        guard var current = state else { return }
        current.readingsImported = progress.readingsImported
        current.readingsSkippedByStore = progress.readingsSkippedByStore
        current.coveredFrom = progress.coveredFrom
        current.coveredTo = progress.coveredTo
        current.skipped = Dictionary(uniqueKeysWithValues: progress.skipped.map { ($0.key.rawValue, $0.value) })
        // PROGRESS must-do: show skipped[.futureDated].
        current.rejectedFutureDated = progress.skipped[.futureDated] ?? 0
        publish(current, finished: false)
    }

    // MARK: - Clarity CSV

    func startClarity(data: Data, timeZone: TimeZone, repository: any GlucoseReadingRepository) {
        guard !isRunning else { return }
        let importer = ClarityHistoryImporter(repository: repository, log: diagnostics)
        begin(.clarityCSV)
        let (updates, continuation) = AsyncStream.makeStream(of: ClarityImportProgress.self, bufferingPolicy: .unbounded)
        let progressTask = Task { [weak self] in
            for await progress in updates {
                self?.note(progress)
            }
        }
        task = Task { [weak self] in
            do throws(ClarityImportError) {
                let result = try await importer.importExport(data, timeZone: timeZone) { continuation.yield($0) }
                continuation.finish()
                await progressTask.value
                self?.note(result)
                self?.finish(.finished)
            } catch {
                continuation.finish()
                await progressTask.value
                self?.finish(Task.isCancelled ? .cancelled : .failed(message: error.description))
            }
        }
    }

    private func note(_ progress: ClarityImportProgress) {
        guard var current = state else { return }
        current.readingsImported = progress.readingsImported
        current.readingsSkippedByStore = progress.readingsSkippedByStore
        current.coveredFrom = progress.coveredFrom
        current.coveredTo = progress.coveredTo
        publish(current, finished: false)
    }

    private func note(_ result: ClarityImportResult) {
        guard var current = state else { return }
        current.readingsImported = result.readingsImported
        current.readingsSkippedByStore = result.readingsSkippedByStore
        current.coveredFrom = result.coveredFrom
        current.coveredTo = result.coveredTo
        let parse = result.parse
        current.skipped = [
            "ignoredRows": parse.ignoredRows,
            "duplicateRows": parse.duplicateRows,
            "rejectedNonexistentLocalTime": parse.rejectedNonexistentLocalTime,
            "rejectedAmbiguousLocalTime": parse.rejectedAmbiguousLocalTime,
            "rejectedInvalidTimestamp": parse.rejectedInvalidTimestamp,
            "rejectedInvalidValue": parse.rejectedInvalidValue,
            "rejectedFutureDated": parse.rejectedFutureDated,
        ].filter { $0.value > 0 }
        // PROGRESS must-do: show rejectedFutureDated.
        current.rejectedFutureDated = parse.rejectedFutureDated
        publish(current, finished: false)
    }

    // MARK: - Common

    func cancel() {
        task?.cancel()
    }

    private func begin(_ origin: ImportOrigin) {
        publish(HistoryImportState(
            origin: origin, phase: .running, readingsImported: 0, readingsSkippedByStore: 0, coveredFrom: nil, coveredTo: nil,
            skipped: [:], rejectedFutureDated: 0, startedAt: Date(), finishedAt: nil
        ), finished: false)
    }

    private func finish(_ phase: HistoryImportState.Phase) {
        guard var current = state else { return }
        current.phase = phase
        current.finishedAt = Date()
        task = nil
        diagnostics.record(DiagnosticEvent(
            date: Date(), category: .importer,
            message: "\(current.origin.rawValue) import ended (\(phase)): \(current.readingsImported) stored, \(current.readingsSkippedByStore) skipped by the store, \(current.rejectedFutureDated) future-dated"
        ))
        publish(current, finished: true)
    }

    private func publish(_ newState: HistoryImportState, finished: Bool) {
        state = newState
        onChange?(newState, finished)
    }
}
