// Original to Sensor (no ported code).
// A mock of the parts of Nightscout (cgm-remote-monitor 15.0.8) this package uses, faithful where
// it matters for the tests:
//   - auth: the `api-secret` header must carry the token (lib/authorization/index.js:76-96,
//     194-200), else 401 (:267);
//   - GET /api/v1/entries.json: `find[type]`, `find[date][$gte|$lt]` as integers, `count` default 10,
//     newest first (lib/server/entries.js:29-31, 183-198; lib/constants.json:8); entries without a
//     numeric `date` never match a date range (MongoDB semantics);
//   - POST /api/v1/entries: upsert keyed on `sysTime` + `type`, `sysTime` derived from `dateString`
//     if present else from `date` (lib/server/entries.js:114-139, 238-248) — so re-posting an entry
//     does not create a second one.

import Foundation
@testable import NightscoutKit

actor MockNightscoutServer: MockBackend {
    struct Entry: Codable, Equatable, Sendable {
        var _id: String?
        var type: String?
        var sgv: Double?
        var mbg: Double?
        var date: Double?
        var dateString: String?
        var sysTime: String?
        var direction: String?
        var device: String?
    }

    let token: String?
    private(set) var entries: [Entry]
    private(set) var requests: [MockHTTPRequest] = []
    private var nextID = 1

    /// GET works without a token (AUTH_DEFAULT_ROLES=readable).
    var readableWithoutToken = false
    /// Simulates a server that ignores `find[type]` and returns every entry type.
    var ignoresTypeFilter = false
    /// Replies used, in order, instead of handling the next requests.
    var scripted: [MockReply] = []
    /// For the next POSTs: store the entries, then answer with this status (a lost/failed response
    /// after a successful write — the case that makes retries dangerous without server dedupe).
    var storeThenFailStatuses: [Int] = []
    /// After this many requests, every request fails as if offline.
    var offlineAfterRequests: Int?

    init(token: String? = "synthetic-token-1234", entries: [Entry] = []) {
        self.token = token
        self.entries = entries
    }

    // Hold gate: makes "a request is in flight" a state a test can wait for and end, so tests of
    // concurrent calls do not depend on scheduling (no sleeps).
    private var holdNext = false
    private var heldRequest: CheckedContinuation<Void, Never>?
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []

    /// The next request waits inside the server until `releaseHeldRequest()`.
    func holdNextRequest() { holdNext = true }

    /// Returns once a request is being held.
    func waitUntilHoldingRequest() async {
        if heldRequest != nil { return }
        await withCheckedContinuation { holdWaiters.append($0) }
    }

    /// Lets the held request continue.
    func releaseHeldRequest() {
        heldRequest?.resume()
        heldRequest = nil
    }

    func setReadableWithoutToken(_ value: Bool) { readableWithoutToken = value }
    func setIgnoresTypeFilter(_ value: Bool) { ignoresTypeFilter = value }
    func script(_ replies: [MockReply]) { scripted = replies }
    func storeThenFail(_ statuses: [Int]) { storeThenFailStatuses = statuses }
    func goOffline(afterRequests count: Int?) { offlineAfterRequests = count }
    var sgvEntries: [Entry] { entries.filter { $0.type == "sgv" } }

    func handle(_ request: MockHTTPRequest) async -> MockReply {
        requests.append(request)
        if holdNext {
            holdNext = false
            await withCheckedContinuation { continuation in
                heldRequest = continuation
                holdWaiters.forEach { $0.resume() }
                holdWaiters.removeAll()
            }
        }
        if let limit = offlineAfterRequests, requests.count > limit { return .transportFailure("offline") }
        if !scripted.isEmpty { return scripted.removeFirst() }
        guard request.path == "/api/v1/entries.json" || request.path == "/api/v1/entries" else {
            return .status(404)
        }
        let authorized = token == nil || request.header("api-secret") == token
        switch request.method {
        case "GET":
            guard authorized || readableWithoutToken else { return .json(401, ["status": 401, "message": "Unauthorized"]) }
            return list(request)
        case "POST":
            guard authorized else { return .json(401, ["status": 401, "message": "Unauthorized"]) }
            return create(request)
        default:
            return .status(405)
        }
    }

    private func list(_ request: MockHTTPRequest) -> MockReply {
        let gte = request.query("find[date][$gte]").flatMap { Int64($0) }
        let lt = request.query("find[date][$lt]").flatMap { Int64($0) }
        // Nightscout would silently apply "last 4 days of server time" without a date bound
        // (lib/server/query.js:82-87); the client must always send one, so the mock refuses.
        guard gte != nil || lt != nil else { return .status(400, body: "mock: date bound required") }
        let type = ignoresTypeFilter ? nil : request.query("find[type]")
        let count = request.query("count").flatMap { Int($0) } ?? 10
        let matching = entries
            .filter { entry in
                guard let date = entry.date else { return false }
                if let type, entry.type != type { return false }
                if let gte, date < Double(gte) { return false }
                if let lt, date >= Double(lt) { return false }
                return true
            }
            .sorted { ($0.date ?? 0) > ($1.date ?? 0) }
            .prefix(count)
        let data = (try? JSONEncoder().encode(Array(matching))) ?? Data("[]".utf8)
        return .http(HTTPResponse(statusCode: 200, body: data))
    }

    private func create(_ request: MockHTTPRequest) -> MockReply {
        let docs: [Entry]
        if let array = try? JSONDecoder().decode([Entry].self, from: request.body) {
            docs = array
        } else if let single = try? JSONDecoder().decode(Entry.self, from: request.body) {
            docs = [single]
        } else {
            return .status(400)
        }
        var stored: [Entry] = []
        for var doc in docs {
            doc.sysTime = Self.sysTime(for: doc)
            if let index = entries.firstIndex(where: { $0.sysTime == doc.sysTime && $0.type == doc.type }) {
                doc._id = entries[index]._id
                entries[index] = doc
            } else {
                doc._id = String(format: "%024x", nextID)
                nextID += 1
                entries.append(doc)
            }
            stored.append(doc)
        }
        if !storeThenFailStatuses.isEmpty { return .status(storeThenFailStatuses.removeFirst()) }
        let data = (try? JSONEncoder().encode(stored)) ?? Data("[]".utf8)
        return .http(HTTPResponse(statusCode: 200, body: data))
    }

    /// `moment.parseZone(dateString).toISOString()` or `moment(date).toISOString()`.
    static func sysTime(for doc: Entry) -> String? {
        let output = ISO8601DateFormatter()
        output.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        output.timeZone = TimeZone(identifier: "UTC")
        if let dateString = doc.dateString {
            let input = ISO8601DateFormatter()
            input.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = input.date(from: dateString) { return output.string(from: date) }
            input.formatOptions = [.withInternetDateTime]
            if let date = input.date(from: dateString) { return output.string(from: date) }
        }
        if let ms = doc.date { return output.string(from: Date(timeIntervalSince1970: ms / 1000)) }
        return nil
    }
}
