// Original to Sensor (no ported code).

import XCTest
@testable import G7Kit

final class G7AuthSessionTests: XCTestCase {
    private func makeSession(code: String?, savedKey: [UInt8]?, sensor: G7SensorSimulator, slot: G7AuthenticationSlot = .mobileApp)
        -> (G7AuthSession, RecordingAuthDelegate, FakeLink, LinkDriver) {
        let link = FakeLink()
        let session = G7AuthSession(link: link, slot: slot, pairingCode: code, savedKey: savedKey)
        let delegate = RecordingAuthDelegate()
        session.delegate = delegate
        let driver = LinkDriver(link: link, sensor: sensor,
                                deliverNotify: { characteristic, enabled, _ in session.notificationStateChanged(for: characteristic, isNotifying: enabled) },
                                deliverValue: { characteristic, value in
                                    if characteristic == .authStream { session.receiveAuthStream(value) } else { session.receiveAuthentication(value) }
                                })
        return (session, delegate, link, driver)
    }

    /// Auth_Stream must be listening before Receive_Authentication (DexcomG7AuthSession.swift:199-211).
    func test_enablesAuthStreamBeforeReceiveAuthentication() {
        let sensor = G7SensorSimulator(pairingCode: "1234")
        let (session, _, link, _) = makeSession(code: "1234", savedKey: nil, sensor: sensor)
        session.begin()
        XCTAssertEqual(link.notifyRequests.map(\.0), [.authStream])
        link.notifying.insert(.authStream)
        session.notificationStateChanged(for: .authStream, isNotifying: true)
        XCTAssertEqual(link.notifyRequests.map(\.0), [.authStream, .receiveAuthentication])
        XCTAssertTrue(link.writes.isEmpty, "nothing is written until both are notifying")
    }

    /// Short path: `02 token 02` → `03` → `04 hash` → `05 01 01`.
    func test_shortAuthenticationWithSavedKey() throws {
        let key = G7Random.bytes(16)
        let sensor = G7SensorSimulator(pairingCode: "1234")
        sensor.confirmedKeys[0x02] = key
        let (session, delegate, link, driver) = makeSession(code: "1234", savedKey: key, sensor: sensor)
        session.begin()
        driver.pump()
        XCTAssertTrue(session.isAuthenticated)
        XCTAssertEqual(delegate.authenticatedKeys.count, 1)
        XCTAssertNil(delegate.authenticatedKeys[0] ?? nil, "no new key on the short path")
        let controlWrites = link.allWrites.filter { $0.characteristic == .receiveAuthentication }.map(\.data)
        XCTAssertEqual(controlWrites.first?.first, 0x02)
        XCTAssertEqual(controlWrites.first?.last, 0x02, "slot byte")
        XCTAssertEqual(controlWrites.last?.first, 0x04)
        XCTAssertFalse(link.allWrites.contains { $0.characteristic == .authStream }, "no J-PAKE on the short path")
    }

    /// Full path, legacy completion: `06 00` → `07` → `07 00` → `08 01` (DexcomG7AuthSession.swift:308-334).
    func test_fullBootstrapWithLegacyBondCompletion() throws {
        let sensor = G7SensorSimulator(pairingCode: "0042")
        sensor.ownershipCompletion = .legacyBond
        let (session, delegate, link, driver) = makeSession(code: "0042", savedKey: nil, sensor: sensor, slot: .smartWatch)
        session.begin()
        driver.pump()
        XCTAssertTrue(session.isAuthenticated)
        let key = try XCTUnwrap(delegate.authenticatedKeys.first ?? nil)
        XCTAssertEqual(sensor.confirmedKeys[0x03], key)
        XCTAssertTrue(link.allWrites.contains { $0.data == Data([0x07]) })
        // Auth_Stream carried three 160-byte J-PAKE payloads, both certificates and the signature.
        let streamed = link.allWrites.filter { $0.characteristic == .authStream }.reduce(0) { $0 + $1.data.count }
        XCTAssertEqual(streamed, 3 * 160 + 494 + 465 + 64)
        XCTAssertTrue(link.allWrites.filter { $0.characteristic == .authStream }.allSatisfy { $0.data.count <= 20 })
    }

    /// Wrong code: J-PAKE completes, keys differ, the sensor answers `05 02 02` → pairingCodeRejected,
    /// and no key is reported (DexcomG7AuthSession.swift:436-441).
    func test_wrongPairingCodeIsRejectedWithoutAKey() {
        let sensor = G7SensorSimulator(pairingCode: "1111")
        let (session, delegate, _, driver) = makeSession(code: "2222", savedKey: nil, sensor: sensor)
        session.begin()
        driver.pump()
        XCTAssertFalse(session.isAuthenticated)
        XCTAssertEqual(delegate.failures, [.pairingCodeRejected])
        XCTAssertTrue(delegate.authenticatedKeys.isEmpty)
        XCTAssertTrue(sensor.confirmedKeys.isEmpty)
    }

