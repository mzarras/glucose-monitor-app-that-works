// Original to Sensor (no ported code).
// The user's Nightscout site (PROGRESS D6), entered at runtime.

import Foundation

/// A validated Nightscout base URL.
///
/// Only `https` is accepted, because every request carries the access token. Plain `http` is
/// accepted for loopback hosts only (`127.0.0.1`, `::1`, `localhost`) so tests can run against a
/// local mock server.
public struct NightscoutSite: Sendable, Equatable, Hashable, Codable {
    public let baseURL: URL

    public enum ValidationError: Error, Sendable, Equatable {
        case notAURL
        case insecureScheme
        case missingHost
        /// Credentials must go in the Keychain, never in the URL.
        case containsCredentialsOrQuery
    }

    public init(_ string: String) throws(ValidationError) {
        guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw .notAURL
        }
        try self.init(components: components)
    }

    // Codable goes through `init(url:)`, so a stored value (e.g. an import checkpoint) can never
    // carry a URL that would be refused if typed in (`http://` to a non-loopback host, credentials).
    private enum CodingKeys: String, CodingKey { case baseURL }

    public init(from decoder: any Decoder) throws {
        let url = try decoder.container(keyedBy: CodingKeys.self).decode(URL.self, forKey: .baseURL)
        do {
            try self.init(url: url)
        } catch {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [CodingKeys.baseURL], debugDescription: "invalid Nightscout site: \(error)"
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseURL, forKey: .baseURL)
    }

    public init(url: URL) throws(ValidationError) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw .notAURL }
        try self.init(components: components)
    }

    private init(components input: URLComponents) throws(ValidationError) {
        var components = input
        guard let scheme = components.scheme?.lowercased() else { throw .notAURL }
        guard let host = components.host, !host.isEmpty else { throw .missingHost }
        guard components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            throw .containsCredentialsOrQuery
        }
        let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]
        switch scheme {
        case "https": break
        case "http" where loopbackHosts.contains(host.lowercased()): break
        default: throw .insecureScheme
        }
        // Normalise: no trailing slash, so endpoint paths append cleanly.
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw .notAURL }
        self.baseURL = url
    }

    // Nightscout API v1 is mounted at `/api/v1` (cgm-remote-monitor lib/server/app.js:292) and
    // routes `/entries*` to the entries router (lib/api/index.js:45). Line numbers in this package
    // refer to cgm-remote-monitor 15.0.8 (92d08342).

    /// `GET <base>/api/v1/entries.json` — list entries (lib/api/entries/index.js:421). The `.json`
    /// extension is stripped and turned into `Accept: application/json`
    /// (lib/middleware/express-extension-to-accept.js:19-37, enabled at entries/index.js:50-52).
    var entriesJSONURL: URL {
        baseURL.appendingPathComponent("api/v1/entries.json")
    }

    /// `POST <base>/api/v1/entries` — create/upsert entries (lib/api/entries/index.js:796).
    var entriesURL: URL {
        baseURL.appendingPathComponent("api/v1/entries")
    }
}
