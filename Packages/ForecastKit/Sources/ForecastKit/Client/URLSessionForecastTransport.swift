// Original to Sensor (no ported code).
// Production transport over URLSession.

import Foundation

/// Sends feed requests with `URLSession`.
///
/// The default session is ephemeral with no URL cache, cookies or credential storage: nothing is
/// written to disk (D57: no persistence), and URLSession never answers from or rewrites a cached
/// copy, so the client's own `If-None-Match` reaches CloudFront and a 304 reaches the client as a
/// 304. Requests time out after 10 s overall and fail at once when offline.
///
/// Redirects are refused (the 3xx comes back as the response, which the client reports as
/// `.httpStatus`): the configured host must serve the feed itself, so a redirect is a
/// misconfiguration to surface, not something to follow to another host.
///
/// The body is read as it arrives and refused once it passes `ForecastLimits.maximumResponseBytes`
/// (or when `Content-Length` already says it will), so a wrong host serving a large file costs
/// little memory.
///
/// The transport owns its session and invalidates it (`finishTasksAndInvalidate`) when released,
/// so replacing the client after a change of host in Settings does not leak sessions.
public final class URLSessionForecastTransport: ForecastTransport {
    private let session: URLSession

    /// - Parameter session: taken over by the transport, which invalidates it when released.
    public init(session: URLSession = URLSessionForecastTransport.makeDefaultSession()) {
        self.session = session
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Time limit for one request, connection included.
    public static let timeout: TimeInterval = 10

    public static func makeDefaultSession() -> URLSession {
        URLSession(configuration: makeConfiguration())
    }

    /// The configuration `makeDefaultSession()` uses; tests add a stub protocol class to it.
    public static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        return configuration
    }

    public func send(_ request: URLRequest) async throws(ForecastTransportError) -> ForecastHTTPResponse {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: RefuseRedirects())
        } catch {
            throw Self.transportError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw ForecastTransportError(message: "The response is not HTTP.")
        }
        let limit = ForecastLimits.maximumResponseBytes
        // -1 when the server sent no Content-Length (NSURLResponseUnknownLength).
        if http.expectedContentLength > Int64(limit) {
            bytes.task.cancel()
            throw .bodyTooLarge
        }
        var body = Data()
        var tooLarge = false
        do {
            for try await byte in bytes {
                if body.count == limit {
                    tooLarge = true
                    break
                }
                body.append(byte)
            }
        } catch {
            throw Self.transportError(error)
        }
        if tooLarge {
            bytes.task.cancel()
            throw .bodyTooLarge
        }
        return ForecastHTTPResponse(statusCode: http.statusCode, eTag: http.value(forHTTPHeaderField: "ETag"), body: body)
    }

    /// URLSession reports a cancelled task as `URLError.cancelled`; Swift task cancellation can
    /// also surface as `CancellationError`. Both are cancellations, not failures (review m4).
    static func transportError(_ error: any Error) -> ForecastTransportError {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError, urlError.code == .cancelled { return .cancelled }
        return ForecastTransportError(message: error.localizedDescription)
    }
}

/// Refuses every redirect; URLSession then completes the task with the 3xx response.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
