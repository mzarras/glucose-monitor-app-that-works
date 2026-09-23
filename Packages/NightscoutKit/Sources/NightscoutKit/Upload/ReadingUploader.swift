// Uploads live sensor readings to one destination (Nightscout or Dexcom Share) with a persistent
// queue, retry with backoff, and a status for Settings and the S5 banner (HANDOFF §8A).
//
// This is the only way readings reach an uploader, so the S2/S6 gate lives here, once:
// `submit` calls `LiveReadingGate.validate` immediately before queueing and refuses anything it
// rejects (non-`.sensor` sources, no/malformed session, warm-up, expired, future, implausible
// value). Replay/mock/imported readings can never be queued. The DEBUG replay-accepting gate
// variant is not used here (PROGRESS D11: uploaders never accept replay).
//
// Driving it (app wiring):
//   - For each reading the repository newly stored (`insert`'s return value), call
//     `submit(_:session:)` with the source's `currentSession`, then `flushIfDue()`.
//   - Call `flushIfDue()` when the app comes to the foreground or gets background time.
//   - "Retry now": `flush()`.
//   - After saving new credentials: `credentialsChanged()`, then `flush()`.
//   - `flush()`/`flushIfDue()` return `.alreadyFlushing` while another flush is running; that flush
//     may still be using the old credentials or may have taken its batch before a new reading was
//     queued, so call `flush()` again once it has finished (e.g. after awaiting the status stream
//     or on the next reading).
//   - Exactly one `ReadingUploader` per queue file per process; `init` throws `QueueFileInUse` for
//     a second one (two owners would each rewrite the file from their own memory and lose readings).

import Foundation
import GlucoseCore

/// Why `submit` refused a reading. Nothing refused is ever queued.
public enum UploadRefusal: Error, Sendable, Equatable {
    /// S2/S6: `LiveReadingGate` rejected it.
    case gate(LiveReadingGate.Rejection)
    /// S4: the destination has no faithful representation for this value.
    case notRepresentable(GlucoseValue)
}

/// Another live `ReadingUploader` in this process already owns the queue file.
public struct QueueFileInUse: Error, Sendable, Equatable {
    public let path: String
}

/// Process-wide set of queue files owned by a live `ReadingUploader`.
final class QueueFileRegistry: @unchecked Sendable {
    // @unchecked Sendable: `claimed` is only read and written while holding `lock`.
    static let shared = QueueFileRegistry()
    private let lock = NSLock()
    private var claimed: Set<String> = []

    /// True if `path` was free and is now claimed.
    func claim(_ path: String) -> Bool {
        lock.withLock { claimed.insert(path).inserted }
    }

    func release(_ path: String) {
        _ = lock.withLock { claimed.remove(path) }
    }
}

public enum FlushOutcome: Sendable, Equatable {
    case nothingQueued
    /// Another flush is running. It sends the batches it takes, but may use old credentials or
    /// miss a reading queued after it started: call `flush()` again when it has finished.
    case alreadyFlushing
    /// Backing off after a failure; `flushIfDue` does nothing until then.
    case deferred(until: Date)
    case uploaded(count: Int)
    /// The attempt failed; the readings stay queued. Earlier batches in the same flush may have
    /// succeeded (`uploadedBeforeFailure`).
    case failed(UploadError, uploadedBeforeFailure: Int)
}

