// `changes()` plumbing: a GRDB transaction observer notices committed writes that changed the
// `reading` table and a broadcaster fans that out to every AsyncStream handed out by `changes()`.

import GRDB
import os

/// Fans one "rows changed" signal out to every live `changes()` stream.
final class ChangeBroadcaster: Sendable {
    private struct State {
        var nextKey: UInt64 = 0
        /// Continuations of the streams still being consumed, keyed so a terminated stream can
        /// remove itself.
        var continuations: [UInt64: AsyncStream<Void>.Continuation] = [:]
    }

    /// OSAllocatedUnfairLock (iOS 16+/macOS 13+) keeps this class Sendable without @unchecked.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A new stream. Unbounded buffer: the contract says one element per committed write, and
    /// elements are `Void`, so a slow consumer costs almost nothing.
    func makeStream() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
        let key = state.withLock { state in
            state.nextKey += 1
            state.continuations[state.nextKey] = continuation
            return state.nextKey
        }
        continuation.onTermination = { [weak self] _ in
            self?.removeContinuation(key)
        }
        return stream
    }

    func broadcast() {
        let current = state.withLock { Array($0.continuations.values) }
        for continuation in current {
            continuation.yield()
        }
    }

    /// Ends every stream (the store is going away).
    func finishAll() {
        let current = state.withLock { state in
            let values = Array(state.continuations.values)
            state.continuations.removeAll()
            return values
        }
        // Outside the lock: finish() runs onTermination, which takes the lock again.
        for continuation in current {
            continuation.finish()
        }
    }

    private func removeContinuation(_ key: UInt64) {
        state.withLock { _ = $0.continuations.removeValue(forKey: key) }
    }
}

/// Calls `onCommitWithChanges` after each committed transaction that inserted, updated or deleted
/// at least one row of the `reading` table. Transactions that changed nothing (for example an
/// insert whose every id already existed: `ON CONFLICT DO NOTHING` fires no update hook) and
/// rolled-back transactions are not reported.
///
/// GRDB calls every method on its writer queue, one transaction at a time, so the mutable flag
/// needs no lock. The class is not Sendable and is only ever touched by GRDB.
final class ReadingTableObserver: TransactionObserver {
    private let onCommitWithChanges: @Sendable () -> Void
    private var changedInCurrentTransaction = false

    init(onCommitWithChanges: @escaping @Sendable () -> Void) {
        self.onCommitWithChanges = onCommitWithChanges
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        eventKind.tableName == StoreSchema.readingTable
    }

    func databaseDidChange(with event: DatabaseEvent) {
        changedInCurrentTransaction = true
        // One change is enough to know; skip the per-row callbacks for the rest of the transaction.
        stopObservingDatabaseChangesUntilNextTransaction()
    }

    func databaseDidCommit(_ db: Database) {
        guard changedInCurrentTransaction else { return }
        changedInCurrentTransaction = false
        onCommitWithChanges()
    }

    func databaseDidRollback(_ db: Database) {
        changedInCurrentTransaction = false
    }
}
