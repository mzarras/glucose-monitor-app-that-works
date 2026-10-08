// Original to Sensor (no ported code).
// The feed host the user entered (Settings › Predictions) or the build provided
// (`ZEN_PREDICT_FEED_HOST`, PROGRESS D57), validated, and the two feed URLs on it.

import Foundation

/// Why a feed host was refused. `description` is a sentence the Settings screen can show.
public enum ForecastEndpointError: Error, Sendable, Equatable, CustomStringConvertible {
    case empty
    /// `http://` or any scheme other than `https://`.
    case notHTTPS
    /// `user:password@host`. The feed is public; nothing secret belongs in it.
    case containsCredentials
    case containsQueryOrFragment
    /// Anything after the host other than one trailing slash. The feed lives at the host's root.
    case containsPath
    case containsPort
    /// Not a DNS name: see `ForecastFeedEndpoint.isHostName`. IP addresses are refused too.
    case invalidHost

    public var description: String {
        switch self {
        case .empty: return "Enter the feed's host name, for example zen.example.com."
        case .notHTTPS: return "Only https:// is supported."
        case .containsCredentials: return "Remove the user name and password; the feed is public."
        case .containsQueryOrFragment: return "Remove everything after ? or #."
        case .containsPath: return "Enter only the host name, without a path."
        case .containsPort: return "Enter only the host name, without a port."
        case .invalidHost: return "That is not a valid host name, for example zen.example.com."
        }
    }
}

/// A validated feed host and the URLs of its two documents.
public struct ForecastFeedEndpoint: Sendable, Equatable, Hashable {
    /// The host, lower-cased, e.g. "zen.example.com": exactly the host of `latestURL` and
    /// `metricsURL`, so what Settings shows is what the app contacts.
    public let host: String
    /// `https://<host>/latest.json` (publish.py `LATEST_KEY`).
    public let latestURL: URL
    /// `https://<host>/metrics.json` (publish.py `METRICS_KEY`).
    public let metricsURL: URL

    /// Accepts a bare host (`zen.example.com`) or `https://zen.example.com`, either with one
    /// optional trailing slash; surrounding whitespace is ignored and the host is lower-cased.
    /// Refuses `http://` and other schemes, credentials, queries, fragments, paths, ports, IP
    /// addresses and anything that is not an ASCII DNS name with a dot.
    public init(_ input: String) throws(ForecastEndpointError) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = text.range(of: "://") {
            guard text[..<separator.lowerBound].lowercased() == "https" else { throw .notHTTPS }
            text = String(text[separator.upperBound...])
        }
        if text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { throw .empty }
        guard !text.contains("@") else { throw .containsCredentials }
        guard !text.contains("?"), !text.contains("#") else { throw .containsQueryOrFragment }
        guard !text.contains("/") else { throw .containsPath }
        guard !text.contains(":") else { throw .containsPort }

        // ASCII before lower-casing too: Unicode lower-casing maps some non-ASCII characters to
        // ASCII letters (U+212A KELVIN SIGN → "k").
        guard text.utf8.allSatisfy({ $0 < 0x80 }) else { throw .invalidHost }
        let host = text.lowercased()
        guard Self.isHostName(host),
              let latestURL = URL(string: "https://\(host)/latest.json"),
              let metricsURL = URL(string: "https://\(host)/metrics.json"),
              latestURL.host(percentEncoded: false) == host,
              metricsURL.host(percentEncoded: false) == host
        else { throw .invalidHost }
        self.host = host
        self.latestURL = latestURL
        self.metricsURL = metricsURL
    }

    /// An RFC 1123 DNS name, checked byte by byte on the UTF-8 so only ASCII passes (a Swift
    /// `Character` such as "n" + U+20DD would compare as a letter): at most 253 bytes; at least two
    /// dot-separated labels of 1–63 bytes from a–z, 0–9 and "-", not starting or ending with "-";
    /// and a last label of letters only, so no IP address (`192.168.1.10`, `999.999.999.999`) or
    /// bare number (`0`) passes. Single-label names such as `localhost` are refused too.
    static func isHostName(_ host: String) -> Bool {
        let bytes = Array(host.utf8)
        guard bytes.count <= 253 else { return false }
        let labels = bytes.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last, last.allSatisfy(isLetter) else { return false }
        return labels.allSatisfy { label in
            (1...63).contains(label.count)
                && label.first != UInt8(ascii: "-") && label.last != UInt8(ascii: "-")
                && label.allSatisfy { isLetter($0) || isDigit($0) || $0 == UInt8(ascii: "-") }
        }
    }

    private static func isLetter(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z") }
    private static func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
}
