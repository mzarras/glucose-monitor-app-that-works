// Original to Sensor (no ported code).

import Security
import XCTest
@testable import G7Kit

final class G7CredentialStoreTests: XCTestCase {
    func test_inMemoryStoreRoundTrips() throws {
        let store = G7InMemoryCredentialStore()
        XCTAssertNil(try store.load())
        var record = G7PairingRecord(pairingCode: "1234", slot: .mobileApp)
        record.sharedKey = Data(repeating: 7, count: 16)
        try store.save(record)
        XCTAssertEqual(try store.load(), record)
        try store.delete()
        XCTAssertNil(try store.load())
    }

    func test_recordIsCodable() throws {
        var record = G7PairingRecord(pairingCode: "0042", slot: .receiverOrPump)
        record.sensorName = "DXCM4F"
        record.peripheralIdentifier = UUID()
        record.serial = "DXCM4F-12345678"
        record.requiresNewPairing = true
        record.reportedSessionLength = 907_200
        record.reportedWarmUp = 1_620
        XCTAssertEqual(try JSONDecoder().decode(G7PairingRecord.self, from: JSONEncoder().encode(record)), record)
    }

    /// The Keychain item must be readable while the phone is locked (reconnects happen then) and
    /// must never sync to iCloud. The Keychain itself is not host-testable without entitlements, so
    /// this checks the attributes the store uses.
    func test_keychainItemIsReadableAfterFirstUnlockAndNotSynchronized() {
        let store = G7KeychainCredentialStore(service: "test.service")
        let query = store.baseQuery
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "test.service")
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(G7KeychainCredentialStore.defaultService, "com.mzarras.sensor.g7kit.pairing")
        XCTAssertEqual(kSecAttrAccessibleAfterFirstUnlock as String, "ck", "the accessibility constant the store writes")
    }

    func test_configurationDefaults() {
        let configuration = G7Configuration()
        XCTAssertEqual(configuration.restoreIdentifier, "com.mzarras.sensor.g7kit.central")
        XCTAssertEqual(configuration.authenticationSlot, .mobileApp)
        XCTAssertEqual(G7AuthenticationSlot.recommendedDefault, .mobileApp)
        XCTAssertEqual(G7SensorSerial.make(sensorName: "DXCM4F", peripheralIdentifier: UUID(uuidString: "1A2B3C4D-0000-4000-8000-000000000001")!), "DXCM4F-1A2B3C4D")
    }
}