    /// A saved key the sensor no longer accepts: stop, never re-bootstrap on our own
    /// (DexcomG7AuthSession.swift:409-420).
    func test_rejectedSavedKeyStopsWithoutBootstrapping() {
        let sensor = G7SensorSimulator(pairingCode: "1234")
        sensor.confirmedKeys[0x02] = G7Random.bytes(16)
        let (session, delegate, link, driver) = makeSession(code: "1234", savedKey: G7Random.bytes(16), sensor: sensor)
        session.begin()
        driver.pump()
        XCTAssertEqual(delegate.savedKeyRejected, 1)
        XCTAssertFalse(session.isAuthenticated)
        XCTAssertFalse(link.allWrites.contains { $0.data == Data([0x0A, 0x00]) }, "no J-PAKE started")
    }

    /// Authenticated but not paired: ask for a clean full bootstrap (DexcomG7AuthSession.swift:422-434).
    func test_authenticatedButUnpairedRequestsFullBootstrap() {
        let key = G7Random.bytes(16)
        let sensor = G7SensorSimulator(pairingCode: "1234")
        sensor.confirmedKeys[0x02] = key
        sensor.shortAuthPairedByte = 0x02
        let (session, delegate, _, driver) = makeSession(code: "1234", savedKey: key, sensor: sensor)
        session.begin()
        driver.pump()
        XCTAssertEqual(delegate.needsFullBootstrap, 1)
        XCTAssertFalse(session.isAuthenticated)
    }

    func test_missingPairingCodeFails() {
        let sensor = G7SensorSimulator(pairingCode: "1234")
        let (session, delegate, _, driver) = makeSession(code: nil, savedKey: nil, sensor: sensor)
        session.begin()
        driver.pump()
        XCTAssertEqual(delegate.failures, [.missingPairingCode])
    }

    /// xDrip Tests/DexcomG7CalibrationTests.swift:296-327 (`authenticationStatusAction`), unchanged.
    func test_statusActionTable() {
        XCTAssertEqual(G7AuthSession.statusAction(usingFullBootstrap: false, authenticated: true, paired: true), .continueAuthentication)
        XCTAssertEqual(G7AuthSession.statusAction(usingFullBootstrap: false, authenticated: true, paired: false), .startFullBootstrap)
        XCTAssertEqual(G7AuthSession.statusAction(usingFullBootstrap: false, authenticated: false, paired: true), .rejectSavedKey)
        XCTAssertEqual(G7AuthSession.statusAction(usingFullBootstrap: false, authenticated: false, paired: false), .rejectSavedKey)
        XCTAssertEqual(G7AuthSession.statusAction(usingFullBootstrap: true, authenticated: true, paired: false), .continueAuthentication)
        XCTAssertEqual(G7AuthSession.statusAction(usingFullBootstrap: true, authenticated: false, paired: true), .reject)
    }

    /// Protocol violations fail loudly instead of hanging.
    func test_outOfOrderAndMalformedPacketsFail() {
        let sensor = G7SensorSimulator(pairingCode: "1234")
        let (session, delegate, link, _) = makeSession(code: "1234", savedKey: nil, sensor: sensor)
        session.begin()
        link.notifying = [.authStream, .receiveAuthentication]
        session.notificationStateChanged(for: .authStream, isNotifying: true)
        session.notificationStateChanged(for: .receiveAuthentication, isNotifying: true)
        session.receiveAuthentication(Data([0x0A, 0x01, 0x00]))
        XCTAssertEqual(delegate.failures, [.pakeRejectedBySensor])

        let (second, secondDelegate, secondLink, _) = makeSession(code: "1234", savedKey: nil, sensor: sensor)
        second.begin()
        secondLink.notifying = [.authStream, .receiveAuthentication]
        second.notificationStateChanged(for: .receiveAuthentication, isNotifying: true)
        second.notificationStateChanged(for: .authStream, isNotifying: true)
        second.receiveAuthentication(Data([0x0B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
        XCTAssertEqual(secondDelegate.failures, [.certificateExchangeRejected], "certificate before J-PAKE finished")
        second.receiveAuthentication(Data([0xEE]))
        XCTAssertEqual(secondDelegate.failures.count, 1, "nothing more after a failure")
    }

    func test_cancelInvalidatesScheduledWrites() {
        let sensor = G7SensorSimulator(pairingCode: "1234")
        let (session, _, link, _) = makeSession(code: "1234", savedKey: nil, sensor: sensor)
        session.begin()
        link.notifying = [.authStream, .receiveAuthentication]
        session.notificationStateChanged(for: .authStream, isNotifying: true)
        session.notificationStateChanged(for: .receiveAuthentication, isNotifying: true)
        for (characteristic, value) in sensor.handleWrite(link.writes.removeFirst().data, to: .receiveAuthentication) {
            if characteristic == .authStream { session.receiveAuthStream(value) } else { session.receiveAuthentication(value) }
        }
        XCTAssertFalse(link.scheduled.isEmpty)
        session.cancel()
        link.scheduled.forEach { $0.action() }
        XCTAssertTrue(link.writes.isEmpty, "a delayed write from an ended connection never reaches the link")
    }
}