public actor ReadingUploader {
    public nonisolated let destinationName: String
    private let destination: any UploadDestination
    private let retryPolicy: RetryPolicy
    private let clock: any WallClock
    private let log: any DiagnosticLog
    private var queue: PersistentReadingQueue
    private var currentStatus: UploadStatus
    private var isFlushing = false
    private var observers: [UUID: AsyncStream<UploadStatus>.Continuation] = [:]
    private nonisolated let queuePath: String

    /// - Parameter queueFile: where queued readings persist (one file per destination).
    /// - Throws: `QueueFileInUse` if another live uploader in this process owns `queueFile`.
    public init(
        destination: any UploadDestination,
        queueFile: URL,
        retryPolicy: RetryPolicy = .default,
        clock: any WallClock = SystemWallClock(),
        log: any DiagnosticLog = NullDiagnosticLog()
    ) throws(QueueFileInUse) {
        let path = queueFile.standardizedFileURL.resolvingSymlinksInPath().path
        guard QueueFileRegistry.shared.claim(path) else { throw QueueFileInUse(path: path) }
        self.queuePath = path
        self.destinationName = destination.name
        self.destination = destination
        self.retryPolicy = retryPolicy
        self.clock = clock
        self.log = log
        let loaded = PersistentReadingQueue.load(fileURL: queueFile, now: clock.now())
        self.queue = loaded.queue
        var status = UploadStatus(destination: destination.name)
        status.lastSuccessAt = loaded.queue.lastSuccessAt
        status.queueDepth = loaded.queue.count
        status.queueLoadProblem = loaded.problem
        // Persisted retry state: the S5 banner and the backoff survive a relaunch.
        status.consecutiveFailures = loaded.queue.retry.consecutiveFailures
        status.nextAttemptAt = loaded.queue.retry.nextAttemptAt
        status.lastError = loaded.queue.retry.lastError
        status.lastErrorAt = loaded.queue.retry.lastErrorAt
        self.currentStatus = status
        if let problem = loaded.problem {
            log.record(DiagnosticEvent(date: clock.now(), category: .upload, message: "\(destination.name): \(problem)"))
        }
    }

    deinit {
        QueueFileRegistry.shared.release(queuePath)
    }

    public var status: UploadStatus { currentStatus }

    /// Current status, then every change. Any number of observers.
    public func statusUpdates() -> AsyncStream<UploadStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: UploadStatus.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(currentStatus)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    // MARK: - Submit

    /// Validates `reading` against `session` (S2/S6) and the destination's representation (S4),
    /// then queues it. Idempotent: a reading already queued (same id) is not queued twice.
    public func submit(_ reading: GlucoseReading, session: SensorSession?) throws(UploadRefusal) {
        let now = clock.now()
        do {
            try LiveReadingGate.validate(reading, session: session, now: now)
        } catch {
            currentStatus.refusedByGate += 1
            recordRefusal(.gate(error), at: now)
            record("refused reading \(reading.id) (\(reading.source)): \(error)")
            publish()
            throw .gate(error)
        }
        guard destination.canRepresent(reading.value) else {
            currentStatus.notRepresentable += 1
            recordRefusal(.notRepresentable(reading.value), at: now)
            record("not uploading reading \(reading.id): \(reading.value) has no faithful representation here")
            publish()
            throw .notRepresentable(reading.value)
        }
        let result = queue.append(reading, at: now)
        if !result.dropped.isEmpty {
            currentStatus.discarded += result.dropped.count
            record("queue over capacity: dropped \(result.dropped.count) oldest readings")
        }
        if result.appended { persist() }
        publish()
    }

    // MARK: - Credentials

    /// Call after the user saves new credentials: forgets any cached login (Share session) and the
    /// backoff, so the next `flush()` uses the new credentials at once. See the file comment about
    /// `.alreadyFlushing`.
    public func credentialsChanged() async {
        await destination.resetSession()
        currentStatus.nextAttemptAt = nil
        queue.retry.nextAttemptAt = nil
        persist()
        record("credentials changed; cached login and backoff cleared")
        publish()
    }

    // MARK: - Flush

    /// Uploads queued readings unless backing off after a failure.
    @discardableResult
    public func flushIfDue() async -> FlushOutcome {
        await flush(respectingBackoff: true)
    }

    /// Uploads queued readings now, ignoring backoff.
    @discardableResult
    public func flush() async -> FlushOutcome {
        await flush(respectingBackoff: false)
    }

    private func flush(respectingBackoff: Bool) async -> FlushOutcome {
        guard !isFlushing else { return .alreadyFlushing }
        let startedAt = clock.now()
        if respectingBackoff, let next = currentStatus.nextAttemptAt, startedAt < next {
            return .deferred(until: next)
        }
        isFlushing = true
        defer { isFlushing = false }

        discardUnsendable(now: startedAt)
        var uploaded = 0
        while true {
            let batch = queue.items.prefix(max(1, destination.maxBatchSize)).map(\.reading)
            guard !batch.isEmpty else { break }
            currentStatus.lastAttemptAt = clock.now()
            do {
                try await destination.upload(batch)
            } catch {
                recordFailure(error)
                publish()
                return .failed(error, uploadedBeforeFailure: uploaded)
            }
            // `submit` may have appended while we awaited; remove exactly what was sent.
            let sent = Set(batch.map(\.id))
            let removed = queue.removeAll { sent.contains($0.reading.id) }
            // Cannot happen (only this flush removes items and flushes do not overlap); guards
            // against ever re-sending the same batch in a loop.
            guard !removed.isEmpty else { break }
            let now = clock.now()
            if currentStatus.consecutiveFailures > 0 {
                record("recovered after \(currentStatus.consecutiveFailures) failed attempts")
            }
            queue.recordSuccess(at: now)
            // Keep the last error for Settings; clear what makes the status "failing".
            queue.retry.consecutiveFailures = 0
            queue.retry.nextAttemptAt = nil
            persist()
            uploaded += batch.count
            currentStatus.lastSuccessAt = now
            currentStatus.consecutiveFailures = 0
            currentStatus.nextAttemptAt = nil
            currentStatus.refusalsSinceLastSuccess = 0
            publish()
        }
        return uploaded == 0 ? .nothingQueued : .uploaded(count: uploaded)
    }

    /// Drops queued readings that must not or cannot be sent, each counted and logged:
    /// not `.sensor` (only possible if the queue file was altered; S6 defence in depth), not
    /// representable by this destination (S4), or older than the destination accepts.
    private func discardUnsendable(now: Date) {
        let notLive = queue.removeAll { !$0.reading.source.isLiveSensor }
        let unrepresentable = queue.removeAll { !destination.canRepresent($0.reading.value) }
        var expired: [PersistentReadingQueue.Item] = []
        if let maxAge = destination.maxReadingAge {
            expired = queue.removeAll { now.timeIntervalSince($0.reading.date) > maxAge }
        }
        if !notLive.isEmpty { record("discarded \(notLive.count) queued non-sensor readings (S6)") }
        if !unrepresentable.isEmpty { record("discarded \(unrepresentable.count) queued readings with no faithful representation (S4)") }
        if !expired.isEmpty { record("discarded \(expired.count) queued readings older than this destination accepts") }
        let count = notLive.count + unrepresentable.count + expired.count
        guard count > 0 else { return }
        currentStatus.discarded += count
        persist()
        publish()
    }

    // MARK: - Helpers

    private func recordFailure(_ error: UploadError) {
        let now = clock.now()
        currentStatus.consecutiveFailures += 1
        currentStatus.totalFailures += 1
        currentStatus.lastError = error
        currentStatus.lastErrorAt = now
        let delay = retryPolicy.delay(afterConsecutiveFailures: currentStatus.consecutiveFailures, kind: error.kind)
        currentStatus.nextAttemptAt = now.addingTimeInterval(delay)
        queue.retry = PersistentReadingQueue.RetryState(
            consecutiveFailures: currentStatus.consecutiveFailures,
            nextAttemptAt: currentStatus.nextAttemptAt,
            lastError: error,
            lastErrorAt: now
        )
        persist()
        record("upload failed (\(currentStatus.consecutiveFailures) in a row, \(queue.count) queued, retry in \(Int(delay)) s): \(error)")
    }

    private func recordRefusal(_ refusal: UploadRefusal, at date: Date) {
        currentStatus.lastRefusal = refusal
        currentStatus.lastRefusedAt = date
        currentStatus.refusalsSinceLastSuccess += 1
    }

    private func persist() {
        do {
            try queue.save()
            currentStatus.queueSaveProblem = nil
        } catch {
            let problem = "Upload queue could not be saved: \(error.localizedDescription)"
            if currentStatus.queueSaveProblem == nil { record(problem) }
            currentStatus.queueSaveProblem = problem
        }
    }

    private func publish() {
        currentStatus.queueDepth = queue.count
        for continuation in observers.values { continuation.yield(currentStatus) }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func record(_ message: String) {
        log.record(DiagnosticEvent(date: clock.now(), category: .upload, message: "\(destinationName): \(message)"))
    }
}
