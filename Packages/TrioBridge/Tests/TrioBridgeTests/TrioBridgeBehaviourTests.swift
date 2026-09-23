// Non-safety behaviour of the bridge: clearing, the optional heartbeat keys, re-seeding after relaunch.

import Foundation
import GlucoseCore
import XCTest
@testable import TrioBridge

final class TrioBridgeBehaviourTests: XCTestCase {
    private let heartbeat = TrioHeartbeatPeripheral(
        peripheralIdentifier: UUID(uuidString: "0F6B2E6C-9A3B-4C7B-8E1F-2D6A5B4C3D2E")!,
        serviceUUID: "11111111-2222-3333-4444-555555555555", // example values, not protocol constants
        receiveCharacteristicUUID: "66666666-7777-8888-9999-AAAAAAAAAAAA"
    )

    private func bridge(_ store: InMemoryTrioStore, at seconds: UInt32 = 3_600) -> TrioBridge {
        TrioBridge(store: store, clock: { Fixture.time(seconds) })
    }

    func test_noNewReadingsMeansNoRewrite() async {
        let store = InMemoryTrioStore()
        let bridge = bridge(store)
        await bridge.publish([Fixture.reading(at: 3_600)], session: Fixture.session)
        let again = await bridge.publish([], session: Fixture.session)
        XCTAssertFalse(again.didWrite)
        XCTAssertEqual(store.readingWrites, 1)
    }

    func test_eachWriteCarriesEarlierReadingsSoTrioCanCatchUp() async throws {
        // Trio may be suspended across several writes; every write still contains the readings before it.
        let store = InMemoryTrioStore()
        let clock = TestClock(Fixture.time(3_600))
        let bridge = TrioBridge(store: store, clock: { clock.now() })
        for seconds in stride(from: UInt32(3_600), through: 4_800, by: 300) {
            clock.set(Fixture.time(seconds))
            await bridge.publish([Fixture.reading(at: seconds)], session: Fixture.session)
        }
        let read = try TrioReaderEmulation.read(XCTUnwrap(store.payload)).accepted
        XCTAssertEqual(read.count, 5)
        XCTAssertEqual(store.readingWrites, 5)
    }

    func test_relaunchedBridgeIsReseededFromStoredReadings() async throws {
        // A new process has an empty window; the app publishes its recent stored sensor readings and each
        // passes the gate again before it is written.
        let store = InMemoryTrioStore()
        await bridge(store, at: 4_200).publish(Fixture.series(from: 3_600, count: 3), session: Fixture.session)
        let relaunched = bridge(store, at: 4_500)
        let result = await relaunched.publish(Fixture.series(from: 3_600, count: 4), session: Fixture.session)
        XCTAssertEqual(result.addedReadingIDs.count, 4)
        XCTAssertEqual(try TrioReaderEmulation.read(XCTUnwrap(store.payload)).accepted.count, 4)
    }

    func test_clearRemovesReadingsAndForgetsThePayload() async throws {
        let store = InMemoryTrioStore()
        let bridge = bridge(store)
        await bridge.publish([Fixture.reading(at: 3_600)], session: Fixture.session)
        try await bridge.clear()
        XCTAssertNil(store.payload)
        XCTAssertEqual(store.operations.last, "remove latestReadings")
        // The same reading is no longer a duplicate: it is written again.
        let again = await bridge.publish([Fixture.reading(at: 3_600)], session: Fixture.session)
        XCTAssertTrue(again.didWrite)
    }

    func test_clearReportsMissingAppGroup() async {
        let store = InMemoryTrioStore()
        store.accessError = .appGroupUnavailable(groupID: "x", reason: .invalidGroupID)
        do {
            try await bridge(store).clear()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error, .appGroupUnavailable(groupID: "x", reason: .invalidGroupID))
        }
        XCTAssertTrue(store.operations.isEmpty)
    }

    func test_heartbeatWritesUUIDsBeforeAddressAndRemovesAddressFirst() async throws {
        let store = InMemoryTrioStore()
        let bridge = bridge(store)
        try await bridge.setHeartbeatPeripheral(heartbeat)
        XCTAssertEqual(store.operations, [
            "setString cgmTransmitter_CBUUID_Service",
            "setString cgmTransmitter_CBUUID_Receive",
            "setString cgmTransmitterDeviceAddress",
        ])
        XCTAssertEqual(store.string(forKey: "cgmTransmitterDeviceAddress"), "0F6B2E6C-9A3B-4C7B-8E1F-2D6A5B4C3D2E")
        XCTAssertEqual(store.string(forKey: "cgmTransmitter_CBUUID_Service"), heartbeat.serviceUUID)
        XCTAssertEqual(store.string(forKey: "cgmTransmitter_CBUUID_Receive"), heartbeat.receiveCharacteristicUUID)

        try await bridge.setHeartbeatPeripheral(nil)
        XCTAssertEqual(store.operations.suffix(3), [
            "remove cgmTransmitterDeviceAddress",
            "remove cgmTransmitter_CBUUID_Service",
            "remove cgmTransmitter_CBUUID_Receive",
        ])
        XCTAssertNil(store.string(forKey: "cgmTransmitterDeviceAddress"))
    }

    func test_heartbeatReportsMissingAppGroup() async {
        let store = InMemoryTrioStore()
        store.accessError = .appGroupUnavailable(groupID: "x", reason: .notEntitled)
        do {
            try await bridge(store).setHeartbeatPeripheral(heartbeat)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error, .appGroupUnavailable(groupID: "x", reason: .notEntitled))
        }
        XCTAssertTrue(store.operations.isEmpty)
    }

    func test_writesDiagnosticsForEachWrite() async {
        let store = InMemoryTrioStore()
        let log = RecordingDiagnosticLog()
        let bridge = TrioBridge(store: store, diagnostics: log, clock: { Fixture.time(3_600) })
        await bridge.publish([Fixture.reading(at: 3_600), Fixture.reading(at: 3_600)], session: Fixture.session)
        let messages = log.events.map(\.message)
        XCTAssertTrue(messages.contains { $0.hasPrefix("Trio bridge: wrote 1 reading(s) to Trio") })
        XCTAssertTrue(messages.contains { $0.contains("ignored 1 reading(s) already in the payload") })
        XCTAssertTrue(log.events.allSatisfy { $0.category == .bridge && $0.date == Fixture.time(3_600) })
    }
}

