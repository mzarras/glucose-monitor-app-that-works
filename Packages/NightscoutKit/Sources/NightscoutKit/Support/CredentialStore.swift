// Credentials for Nightscout and Dexcom Share (PROGRESS D6, D7): entered in the app only, stored in
// the Keychain (`KeychainCredentialStore`), never in files, UserDefaults, logs, or URLs.

import Foundation

/// The secrets this package reads. Raw values are the Keychain account names; do not rename.
public enum CredentialKey: String, Sendable, CaseIterable {
    /// Nightscout access token (Admin Tools → Subjects), not the API_SECRET. See `NightscoutClient`.
    case nightscoutToken = "nightscout.token"
    /// Dexcom Share account name (the Dexcom account username).
    case dexcomShareAccountName = "dexcomShare.accountName"
    /// Dexcom Share account password.
    case dexcomSharePassword = "dexcomShare.password"
}

public struct CredentialStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Secret storage. Implementations must be thread-safe.
public protocol CredentialStore: Sendable {
    /// The stored value, or `nil` if none is stored.
    func read(_ key: CredentialKey) throws(CredentialStoreError) -> String?
    /// Stores or replaces the value.
    func write(_ value: String, for key: CredentialKey) throws(CredentialStoreError)
    /// Removes the value. Removing a missing value is not an error.
    func delete(_ key: CredentialKey) throws(CredentialStoreError)
}

/// In-memory store for tests and SwiftUI previews. Never use it for real credentials.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    // @unchecked Sendable: the only mutable state, `values`, is read and written exclusively while
    // holding `lock`.
    private let lock = NSLock()
    private var values: [CredentialKey: String]

    public init(_ values: [CredentialKey: String] = [:]) {
        self.values = values
    }

    public func read(_ key: CredentialKey) throws(CredentialStoreError) -> String? {
        lock.withLock { values[key] }
    }

    public func write(_ value: String, for key: CredentialKey) throws(CredentialStoreError) {
        lock.withLock { values[key] = value }
    }

    public func delete(_ key: CredentialKey) throws(CredentialStoreError) {
        lock.withLock { values[key] = nil }
    }
}
