// Original to Sensor (no ported code).
// Fetches and validates the two feed documents. The app owns the timers (ForecastPolling) and
// decides what to keep in memory; this client keeps only the last validated document per URL
// with its ETag, so an unchanged document costs an empty 304.
//
// One request per URL at a time (review of 79c2c40, m1): a fetch that starts while another for the
// same URL is in flight waits for that one and gets its result. Without this, overlapping fetches
// could finish out of order and return (or remember) an older document after a newer one, or bring
// back a document after a later response had been rejected.

import Foundation

/// Why a fetch produced no value.
public enum ForecastFeedError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No usable HTTP response (offline, DNS, TLS, timeout, a body over
    /// `ForecastLimits.maximumResponseBytes`).
    case transport(ForecastTransportError)
    /// An HTTP status other than 2xx or 304 (including a refused redirect).
    case httpStatus(Int)
    /// A 304 arrived for a request the client sent without `If-None-Match`.
    case notModifiedWithoutCachedValue
    /// The document failed validation and was rejected whole.
    case invalidDocument(ForecastDocumentError)
    /// The request was cancelled (the caller's task was cancelled, or URLSession cancelled it).
    /// Not a failure: do not count it toward backoff and do not show it as an error.
    case cancelled

    public var description: String {
        switch self {
        case .transport(let error): return "Could not reach the forecast feed: \(error.message)"
        case .httpStatus(let status): return "The forecast feed answered HTTP \(status)."
        case .notModifiedWithoutCachedValue: return "The forecast feed answered 304 to an unconditional request."
        case .invalidDocument(let error): return "The forecast feed was rejected: \(error.description)"
        case .cancelled: return "The forecast request was cancelled."
        }
    }
}

