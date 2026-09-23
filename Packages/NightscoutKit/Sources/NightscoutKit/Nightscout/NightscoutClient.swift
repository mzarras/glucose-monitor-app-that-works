// Minimal Nightscout REST API v1 client: list sgv entries (import) and post entries (upload).
// Line numbers refer to cgm-remote-monitor 15.0.8 (92d08342).
//
// Authentication: the access token goes in the `api-secret` request header, never in the URL.
//   - lib/authorization/index.js:76-96 reads `api-secret` (header) as the "secret".
//   - :171-180 first compares it with the SHA-1/SHA-512 of API_SECRET (admin); an access token
//     does not match, so resolution continues.
//   - :194-200 "Check if there's a token in the secret": if an access token with that name exists
//     (lib/authorization/storage.js:302-307), its roles apply.
//   The same lookup exists in 14.2.6 (lib/authorization/index.js:196-198), so older sites work.
// The alternative, `?token=` (lib/authorization/index.js:43-61), would put the token in the URL,
// where reverse proxies, load balancers (Michael runs Nightscout on AWS) and diagnostics log it.
//
// Required permissions: GET needs `api:entries:read` (lib/api/entries/index.js:54, role
// "readable"); POST needs `api:entries:create` (:796), which no default role except "admin" has
// (lib/authorization/storage.js:140-148). See docs/following.md for the role to create.

import Foundation

/// Errors from Nightscout requests. Messages never contain the token.
public enum NightscoutClientError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No access token in the credential store (uploads always need one).
    case missingToken
    case credentialStore(String)
    /// 401/403: token unknown, or its roles lack the permission (lib/authorization/index.js:267).
    case unauthorized(statusCode: Int)
    case http(statusCode: Int)
    case transport(String)
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .missingToken: return "Nightscout token is not set"
        case .credentialStore(let message): return "Could not read the Nightscout token: \(message)"
        case .unauthorized(let code): return "Nightscout refused the token (HTTP \(code))"
        case .http(let code): return "Nightscout returned HTTP \(code)"
        case .transport(let message): return "Could not reach Nightscout: \(message)"
        case .malformedResponse(let message): return "Unexpected Nightscout response: \(message)"
        }
    }
}

struct NightscoutClient: Sendable {
    let site: NightscoutSite
    let credentials: any CredentialStore
    let transport: any HTTPTransport

    /// sgv entries with `lowerMs <= date < upperMs`, newest first, at most `count`.
    ///
    /// Query parameters (lib/server/query.js, lib/api/entries/index.js):
    ///   `find[type]=sgv`         only sgv entries (type filter, entries/index.js:130-134, 339-349)
    ///   `find[date][$gte]=<ms>`  `date` is compared as an integer (lib/server/entries.js:187)
    ///   `find[date][$lt]=<ms>`   an explicit date bound also disables the default "last 4 days"
    ///                            filter (lib/server/query.js:82-87)
    ///   `count=<n>`              default is 10 (lib/constants.json:8, entries/index.js:462-465)
    /// Results are sorted by `date` descending (lib/server/entries.js:29-31).
    func sgvEntries(lowerMs: Int64, upperMs: Int64, count: Int) async throws(NightscoutClientError) -> [NightscoutEntry] {
        try await getEntries([
            URLQueryItem(name: "find[type]", value: "sgv"),
            URLQueryItem(name: "find[date][$gte]", value: String(lowerMs)),
            URLQueryItem(name: "find[date][$lt]", value: String(upperMs)),
            URLQueryItem(name: "count", value: String(count)),
        ])
    }

    /// The newest sgv entry with `date < upperMs`, or `nil` if there is none. Used by the
    /// "everything" import to skip gaps and to find where history ends.
    func newestSGVEntry(beforeMs upperMs: Int64) async throws(NightscoutClientError) -> NightscoutEntry? {
        try await getEntries([
            URLQueryItem(name: "find[type]", value: "sgv"),
            URLQueryItem(name: "find[date][$lt]", value: String(upperMs)),
            URLQueryItem(name: "count", value: "1"),
        ]).first
    }

    /// POSTs a JSON array of entries. Nightscout upserts each on `sysTime` + `type`
    /// (lib/server/entries.js:122-139, 238-248), so posting the same entry again is idempotent.
    /// Arrays of up to 10000 documents are accepted (lib/api/shared/write-payload.js:6).
    ///
    /// Success means a 2xx **and** a JSON array body: Nightscout answers a stored POST with the
    /// stored documents (15.0.8 lib/api/entries/index.js:255-262 `res.json(res.entries || [])`;
    /// 14.2.6 answers through `format_entries`, JSON for `Accept: application/json`). Anything
    /// else with a 2xx — a captive portal's or proxy's HTML page — is not proof the entries were
    /// stored, so it fails and the readings stay queued.
    func postEntries(jsonArray body: Data) async throws(NightscoutClientError) {
        guard let token = try readToken() else { throw .missingToken }
        var request = URLRequest(url: site.entriesURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(token, forHTTPHeaderField: "api-secret")
        let response = try await send(request)
        try Self.check(response)
        guard (try? JSONSerialization.jsonObject(with: response.body)) is [Any] else {
            throw .malformedResponse("upload answer is not a JSON array (HTTP \(response.statusCode))")
        }
    }

    private func getEntries(_ queryItems: [URLQueryItem]) async throws(NightscoutClientError) -> [NightscoutEntry] {
        guard var components = URLComponents(url: site.entriesJSONURL, resolvingAgainstBaseURL: false) else {
            throw .malformedResponse("cannot build entries URL")
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw .malformedResponse("cannot build entries URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Reading may be allowed without a token (AUTH_DEFAULT_ROLES=readable); send one if we have it.
        if let token = try readToken() {
            request.setValue(token, forHTTPHeaderField: "api-secret")
        }
        let response = try await send(request)
        try Self.check(response)
        do {
            return try JSONDecoder().decode([NightscoutEntry].self, from: response.body)
        } catch {
            throw .malformedResponse("entries body is not a JSON array")
        }
    }

    private func readToken() throws(NightscoutClientError) -> String? {
        let token: String?
        do {
            token = try credentials.read(.nightscoutToken)
        } catch {
            throw .credentialStore(error.message)
        }
        guard let token, !token.isEmpty else { return nil }
        return token
    }

    private func send(_ request: URLRequest) async throws(NightscoutClientError) -> HTTPResponse {
        do {
            return try await transport.send(request)
        } catch {
            throw .transport(error.message)
        }
    }

    private static func check(_ response: HTTPResponse) throws(NightscoutClientError) {
        if response.isSuccess { return }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw .unauthorized(statusCode: response.statusCode)
        }
        throw .http(statusCode: response.statusCode)
    }
}
