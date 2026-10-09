// Original to Sensor (no ported code).
// Answers URLSession requests in-process, so the real URLSessionForecastTransport is tested
// without any network access. Each test uses its own host so stubs never collide.

import Foundation
@testable import ForecastKit

/// `@unchecked Sendable`: URLSession creates one instance per request and calls it from its own
/// threads; this subclass adds no stored state of its own (its replies live in `registry`, which
/// locks), and URLProtocol's own state is set by URLSession before loading starts.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case http(status: Int, headers: [String: String], body: Data)
        case notHTTP
        case failure(URLError.Code)
        /// A 301 to `location`, delivered the way URLSession's own HTTP loader reports one: the
        /// session asks its delegate, and only follows when the delegate returns the new request.
        case redirect(to: URL)
    }

    static let registry = Registry()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        Self.registry.record(request)
        guard let url = request.url, let reply = Self.registry.reply(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch reply {
        case .http(let status, let headers, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            if let response {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .notHTTP:
            let response = URLResponse(url: url, mimeType: "application/json", expectedContentLength: 2, textEncodingName: nil)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .redirect(let location):
            let headers = ["Location": location.absoluteString]
            if let response = HTTPURLResponse(url: url, statusCode: 301, httpVersion: "HTTP/1.1", headerFields: headers) {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: location), redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocol(self, didLoad: Data("moved".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// A session that sends everything to this stub, with the production configuration otherwise.
    static func session() -> URLSession {
        let configuration = URLSessionForecastTransport.makeConfiguration()
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// `@unchecked Sendable`: shared by every test and every URLSession thread; all its mutable
    /// state is only ever accessed under `lock`.
    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [URL: Reply] = [:]
        private var requests: [URLRequest] = []

        func set(_ reply: Reply, for url: URL) {
            lock.lock(); defer { lock.unlock() }
            replies[url] = reply
        }

        func reply(for url: URL) -> Reply? {
            lock.lock(); defer { lock.unlock() }
            return replies[url]
        }

        func record(_ request: URLRequest) {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
        }

        func requests(to url: URL) -> [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return requests.filter { $0.url == url }
        }
    }
}
