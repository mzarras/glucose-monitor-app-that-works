// Original to Sensor (no ported code).

import Foundation
import Security

/// Stores the pairing record as one generic-password Keychain item (JSON).
///
/// Accessibility is `kSecAttrAccessibleAfterFirstUnlock`: the sensor reconnects every ~5 minutes
/// while the phone is locked, and the short authentication path must read the key then. The item is
/// not synchronizable (never goes to iCloud Keychain). Without `ThisDeviceOnly` an encrypted device
/// backup can restore it; that is harmless, because a restored key for a sensor that is gone never
/// matches, and a restored key for the current sensor lets readings resume without re-pairing.
public struct G7KeychainCredentialStore: G7CredentialStore {
    /// Keychain service; one record per app.
    public static let defaultService = "com.mzarras.sensor.g7kit.pairing"
    static let account = "pairing-record"

    public enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case corruptRecord
    }

    private let service: String

    public init(service: String = G7KeychainCredentialStore.defaultService) {
        self.service = service
    }

    public func load() throws -> G7PairingRecord? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data, let record = try? JSONDecoder().decode(G7PairingRecord.self, from: data) else {
            throw KeychainError.corruptRecord
        }
        return record
    }

    public func save(_ record: G7PairingRecord) throws {
        let data = try JSONEncoder().encode(record)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
        var add = baseQuery
        add.merge(update) { _, new in new }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
    }

    /// The attributes that identify the item. `kSecUseDataProtectionKeychain` makes macOS use the
    /// same keychain semantics as iOS (it is the only keychain on iOS).
    var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
