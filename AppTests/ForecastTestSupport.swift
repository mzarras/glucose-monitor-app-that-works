// Doubles for the D57 forecast tests: an in-process feed transport (no network), a sleeper the test
// steps by hand (no waiting), and documents built with the app's fixture builder.

import ForecastKit
import Foundation
@testable import Sensor

/// Answers latest.json and metrics.json from queues (or a default), records every request, and can
/// hold the next request until the test releases it.
actor FakeForecastTransport: ForecastTransport {
    typealias Reply = Result<ForecastHTTPResponse, ForecastTransportError>

    private(set) var requests: [URLRequest] = []
    private var latestReplies: [Reply] = []
    private var metricsReplies: [Reply] = []
    /// Used when the queue for that document is empty.
    private var defaultLatest: Reply
    private var defaultMetrics: Reply
    /// Requests still to hold, in order: `true` = the hold ends when the request's task is cancelled
    /// (as URLSession does), `false` = it waits for `release()` whatever happens (an answer already
    /// on its way when the app stopped asking).
    private var holdsWanted: [Bool] = []
    /// Held requests, oldest first; resumed with true (released) or false (cancelled).
    private var held: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    private var cancelledEarly: Set<UUID> = []
    private var cancelRemaining = 0

    init(latest: Reply, metrics: Reply) {
        defaultLatest = latest
        defaultMetrics = metrics
    }

    /// "latest.json", "metrics.json", … in order.
    var paths: [String] { requests.map { $0.url?.lastPathComponent ?? "?" } }
    var hosts: [String] { requests.map { $0.url?.host() ?? "?" } }
    var count: Int { requests.count }
    var isHolding: Bool { !held.isEmpty }
    var heldCount: Int { held.count }

    func setDefaultLatest(_ reply: Reply) { defaultLatest = reply }
    func enqueueLatest(_ reply: Reply) { latestReplies.append(reply) }
    func enqueueMetrics(_ reply: Reply) { metricsReplies.append(reply) }

    /// The next `count` latest.json requests end cancelled, as when the system cancels a request:
    /// the transport cancels the task it runs in and fails, which ForecastKit reports as
    /// `ForecastFeedError.cancelled` ("another transport signals cancellation by throwing while its
    /// task is cancelled"). The app's own polling task is not cancelled.
    func cancelNextLatestRequests(_ count: Int) { cancelRemaining = count }

    /// The next request waits in `send` until `release()` (the oldest held one first). With
    /// `cancellable`, cancelling its task ends it at once with a cancellation, like URLSession.
    func holdNextRequest(cancellable: Bool = false) { holdsWanted.append(cancellable) }
    func release() {
        guard !held.isEmpty else { return }
        held.removeFirst().continuation.resume(returning: true)
    }

    private func cancelHeld(_ id: UUID) {
        guard let index = held.firstIndex(where: { $0.id == id }) else {
            cancelledEarly.insert(id)
            return
        }
        held.remove(at: index).continuation.resume(returning: false)
    }

    private func hold(cancellable: Bool) async -> Bool {
        let id = UUID()
        let wait = { (continuation: CheckedContinuation<Bool, Never>) in
            if self.cancelledEarly.remove(id) != nil {
                continuation.resume(returning: false)
            } else {
                self.held.append((id, continuation))
            }
        }
        guard cancellable else { return await withCheckedContinuation(wait) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation(wait)
        } onCancel: {
            Task { await self.cancelHeld(id) }
        }
    }

    func send(_ request: URLRequest) async throws(ForecastTransportError) -> ForecastHTTPResponse {
        requests.append(request)
        if !holdsWanted.isEmpty, !(await hold(cancellable: holdsWanted.removeFirst())) {
            // Cancelled while held: fail while the task is cancelled, which ForecastKit reports as
            // `.cancelled` (what URLSession's URLError.cancelled becomes).
            throw ForecastTransportError(message: "cancelled")
        }
        if request.url?.lastPathComponent == "latest.json", cancelRemaining > 0 {
            cancelRemaining -= 1
            withUnsafeCurrentTask { $0?.cancel() }
            throw ForecastTransportError(message: "cancelled")
        }
        let reply: Reply
        if request.url?.lastPathComponent == "metrics.json" {
            reply = metricsReplies.isEmpty ? defaultMetrics : metricsReplies.removeFirst()
        } else {
            reply = latestReplies.isEmpty ? defaultLatest : latestReplies.removeFirst()
        }
        return try reply.get()
    }

    static func ok(_ body: Data) -> Reply {
        .success(ForecastHTTPResponse(statusCode: 200, eTag: nil, body: body))
    }

    static func offline() -> Reply {
        .failure(ForecastTransportError(message: "The Internet connection appears to be offline."))
    }
}

/// Stands in for `Task.sleep` between polls: records each requested delay and suspends until the test
/// calls `wake()`; a cancelled sleeper throws, as `Task.sleep` does.
@MainActor
final class ManualSleeper {
    private(set) var requested: [TimeInterval] = []
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
    private var cancelledEarly: Set<UUID> = []

    var sleeping: Int { waiting.count }

    func sleep(_ seconds: TimeInterval) async throws {
        requested.append(seconds)
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if cancelledEarly.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    /// Ends every current sleep (the poll interval elapsed).
    func wake() {
        let sleepers = waiting
        waiting = []
        for sleeper in sleepers { sleeper.continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else {
            cancelledEarly.insert(id)
            return
        }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

enum ForecastTestDocuments {
    static let host = "zen.example.com"

    /// latest.json with a Zen run at `generatedAt`, published 30 s after it.
    static func latest(run generatedAt: Date, zen: [Int: Double] = ForecastFixtureDocuments.zen,
                       oref: [Int: Double]? = ForecastFixtureDocuments.oref) -> Data {
        ForecastFixtureDocuments.latest(asOf: generatedAt.addingTimeInterval(30), generatedAt: generatedAt, zen: zen, oref: oref)
    }

    /// Decoded at `now` as the app decodes the real feed.
    static func decodedLatest(run generatedAt: Date?, zen: [Int: Double]? = ForecastFixtureDocuments.zen,
                              oref: [Int: Double]? = ForecastFixtureDocuments.oref, feedGlucose: Int? = 105, now: Date) -> LatestForecast? {
        // Published 30 s after the run (never after `now`), or a minute ago when there is no run.
        let asOf = generatedAt.map { min($0.addingTimeInterval(30), now) } ?? now.addingTimeInterval(-60)
        return ForecastFixtureDocuments.decodedLatest(asOf: asOf, generatedAt: generatedAt, zen: zen, oref: oref, feedGlucose: feedGlucose,
                                                      at: ForecastFixtureDocuments.instant(now))
    }

    static func accuracy(now: Date) -> ForecastAccuracy? {
        ForecastFixtureDocuments.decodedAccuracy(asOf: now.addingTimeInterval(-600), at: ForecastFixtureDocuments.instant(now))
    }

    /// A status with predictions on and `latest`/`accuracy` held, as the service leaves it.
    static func status(latest: LatestForecast?, accuracy: ForecastAccuracy? = nil, failures: Int = 0, error: String? = nil) -> ForecastStatus {
        var status = ForecastStatus(setup: .on(host: host), buildHost: host)
        status.latest = latest
        status.accuracy = accuracy
        status.consecutiveFailures = failures
        status.lastError = error
        return status
    }
}