/// Fetches latest.json and metrics.json from one feed host.
public actor ForecastFeedClient {
    public nonisolated let endpoint: ForecastFeedEndpoint
    private let transport: any ForecastTransport
    private let now: @Sendable () -> ForecastInstant

    /// The last document validated from a 2xx response, kept only while the server sent an ETag.
    private struct Remembered<Value: Sendable>: Sendable {
        let eTag: String
        let value: Value
    }
    private var latest: Remembered<LatestForecast>?
    private var accuracy: Remembered<ForecastAccuracy>?

    /// The fetch in flight for each URL, if any. Set when a fetch starts and cleared by that fetch
    /// as it finishes, so at most one request per URL is outstanding and the remembered document
    /// is read and written by one fetch at a time.
    private var latestInFlight: Task<Result<LatestForecast, ForecastFeedError>, Never>?
    private var accuracyInFlight: Task<Result<ForecastAccuracy, ForecastFeedError>, Never>?

    /// - Parameters:
    ///   - transport: `URLSessionForecastTransport()` in the app; a fake in tests.
    ///   - now: both clocks, read when a response arrives: the wall clock rejects future-dated
    ///     documents, and the instant stamps the document for `LatestForecast.zenFreshness(at:)`.
    public init(
        endpoint: ForecastFeedEndpoint,
        transport: any ForecastTransport = URLSessionForecastTransport(),
        now: @escaping @Sendable () -> ForecastInstant = { ForecastInstant.now() }
    ) {
        self.endpoint = endpoint
        self.transport = transport
        self.now = now
    }

    /// GETs latest.json. Show its forecast only through `LatestForecast.currentRun(at:)`.
    ///
    /// A 304 returns the document validated earlier from the same ETag **with its original receipt
    /// instant**: re-stamping it would restart its age from the phone's clock at the 304, so after
    /// the clock was set back the run would look younger again. Joins a fetch already in flight.
    /// If the calling task is cancelled the shared request is cancelled, and every caller waiting
    /// on it gets `.cancelled`.
    public func fetchLatest() async throws(ForecastFeedError) -> LatestForecast {
        let task: Task<Result<LatestForecast, ForecastFeedError>, Never>
        if let inFlight = latestInFlight {
            task = inFlight
        } else {
            task = Task { await self.fetchLatestNow() }
            latestInFlight = task
        }
        return try await result(of: task).get()
    }

    /// GETs metrics.json. A 304 returns the document validated earlier from the same ETag. Joins a
    /// fetch already in flight; cancellation as for `fetchLatest()`.
    public func fetchAccuracy() async throws(ForecastFeedError) -> ForecastAccuracy {
        let task: Task<Result<ForecastAccuracy, ForecastFeedError>, Never>
        if let inFlight = accuracyInFlight {
            task = inFlight
        } else {
            task = Task { await self.fetchAccuracyNow() }
            accuracyInFlight = task
        }
        return try await result(of: task).get()
    }

    /// The one latest.json request in flight. Runs on the actor between its awaits, and nothing
    /// else touches `latest` while it is in flight.
    private func fetchLatestNow() async -> Result<LatestForecast, ForecastFeedError> {
        defer { latestInFlight = nil }
        let request = Self.request(url: endpoint.latestURL, ifNoneMatch: latest?.eTag)
        let result = await fetch(request, remembered: latest?.value) { data, instant throws(ForecastDocumentError) in
            try ForecastFeedDecoder.decodeLatest(data, at: instant)
        }
        switch result {
        case .success(let (value, eTag)):
            latest = eTag.map { Remembered(eTag: $0, value: value) }
        case .failure(.invalidDocument):
            latest = nil
        case .failure:
            break
        }
        return result.map { $0.0 }
    }

    /// The one metrics.json request in flight; as `fetchLatestNow`.
    private func fetchAccuracyNow() async -> Result<ForecastAccuracy, ForecastFeedError> {
        defer { accuracyInFlight = nil }
        let request = Self.request(url: endpoint.metricsURL, ifNoneMatch: accuracy?.eTag)
        let result = await fetch(request, remembered: accuracy?.value) { data, instant throws(ForecastDocumentError) in
            try ForecastFeedDecoder.decodeAccuracy(data, at: instant)
        }
        switch result {
        case .success(let (value, eTag)):
            accuracy = eTag.map { Remembered(eTag: $0, value: value) }
        case .failure(.invalidDocument):
            accuracy = nil
        case .failure:
            break
        }
        return result.map { $0.0 }
    }

    /// Waits for a shared fetch; cancelling the waiting task cancels the fetch. Isolated to the
    /// actor, so a caller that is already cancelled cancels the fetch (the handler runs at once)
    /// before the fetch can start: it then sends nothing.
    private func result<Value: Sendable>(
        of task: Task<Result<Value, ForecastFeedError>, Never>
    ) async -> Result<Value, ForecastFeedError> {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// `GET url`, `Accept: application/json`, 10 s timeout, conditional when an ETag is known.
    static func request(url: URL, ifNoneMatch eTag: String?) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: URLSessionForecastTransport.timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let eTag { request.setValue(eTag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    /// Sends `request` and returns the value with the ETag to remember (nil = remember nothing).
    /// A 304 returns `remembered` with the request's own ETag. A rejected document is never
    /// returned, and the caller forgets the remembered one so the next request is unconditional.
    private func fetch<Value: Sendable>(
        _ request: URLRequest,
        remembered: Value?,
        decode: (Data, ForecastInstant) throws(ForecastDocumentError) -> Value
    ) async -> Result<(Value, String?), ForecastFeedError> {
        if Task.isCancelled { return .failure(.cancelled) }
        let response: ForecastHTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            // A transport that is not URLSession signals cancellation by failing while its task
            // is cancelled.
            return .failure(error.isCancellation || Task.isCancelled ? .cancelled : .transport(error))
        }
        // The production transport stops reading at this size; this covers any other transport.
        if response.body.count > ForecastLimits.maximumResponseBytes {
            return .failure(.transport(.bodyTooLarge))
        }
        switch response.statusCode {
        case 304:
            // RFC 9110 §15.4.5: the representation is unchanged since the one with our ETag.
            guard let remembered, let sentETag = request.value(forHTTPHeaderField: "If-None-Match") else {
                return .failure(.notModifiedWithoutCachedValue)
            }
            return .success((remembered, sentETag))
        case 200...299:
            do {
                return .success((try decode(response.body, now()), response.eTag))
            } catch {
                return .failure(.invalidDocument(error))
            }
        default:
            return .failure(.httpStatus(response.statusCode))
        }
    }
}