final class AppGroupUserDefaultsStoreTests: XCTestCase {
    private let validGroupID = "group.org.nightscout.ABCDE12345.trio.trio-app-group"
    /// A throwaway suite on the host, removed after each test, so no real App Group container is created.
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "TrioBridgeTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func store(groupID: String? = nil, entitled: Bool = true, suiteOpens: Bool = true) -> AppGroupUserDefaultsStore {
        let suite = suiteName
        return AppGroupUserDefaultsStore(
            appGroupID: groupID ?? validGroupID,
            containerExists: { _ in entitled },
            openSuite: { _ in suiteOpens ? UserDefaults(suiteName: suite) : nil }
        )
    }

    func test_trioAppGroupIDFormat() {
        XCTAssertTrue(TrioAppGroupContract.isValidTrioAppGroupID("group.org.nightscout.Z9Y8X7W6V5.trio.trio-app-group"))
        XCTAssertTrue(TrioAppGroupContract.isValidTrioAppGroupID(validGroupID))
        for invalid in [
            "group.org.nightscout..trio.trio-app-group",                  // empty $(DEVELOPMENT_TEAM)
            "group.org.nightscout.$(DEVELOPMENT_TEAM).trio.trio-app-group", // unexpanded
            "group.org.nightscout.abcde12345.trio.trio-app-group",        // lower case
            "group.org.nightscout.ABCDE1234.trio.trio-app-group",         // 9 characters
            "group.com.mzarras.sensor",                                   // this app's own group
            "",
        ] {
            XCTAssertFalse(TrioAppGroupContract.isValidTrioAppGroupID(invalid), invalid)
        }
    }

    func test_checkAccessRejectsInvalidIDMissingEntitlementAndMissingSuite() {
        XCTAssertNoThrow(try store().checkAccess())
        XCTAssertThrowsError(try store(groupID: "group.org.nightscout..trio.trio-app-group").checkAccess()) {
            XCTAssertEqual($0 as? TrioBridgeError, .appGroupUnavailable(groupID: "group.org.nightscout..trio.trio-app-group", reason: .invalidGroupID))
        }
        XCTAssertThrowsError(try store(entitled: false).checkAccess()) {
            XCTAssertEqual($0 as? TrioBridgeError, .appGroupUnavailable(groupID: validGroupID, reason: .notEntitled))
        }
        XCTAssertThrowsError(try store(suiteOpens: false).checkAccess()) {
            XCTAssertEqual($0 as? TrioBridgeError, .appGroupUnavailable(groupID: validGroupID, reason: .suiteUnavailable))
        }
    }

    func test_readWriteRemoveRoundTrip() {
        let store = store()
        let payload = Data("[]".utf8)
        store.setData(payload, forKey: "latestReadings")
        XCTAssertEqual(store.data(forKey: "latestReadings"), payload)
        store.setString("abc", forKey: "cgmTransmitterDeviceAddress")
        XCTAssertEqual(store.string(forKey: "cgmTransmitterDeviceAddress"), "abc")
        store.removeValue(forKey: "latestReadings")
        store.removeValue(forKey: "cgmTransmitterDeviceAddress")
        XCTAssertNil(store.data(forKey: "latestReadings"))
        XCTAssertNil(store.string(forKey: "cgmTransmitterDeviceAddress"))
    }

    func test_productionStoreKeepsTheGroupIDItWasGiven() {
        XCTAssertEqual(AppGroupUserDefaultsStore(appGroupID: validGroupID).appGroupID, validGroupID)
    }

    func test_bridgeEndToEndThroughUserDefaults() async throws {
        let bridge = TrioBridge(store: store(), clock: { Fixture.time(3_600) })
        let result = await bridge.publish([Fixture.reading(at: 3_600, value: .mgdl(123))], session: Fixture.session)
        XCTAssertTrue(result.didWrite)
        let written = try XCTUnwrap(UserDefaults(suiteName: suiteName)?.data(forKey: "latestReadings"))
        XCTAssertEqual(try TrioReaderEmulation.read(written).accepted.map(\.mgdl), [123])
    }
}
