// HTTP plumbing for tests. No test talks to a real service: requests go either to an in-process
// transport or to `LocalHTTPServer` on 127.0.0.1, and the backends below answer them.

import Foundation
import Network
@testable import NightscoutKit

/// A request as a mock backend sees it.
struct MockHTTPRequest: Sendable {
    let method: String
    let path: String
    let queryItems: [URLQueryItem]
    /// Header names lower-cased.
    let headers: [String: String]
    let body: Data
    /// The full request target (path + query) as sent, for "never in the URL" assertions.
    let target: String

    func query(_ name: String) -> String? { queryItems.first { $0.name == name }?.value }
    func header(_ name: String) -> String? { headers[name.lowercased()] }

    init(method: String, target: String, headers: [String: String], body: Data) {
        self.method = method
        self.target = target
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
        let components = URLComponents(string: "http://mock" + target)
        self.path = components?.path ?? target
        self.queryItems = components?.queryItems ?? []
    }

    init(_ request: URLRequest) {
        let url = request.url!
        var target = url.path
        if let query = url.query { target += "?" + query }
        self.init(
            method: request.httpMethod ?? "GET",
            target: target,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? Data()
        )
    }
}

enum MockReply: Sendable {
    case http(HTTPResponse)
    /// No HTTP response at all (offline, connection dropped).
    case transportFailure(String)
    /// 302 Found with a `Location` header (only `LocalHTTPServer` can send the header; the
    /// in-process transport returns the bare 302).
    case redirect(to: String)

    static func json(_ status: Int, _ object: Any) -> MockReply {
        .http(HTTPResponse(statusCode: status, body: (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data()))
    }

    static func status(_ status: Int, body: String = "") -> MockReply {
        .http(HTTPResponse(statusCode: status, body: Data(body.utf8)))
    }
}

protocol MockBackend: Sendable {
    func handle(_ request: MockHTTPRequest) async -> MockReply
}

/// Delivers requests straight to a backend, in process.
struct InProcessTransport: HTTPTransport {
    let backend: any MockBackend

    func send(_ request: URLRequest) async throws(TransportError) -> HTTPResponse {
        switch await backend.handle(MockHTTPRequest(request)) {
        case .http(let response): return response
        case .transportFailure(let message): throw TransportError(message: message)
        case .redirect: return HTTPResponse(statusCode: 302, body: Data())
        }
    }
}

/// A minimal HTTP/1.1 server on 127.0.0.1 (random port) for real-socket tests through
/// `URLSessionTransport`. One request per connection (`Connection: close`).
final class LocalHTTPServer: @unchecked Sendable {
    // @unchecked Sendable: `listener` is configured before `start` and afterwards only touched from
    // `queue` (Network framework callbacks run there); `backend` is itself Sendable.
    private let queue = DispatchQueue(label: "LocalHTTPServer")
    private let listener: NWListener
    private let backend: any MockBackend

    init(backend: any MockBackend) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: parameters)
        self.backend = backend
    }

    /// Starts listening and returns the base URL, e.g. `http://127.0.0.1:53123`.
    func start() async throws -> URL {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                let backend = self.backend
                Task {
                    let reply = await backend.handle(request)
                    self.respond(reply, on: connection)
                }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(_ reply: MockReply, on connection: NWConnection) {
        switch reply {
        case .transportFailure:
            connection.cancel()
        case .redirect(let location):
            let head = "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
        case .http(let response):
            var head = "HTTP/1.1 \(response.statusCode) Mock\r\n"
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(response.body.count)\r\n"
            head += "Connection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// Parses a complete request (head + Content-Length body), or returns nil if more bytes are needed.
    static func parse(_ buffer: Data) -> MockHTTPRequest? {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name.lowercased()] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return nil }
        let body = buffer[bodyStart..<(bodyStart + length)]
        return MockHTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, body: Data(body))
    }
}

/// Guards a continuation against double resumption.
final class ResumeOnce: @unchecked Sendable {
    // @unchecked Sendable: `done` is only read and written while holding `lock`.
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}

/// Answers every request with a redirect to `location` and records what it saw.
actor RedirectingBackend: MockBackend {
    let location: String
    private(set) var requests: [MockHTTPRequest] = []

    init(location: String) {
        self.location = location
    }

    func handle(_ request: MockHTTPRequest) async -> MockReply {
        requests.append(request)
        return .redirect(to: location)
    }
}
