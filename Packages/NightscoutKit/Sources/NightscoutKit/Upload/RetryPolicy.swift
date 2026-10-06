// Original to Sensor (no ported code).
// Backoff between failed upload attempts.

import Foundation

public struct RetryPolicy: Sendable, Equatable {
    /// Wait after the first failure; doubles per consecutive failure.
    public let initialDelay: TimeInterval
    /// Upper bound for the doubling. 5 minutes = one G7 reading interval, so a recovered server is
    /// used again by the next reading at the latest.
    public let maximumDelay: TimeInterval
    /// Wait after a credentials failure. Long on purpose: Dexcom locks an account after repeated
    /// failed logins (xDrip4iOS DexcomShareUploadManager.swift:721-722 handles
    /// "SSO_AuthenticateMaxAttemptsExceeed"; its message says to wait 10 minutes), and Nightscout
    /// delays every request from an IP after a failed authentication
    /// (cgm-remote-monitor lib/authorization/delaylist.js:7-21). Saving new credentials should
    /// call `ReadingUploader.flush()` to retry immediately.
    public let authenticationFailureDelay: TimeInterval

    public init(initialDelay: TimeInterval, maximumDelay: TimeInterval, authenticationFailureDelay: TimeInterval) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.authenticationFailureDelay = authenticationFailureDelay
    }

    public static let `default` = RetryPolicy(initialDelay: 30, maximumDelay: 300, authenticationFailureDelay: 30 * 60)

    /// Delay before the next attempt after `consecutiveFailures` (≥ 1) failures, the last of kind `kind`.
    public func delay(afterConsecutiveFailures consecutiveFailures: Int, kind: UploadError.Kind) -> TimeInterval {
        switch kind {
        case .unauthorized, .missingCredentials:
            return authenticationFailureDelay
        case .configuration, .server, .transport:
            let exponent = min(max(consecutiveFailures - 1, 0), 30)
            return min(initialDelay * pow(2, Double(exponent)), maximumDelay)
        }
    }
}
