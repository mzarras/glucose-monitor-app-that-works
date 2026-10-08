// Original to Sensor (no ported code).
// In-process transports and a hand-moved clock. No test touches the network or sleeps.

import Foundation
@testable import ForecastKit

/// Answers from a queue and records every request.
actor MockForecastTransport: ForecastTransport {
    private var replies: [Result<ForecastHTTPResponse, ForecastTransportError>]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Result<ForecastHTTPResponse, ForecastTransportError>] = []) {
        self.replies = replies
    }

    func send(_ request: URLRequest) async throws(ForecastTransportError) -> ForecastHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw ForecastTransportError(message: "test bug: no reply queued") }
        return try replies.removeFirst().get()
    }

    /// `If-None-Match` of each request so far (nil where it was unconditional).
    func ifNoneMatchHeaders() -> [String?] {
        requests.map { $0.value(forHTTPHeaderField: "If-None-Match") }
    }

    static func ok(_ body: Data, eTag: String? = nil) -> Result<ForecastHTTPResponse, ForecastTransportError> {
        .success(ForecastHTTPResponse(statusCode: 200, eTag: eTag, body: body))
    }

    static func status(_ code: Int, eTag: String? = nil) -> Result<ForecastHTTPResponse, ForecastTransportError> {
        .success(ForecastHTTPResponse(statusCode: code, eTag: eTag, body: Data()))
    }

    static func offline() -> Result<ForecastHTTPResponse, ForecastTransportError> {
        .failure(ForecastTransportError(message: "The Internet connection appears to be offline."))
    }
}

/// Holds every request until the test answers it, in any order (the overlap scenario of the
/// review of 79c2c40, m1). Records the most requests that were ever outstanding at once.
actor GatedTransport: ForecastTransport {
    private var waiting: [Int: CheckedContinuation<ForecastHTTPResponse, Never>] = [:]
    private(set) var requests: [URLRequest] = []
    private(set) var mostOutstanding = 0

    /// `If-None-Match` of each request, in the order sent (nil = unconditional).
    var sent: [String?] { requests.map { $0.value(forHTTPHeaderField: "If-None-Match") } }

    func send(_ request: URLRequest) async throws(ForecastTransportError) -> ForecastHTTPResponse {
        let index = requests.count
        requests.append(request)
        return await withCheckedContinuation { continuation in
            waiting[index] = continuation
            mostOutstanding = max(mostOutstanding, waiting.count)
        }
    }

    func answer(_ index: Int, with response: ForecastHTTPResponse) {
        waiting.removeValue(forKey: index)?.resume(returning: response)
    }

    /// Answers every outstanding request, newest first and one at a time, including requests sent
    /// meanwhile, until none has appeared for a while. `respond` gets the request and how many
    /// were answered before it. Nothing is left waiting, so a client bug fails a test instead of
    /// hanging it.
    func answerAll(_ respond: @Sendable (_ request: URLRequest, _ answeredBefore: Int) -> ForecastHTTPResponse) async {
        var answered = 0
        while true {
            for _ in 0..<200 { await Task.yield() }
            guard let index = waiting.keys.max() else { return }
            let response = respond(requests[index], answered)
            answered += 1
            answer(index, with: response)
        }
    }

    /// Waits (yielding, never sleeping) until `count` requests have been sent.
    func waitUntilSent(_ count: Int) async {
        while requests.count < count { await Task.yield() }
    }
}

/// Never answers; returns only once its task is cancelled, and then fails with a plain transport
/// error (not flagged as a cancellation), as a transport that knows nothing of cancellation would.
actor HangingTransport: ForecastTransport {
    private(set) var started = 0

    func send(_ request: URLRequest) async throws(ForecastTransportError) -> ForecastHTTPResponse {
        started += 1
        while !Task.isCancelled { await Task.yield() }
        throw ForecastTransportError(message: "stopped waiting")
    }

    func waitUntilStarted() async {
        while started == 0 { await Task.yield() }
    }
}

/// Both clocks, moved by hand.
///
/// `@unchecked Sendable`: the client reads it on its own executor while the test moves it; the one
/// mutable field is only ever accessed under `lock`.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ForecastInstant

    init(_ start: ForecastInstant) { current = start }

    var now: ForecastInstant {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Real time passes: both clocks move forward by `seconds`.
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = ForecastInstant(wall: current.wall.addingTimeInterval(seconds), monotonic: current.monotonic + seconds)
    }

    /// The phone's clock is changed by `seconds` (negative = set back); no real time passes.
    func changeWallClock(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = ForecastInstant(wall: current.wall.addingTimeInterval(seconds), monotonic: current.monotonic)
    }
}
