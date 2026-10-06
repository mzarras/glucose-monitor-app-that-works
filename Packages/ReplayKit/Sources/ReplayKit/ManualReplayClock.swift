// Replay time moved by hand. DEBUG only (S6): this whole file is compiled out of Release.
#if DEBUG
import Foundation

/// Virtual time that moves only when `advance` is called. Lets a test play part of a timeline,
/// stop the source, check what was delivered, and continue — without ever sleeping.
public actor ManualReplayClock: ReplayClock {
    private struct Waiter {
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var current: Date
    private var waiters: [Int: Waiter] = [:]
    private var nextWaiterID = 0

    public init(start: Date) {
        current = start
    }

    public func now() -> Date {
        current
    }

    public func sleep(until deadline: Date) async throws {
        try Task.checkCancellation()
        guard deadline > current else { return }
        let id = nextWaiterID
        nextWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Cancelled between checkCancellation and here: the onCancel task below may have
                // run already and found nothing to cancel, so resume now.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Moves time forward to `date` and wakes every sleeper whose deadline has been reached, in
    /// deadline order. Moving backwards is ignored.
    public func advance(to date: Date) {
        guard date > current else { return }
        current = date
        let due = waiters
            .filter { $0.value.deadline <= date }
            .sorted { ($0.value.deadline, $0.key) < ($1.value.deadline, $1.key) }
        for (id, waiter) in due {
            waiters[id] = nil
            waiter.continuation.resume()
        }
    }

    public func advance(by interval: TimeInterval) {
        advance(to: current.addingTimeInterval(interval))
    }

    private func cancelWaiter(_ id: Int) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}
#endif
