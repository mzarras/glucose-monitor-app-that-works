// Hosted (simulator) Keychain round trips for the two credential stores (PROGRESS Phase 2 must-do,
// WS1 review M3, WS7): the host tests of the packages cannot use the data-protection keychain.
// The sensor reconnects and uploads run while the phone is locked, so every item must be readable
// after the first unlock (`kSecAttrAccessibleAfterFirstUnlock`), and none may go to iCloud Keychain.
// Each test uses its own Keychain service name and deletes what it wrote.

import Foundation
import G7Kit
import NightscoutKit
import Security
import XCTest

final class KeychainCredentialStoreTests: XCTestCase {
    /// The simulator's Keychain needs a signed host: `scripts/check.sh` signs simulator test runs
    /// ad hoc (PROGRESS D40). An unsigned host gets errSecMissingEntitlement (-34018) for every call;
    /// that is a failure of the run, reported as such (these tests must run, never skip).
    override func setUpWithError() throws {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.mzarras.sensor.tests.probe",
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemCopyMatching(probe as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            XCTFail("UNSIGNED TEST HOST: the simulator Keychain refuses every call (errSecMissingEntitlement, -34018). Sign the simulator test run (D40).")
        }
    }

    func test_g7PairingRecordRoundTripsAfterFirstUnlockAndNotSynchronizable() throws {
        let service = "com.mzarras.sensor.tests.g7.\(UUID().uuidString)"
        let store = G7KeychainCredentialStore(service: service)
        defer { try? store.delete() }

        XCTAssertNil(try store.load())
        var record = G7PairingRecord(pairingCode: "1234", slot: .mobileApp)
        record.sensorName = "DXCM4F"
        record.serial = "DXCM4F-1A2B3C4D"
        record.sharedKey = Data((0..<16).map { UInt8($0) })
        record.reportedSessionLength = 907_200
        record.reportedWarmUp = 1_620
        record.sessionStart = Date(timeIntervalSince1970: 1_790_000_000)
        try store.save(record)
        XCTAssertEqual(try store.load(), record)

        // The update path (the record is saved at least once per wake).
        record.pairingCode = "5678"
        try store.save(record)
        XCTAssertEqual(try store.load(), record)

        let items = try Self.items(service: service)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlock as String)
        XCTAssertFalse(Self.isSynchronizable(items.first))

        try store.delete()
        XCTAssertNil(try store.load())
        XCTAssertTrue(try Self.items(service: service).isEmpty)
    }

    func test_nightscoutAndShareCredentialsRoundTripAfterFirstUnlockAndNotSynchronizable() throws {
        let service = "com.mzarras.sensor.tests.credentials.\(UUID().uuidString)"
        let store = KeychainCredentialStore(service: service)
        defer {
            for key in CredentialKey.allCases { try? store.delete(key) }
        }

        for key in CredentialKey.allCases {
            XCTAssertNil(try store.read(key))
        }
        try store.write("token-1", for: .nightscoutToken)
        try store.write("michael", for: .dexcomShareAccountName)
        try store.write("pässwörd ✓", for: .dexcomSharePassword)
        XCTAssertEqual(try store.read(.nightscoutToken), "token-1")
        XCTAssertEqual(try store.read(.dexcomShareAccountName), "michael")
        XCTAssertEqual(try store.read(.dexcomSharePassword), "pässwörd ✓")

        // Replacing a value (Settings: new token).
        try store.write("token-2", for: .nightscoutToken)
        XCTAssertEqual(try store.read(.nightscoutToken), "token-2")

        let items = try Self.items(service: service)
        XCTAssertEqual(items.count, 3)
        for item in items {
            XCTAssertEqual(item[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlock as String,
                           "\(item[kSecAttrAccount as String] ?? "?") must be readable while the phone is locked")
            XCTAssertFalse(Self.isSynchronizable(item), "\(item[kSecAttrAccount as String] ?? "?") must not go to iCloud Keychain")
        }

        try store.delete(.nightscoutToken)
        XCTAssertNil(try store.read(.nightscoutToken))
        XCTAssertNoThrow(try store.delete(.nightscoutToken), "deleting a missing value is not an error")
    }

    /// Every generic-password item of `service`, synchronizable or not, with its attributes.
    private static func items(service: String) throws -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainQueryFailed(status: status) }
        return result as? [[String: Any]] ?? []
    }

    private static func isSynchronizable(_ item: [String: Any]?) -> Bool {
        switch item?[kSecAttrSynchronizable as String] {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        default: return false
        }
    }

    private struct KeychainQueryFailed: Error {
        let status: OSStatus
    }
}
