// Original to Sensor (no ported code).
// The one seam for HTTP in this package, so tests never touch the network.

import Foundation

/// An HTTP response reduced to what the client needs.
public struct ForecastHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    /// The `ETag` response header, if any (CloudFront passes S3's ETag through).
    public let eTag: String?
    public let body: Data

    public init(statusCode: Int, eTag: String?, body: Data) {
        self.statusCode = statusCode
        self.eTag = eTag
        self.body = body
    }
}

/// The request produced no usable HTTP response (offline, DNS, TLS, timeout, a body over
/// `ForecastLimits.maximumResponseBytes`, cancelled).
public struct ForecastTransportError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    /// True when the request was cancelled (URLSession's `URLError.cancelled` or Swift task
    /// cancellation). The client reports it as `ForecastFeedError.cancelled`, not as a failure.
    /// Another transport signals cancellation by throwing while its task is cancelled.
    let isCancellation: Bool

    public init(message: String) {
        self.init(message: message, isCancellation: false)
    }

    init(message: String, isCancellation: Bool) {
        self.message = message
        self.isCancellation = isCancellation
    }

    /// The request was cancelled.
    static let cancelled = ForecastTransportError(message: "The request was cancelled.", isCancellation: true)

    /// The body is over `ForecastLimits.maximumResponseBytes`.
    static let bodyTooLarge = ForecastTransportError(
        message: "The response is larger than \(ForecastLimits.maximumResponseBytes / 1024) KB, far more than a feed document."
    )

    public var description: String { message }
}

/// Sends one request and returns the HTTP response, whatever its status code.
public protocol ForecastTransport: Sendable {
    func send(_ request: URLRequest) async throws(ForecastTransportError) -> ForecastHTTPResponse
}
