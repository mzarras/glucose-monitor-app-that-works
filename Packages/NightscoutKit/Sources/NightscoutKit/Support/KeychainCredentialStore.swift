// Keychain-backed `CredentialStore` (PROGRESS D6, D7).
//
// Accessibility is `kSecAttrAccessibleAfterFirstUnlock`: uploads run while the phone is locked
// (BLE wakes the app in the background, HANDOFF §4.5), so the token and Share password must be
// readable after the first unlock since boot. `...ThisDeviceOnly` is not used so an encrypted
// device backup restores them; iCloud Keychain sync is off (`kSecAttrSynchronizable` false).
//
// Not exercised by `swift test`: the macOS host has no data-protection keychain entitlement for a
// test runner. Tests use `InMemoryCredentialStore`; this type is verified on device (HANDOFF §11).

import Foundation
import Security

public struct KeychainCredentialStore: CredentialStore {
    /// `kSecAttrService` for every item this app stores.
    public static let defaultService = "com.mzarras.sensor.credentials"

    private let service: String

    public init(service: String = KeychainCredentialStore.defaultService) {
        self.service = service
    }

    public func read(_ key: CredentialKey) throws(CredentialStoreError) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                throw CredentialStoreError(message: "Keychain item \(key.rawValue) is not UTF-8 text")
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError(message: "Keychain read \(key.rawValue) failed: OSStatus \(status)")
        }
    }

    public func write(_ value: String, for key: CredentialKey) throws(CredentialStoreError) {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(baseQuery(for: key) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError(message: "Keychain update \(key.rawValue) failed: OSStatus \(updateStatus)")
        }
        var add = baseQuery(for: key)
        add.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError(message: "Keychain add \(key.rawValue) failed: OSStatus \(addStatus)")
        }
    }

    public func delete(_ key: CredentialKey) throws(CredentialStoreError) {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError(message: "Keychain delete \(key.rawValue) failed: OSStatus \(status)")
        }
    }

    private func baseQuery(for key: CredentialKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrSynchronizable as String: false,
            // Same keychain implementation on iOS and macOS (the iOS-style data protection keychain).
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
