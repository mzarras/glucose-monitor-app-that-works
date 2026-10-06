// One seam for all HTTP in this package, so tests run against fixtures and a localhost server and
// no code path exercised by a test can reach a real service (brief: no traffic to real services).

import Foundation

/// An HTTP response reduced to what the clients need.
public struct HTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    public var isSuccess: Bool { (200...299).contains(statusCode) }
}

/// The request never produced an HTTP response (offline, DNS, TLS, timeout, cancelled).
public struct TransportError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Sends one request and returns the HTTP response, whatever its status code.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws(TransportError) -> HTTPResponse
}

/// Production transport over `URLSession`.
///
/// Uses an ephemeral configuration: no cookies, no URL cache, no credential storage. Nothing about
/// a Nightscout token or Dexcom password is persisted by the networking stack. Redirects are
/// followed only to the same scheme, host and port: URLSession re-sends custom headers such as
/// `api-secret` on a redirect, so a redirect elsewhere could carry the token away. A refused
/// redirect returns the 3xx response, which callers treat as a failure (S5).
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let redirectPolicy = SameOriginRedirectsOnly()

    public init(session: URLSession = URLSessionTransport.makeDefaultSession()) {
        self.session = session
    }

    public static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws(TransportError) -> HTTPResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: redirectPolicy)
        } catch {
            throw TransportError(message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TransportError(message: "response is not HTTP")
        }
        return HTTPResponse(statusCode: http.statusCode, body: data)
    }
}

/// Allows a redirect only when scheme, host and port are unchanged.
final class SameOriginRedirectsOnly: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        Self.allows(from: task.originalRequest?.url, to: request.url) ? request : nil
    }

    static func allows(from original: URL?, to target: URL?) -> Bool {
        guard let original, let target else { return false }
        return original.scheme?.lowercased() == target.scheme?.lowercased()
            && original.host?.lowercased() == target.host?.lowercased()
            && original.port == target.port
    }
}
