// Where a `ReadingUploader` sends readings: Nightscout or Dexcom Share (HANDOFF §8A).

import Foundation
import GlucoseCore

/// Why an upload attempt failed. Messages never contain tokens or passwords.
public struct UploadError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable, Equatable, Codable {
        /// No token / account / password stored.
        case missingCredentials
        /// Credentials rejected (Nightscout 401/403, Share SSO errors). Retried slowly
        /// (`RetryPolicy.authenticationFailureDelay`) so a wrong password cannot lock the account.
        case unauthorized
        /// The account is not set up for this upload (e.g. Share receiver serial not assigned).
        case configuration
        /// The server answered with an error.
        case server
        /// No HTTP response (offline, DNS, TLS, timeout).
        case transport
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { message }
}

public protocol UploadDestination: Sendable {
    /// Shown in Settings and diagnostics, e.g. "Nightscout".
    var name: String { get }
    /// Most readings sent in one request.
    var maxBatchSize: Int { get }
    /// Queued readings older than this when a flush starts are discarded (and counted); `nil` keeps
    /// them until they are uploaded.
    var maxReadingAge: TimeInterval? { get }
    /// Whether this destination has a faithful representation for `value` (S4). Readings it cannot
    /// represent are refused at submit time, never approximated.
    func canRepresent(_ value: GlucoseValue) -> Bool
    /// Sends `readings` (all `.sensor`, already gated). Must be idempotent on the server: the same
    /// reading sent twice after a lost response must not create a second record. Either returns
    /// (all accepted) or throws (the queue keeps all of them and retries later).
    func upload(_ readings: [GlucoseReading]) async throws(UploadError)
}
