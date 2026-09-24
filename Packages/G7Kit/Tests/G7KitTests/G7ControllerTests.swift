// Original to Sensor (no ported code).

import GlucoseCore
import XCTest
@testable import G7Kit

final class G7ControllerTests: XCTestCase {
    /// New sensor: scan → connect → full J-PAKE → key, identity and serial stored → data.
    func test_pairingStoresKeyIdentityAndSerialThenPublishes() throws {
        let harness = ControllerHarness()
        let link = try harness.pair(glucose: harness.currentGlucose(123))
        XCTAssertEqual(harness.central.scanCount, 1)
        XCTAssertTrue(link.allWrites.contains { $0.data == Data([0x0A, 0x00]) }, "full bootstrap")
        let record = try XCTUnwrap(harness.record)
        XCTAssertEqual(record.sharedKey.map([UInt8].init), harness.sensor.confirmedKeys[0x02])
        XCTAssertEqual(record.sensorName, "DXCM4F")
        XCTAssertEqual(record.peripheralIdentifier, harness.identifier)
        XCTAssertEqual(record.serial, "DXCM4F-1A2B3C4D")
        XCTAssertEqual(record.reportedSessionLength, 907_200, "0x52 requested and stored")
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(123)])
        XCTAssertEqual(harness.readings.first?.sensorSerial, "DXCM4F-1A2B3C4D")
        XCTAssertEqual(harness.states.first, .searching)
        XCTAssertTrue(harness.states.contains(.authenticating))
        if case .active = harness.states.last {} else { XCTFail("expected active, got \(harness.states)") }
        XCTAssertEqual(harness.controller.heartbeatTarget?.peripheralIdentifier, harness.identifier)
        XCTAssertEqual(harness.controller.heartbeatTarget?.characteristicUUID, "F8083535-849E-531C-C594-30F1F86A4EA5")
        XCTAssertEqual(harness.controller.heartbeatTarget?.serviceUUID, "F8083532-849E-531C-C594-30F1F86A4EA5")
        XCTAssertTrue(harness.log.messages.allSatisfy { !$0.contains("1234") }, "the pairing code is never logged")
    }

    /// Later wakes: pending reconnect, short authentication, one GetData, no repeated 0x52.
    func test_reconnectUsesPendingConnectAndShortAuthentication() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(123))
        XCTAssertEqual(harness.central.connectRequests.last, harness.identifier, "pending connect after disconnect")
        harness.clock.advance(300)
        let link = harness.connection(glucose: harness.currentGlucose(125))
        XCTAssertFalse(link.allWrites.contains { $0.data == Data([0x0A, 0x00]) }, "no J-PAKE on reconnect")
        XCTAssertEqual(link.allWrites.filter { $0.data == Data([0x4E]) }.count, 1)
        XCTAssertFalse(link.allWrites.contains { $0.data == Data([0x52]) }, "lifetime already known")
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(123), .mgdl(125)])
        XCTAssertEqual(harness.states.filter { $0 == .authenticating }.count, 1, "no status flicker on routine reconnects")
    }

    /// S2: nothing is published from a session that did not authenticate — a rejected saved key,
    /// and Write_Control/Backfill data that arrives before authentication completes.
    func test_S2_unauthenticatedSessionEmitsNothing() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(123))
        let before = harness.readings.count
        harness.sensor.confirmedKeys[0x02] = G7Random.bytes(16) // another collector took slot 2
        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(150), backfill: [Fixture.backfill(timestamp: harness.sensorClock - 600, glucose: 140)])
        XCTAssertEqual(harness.readings.count, before)
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.savedKeyRejected))
        XCTAssertEqual(harness.record?.requiresNewPairing, true)
        XCTAssertNil(harness.controller.currentSession)

        // Data injected before authentication is ignored.
        let fresh = ControllerHarness()
        try fresh.controller.start(pairingCode: "1234")
        fresh.controller.didDiscover(name: fresh.sensorName, identifier: fresh.identifier)
        let link = FakeLink(identifier: fresh.identifier)
        fresh.controller.didConnect(link: link, availableCharacteristics: Set(G7Characteristic.allCases))
        fresh.controller.valueUpdated(for: .writeControl, value: fresh.currentGlucose(99))
        fresh.controller.valueUpdated(for: .backfill, value: Fixture.backfill(timestamp: fresh.sensorClock - 300, glucose: 98))
        fresh.controller.valueUpdated(for: .writeControl, value: Data([0x59]))
        fresh.controller.didDisconnect(peripheralIdentifier: fresh.identifier)
        XCTAssertTrue(fresh.readings.isEmpty)
        XCTAssertTrue(fresh.log.messages.contains { $0.contains("before authentication ignored") })
    }

    /// The iOS pairing prompt: cancel → clear failure state, disconnect, no data; accept on the
    /// next wake → data flows and the state recovers.
    func test_pairingPromptCancelThenAccept() throws {
        let harness = ControllerHarness()
        try harness.controller.start(pairingCode: "1234")
        harness.controller.didDiscover(name: harness.sensorName, identifier: harness.identifier)
        let cancelled = harness.connection(glucose: harness.currentGlucose(123), failingNotify: [.writeControl: .pairingNotCompleted])
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.bluetoothPairingNotCompleted))
        XCTAssertEqual(cancelled.disconnectCount, 1)
        XCTAssertTrue(harness.readings.isEmpty)
        XCTAssertNotNil(harness.record?.sharedKey, "ownership was confirmed before the prompt")

        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(130))
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(130)])
        if case .active = harness.states.last {} else { XCTFail("expected recovery, got \(harness.states)") }

        let removed = ControllerHarness()
        try removed.pair(glucose: removed.currentGlucose(100))
        removed.clock.advance(300)
        removed.connection(glucose: removed.currentGlucose(101), failingNotify: [.writeControl: .bondRemovedBySensor])
        XCTAssertEqual(removed.states.last, .failed(G7FailureReason.bondRemovedBySensor))
    }

    /// Wrong code: that sensor is excluded and scanning continues; the old sensor is skipped too.
    func test_wrongPairingCodeExcludesTheSensorAndKeepsScanning() throws {
        let harness = ControllerHarness(sensorCode: "9999")
        try harness.pair(code: "1234", glucose: harness.currentGlucose(123))
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.pairingCodeRejected))
        XCTAssertNil(harness.record?.sharedKey)
        XCTAssertEqual(harness.central.scanCount, 2, "scans again after the failed candidate")
        let connectsBefore = harness.central.connectRequests.count
        harness.controller.didDiscover(name: harness.sensorName, identifier: harness.identifier)
        XCTAssertEqual(harness.central.connectRequests.count, connectsBefore, "rejected sensor is not retried")
        harness.controller.didDiscover(name: "DX02AB", identifier: UUID())
        XCTAssertEqual(harness.central.connectRequests.count, connectsBefore, "ONE+ is not a G7 10-day sensor")
        harness.controller.didDiscover(name: "DXCM7Q", identifier: UUID())
        XCTAssertEqual(harness.central.connectRequests.count, connectsBefore + 1)
    }

    /// S5: Bluetooth off / unauthorized always surfaces; power-on restores the sensor state.
    func test_S5_bluetoothUnavailableSurfacesAndRecovers() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(123))
        let active = try XCTUnwrap(harness.states.last)
        harness.controller.bluetoothPowerChanged(.poweredOff)
        XCTAssertEqual(harness.states.last, .bluetoothUnavailable(.poweredOff))
        harness.controller.bluetoothPowerChanged(.unauthorized)
        XCTAssertEqual(harness.states.last, .bluetoothUnavailable(.unauthorized))
        harness.controller.bluetoothPowerChanged(.poweredOn)
        XCTAssertEqual(harness.states.last, active)
        XCTAssertEqual(harness.central.connectRequests.last, harness.identifier)
    }

    /// Bluetooth turned off mid-connection (no didDisconnect from CoreBluetooth): the cycle ends and
    /// power-on reconnects instead of waiting on a dead connection.
    func test_S5_powerOffDuringAConnectionStillReconnects() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(123))
        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(124), disconnect: false)
        harness.controller.bluetoothPowerChanged(.poweredOff)
        let before = harness.central.connectRequests.count
        harness.controller.bluetoothPowerChanged(.poweredOn)
        XCTAssertEqual(harness.central.connectRequests.count, before + 1)
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(123), .mgdl(124)])
    }

    /// A paired sensor found again under a new iOS identifier: reconnect to the new identifier from
    /// now on; the serial (and so every reading id) never changes.
    func test_S3_rediscoveredSensorKeepsItsSerial() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(123))
        let serial = try XCTUnwrap(harness.record?.serial)
        let newIdentifier = UUID()
        harness.controller.didDiscover(name: "DXCM4F", identifier: newIdentifier)
        XCTAssertEqual(harness.central.connectRequests.last, newIdentifier)
        harness.controller.didDiscover(name: "DXCM9Z", identifier: UUID())
        XCTAssertEqual(harness.central.connectRequests.last, newIdentifier, "another sensor's name is ignored")
        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(125), peripheral: newIdentifier)
        XCTAssertEqual(harness.record?.peripheralIdentifier, newIdentifier)
        XCTAssertEqual(harness.record?.serial, serial)
        XCTAssertEqual(Set(harness.readings.map(\.sensorSerial)), [serial])
    }

    func test_forgetSensorDeletesPairingAndReportsNotPaired() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(123))
        harness.controller.forget()
        XCTAssertNil(harness.record)
        XCTAssertEqual(harness.states.last, .notPaired)
        XCTAssertNil(harness.controller.heartbeatTarget)
        XCTAssertNil(harness.controller.currentSession)
        XCTAssertThrowsError(try harness.controller.start(pairingCode: "12a4")) {
            XCTAssertEqual($0 as? G7StartError, .invalidPairingCode)
        }
        try harness.controller.start(pairingCode: nil)
        XCTAssertEqual(harness.states.last, .notPaired)
    }

    /// Warm-up after pairing: the state says so and nothing is published until the sensor is OK.
    func test_S2_warmUpAfterPairingPublishesNothing() throws {
        let harness = ControllerHarness(sessionAge: 10 * 60)
        try harness.pair(glucose: harness.currentGlucose(88, state: 0x02))
        XCTAssertTrue(harness.readings.isEmpty)
        guard case .warmingUp(let endsAt) = harness.states.last else { return XCTFail("\(harness.states)") }
        XCTAssertEqual(endsAt, harness.sessionStart.addingTimeInterval(27 * 60))
    }

    /// Backfill after a gap arrives flagged, in order, after the live reading.
    func test_S3_backfillAfterGapIsPublishedFlaggedAndOrdered() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(123))
        harness.clock.advance(45 * 60)
        let current = harness.sensorClock
        let gap = (1...8).map { Fixture.backfill(timestamp: current - 5 - UInt32($0 * 300), glucose: UInt16(100 + $0)) }
        harness.connection(glucose: harness.currentGlucose(140), backfill: gap)
        let published = Array(harness.readings.dropFirst())
        XCTAssertEqual(published.first?.isBackfill, false)
        let backfill = Array(published.dropFirst())
        XCTAssertEqual(backfill.count, 8)
        XCTAssertTrue(backfill.allSatisfy(\.isBackfill))
        XCTAssertEqual(backfill.map(\.date), backfill.map(\.date).sorted())
    }
}

/// `G7CGMSource` with a fake central: the CGMSource stream rules.
final class G7CGMSourceTests: XCTestCase {
    private func makeSource(store: G7CredentialStore, clock: TestClock, central: FakeCentral) -> G7CGMSource {
        G7CGMSource(configuration: G7Configuration(), credentialStore: store, diagnostics: RecordingDiagnosticLog(), clock: { clock.now }) { _, _ in central }
    }

    /// Runs one sensor wake on the source's queue.
    private func connection(_ source: G7CGMSource, sensor: G7SensorSimulator, identifier: UUID, glucose: Data, backfill: [Data] = []) {
        source.withController { controller in
            sensor.beginConnection()
            sensor.glucoseResponse = glucose
            sensor.backfillFrames = backfill
            let link = FakeLink(identifier: identifier)
            let driver = LinkDriver(link: link, sensor: sensor,
                                    deliverNotify: { controller.notificationStateChanged(for: $0, isNotifying: $1, error: $2) },
                                    deliverValue: { controller.valueUpdated(for: $0, value: $1) })
            controller.didConnect(link: link, availableCharacteristics: Set(G7Characteristic.allCases))
            driver.pump()
            controller.didDisconnect(peripheralIdentifier: identifier)
        }
    }

    func test_initialStateIsTheFirstElement() async {
        let source = makeSource(store: G7InMemoryCredentialStore(), clock: TestClock(), central: FakeCentral())
        let first = await collect(source.state, count: 1)
        XCTAssertEqual(first, [.notPaired])
        XCTAssertEqual(source.acceptedCalibrationRange, 40...400)
        XCTAssertFalse(G7CGMSource.supportsStopSession)
        let session = await source.currentSession
        XCTAssertNil(session)
    }

    /// CGMSource rule: a 288-reading backfill burst (24 h) arrives complete.
    func test_backfillBurstOf288ReadingsArrivesComplete() async throws {
        let clock = TestClock()
        let central = FakeCentral()
        let source = makeSource(store: G7InMemoryCredentialStore(), clock: clock, central: central)
        let sensor = G7SensorSimulator(pairingCode: "1234")
        let identifier = UUID()
        let sessionStart = clock.now.addingTimeInterval(-5 * 86_400)
        try await source.start(pairingCode: "1234")
        source.withController { $0.bluetoothPowerChanged(.poweredOn); $0.didDiscover(name: "DXCM4F", identifier: identifier) }
        let sensorClock = UInt32(clock.now.timeIntervalSince(sessionStart))
        let backfill = (1...288).map { Fixture.backfill(timestamp: sensorClock - 5 - UInt32($0 * 300), glucose: UInt16(80 + $0 % 200)) }
        connection(source, sensor: sensor, identifier: identifier,
                   glucose: Fixture.glucose(sensorClock: sensorClock, age: 5, glucose: 111, state: 0x06), backfill: backfill)
        let readings = await collect(source.readings, count: 289)
        XCTAssertEqual(readings.count, 289)
        XCTAssertEqual(readings.filter(\.isBackfill).count, 288)
        XCTAssertEqual(Set(readings.map(\.id)).count, 289)
        let session = await source.currentSession
        XCTAssertEqual(session?.start, sessionStart)
        let target = await source.heartbeatTarget
        XCTAssertEqual(target?.peripheralIdentifier, identifier)
    }

    /// CGMSource rule: stop() does not finish the streams; start() resumes on the same instances.
    func test_stopThenStartKeepsDeliveringOnTheSameStreams() async throws {
        let clock = TestClock()
        let central = FakeCentral()
        let store = G7InMemoryCredentialStore()
        let source = makeSource(store: store, clock: clock, central: central)
        let sensor = G7SensorSimulator(pairingCode: "1234")
        let identifier = UUID()
        let sessionStart = clock.now.addingTimeInterval(-86_400)
        func glucose(_ mgdl: UInt16) -> Data {
            Fixture.glucose(sensorClock: UInt32(clock.now.timeIntervalSince(sessionStart)), age: 5, glucose: mgdl, state: 0x06)
        }
        let readings = source.readings
        try await source.start(pairingCode: "1234")
        source.withController { $0.bluetoothPowerChanged(.poweredOn); $0.didDiscover(name: "DXCM4F", identifier: identifier) }
        connection(source, sensor: sensor, identifier: identifier, glucose: glucose(101))

        await source.stop()
        XCTAssertEqual(central.cancelRequests.last, identifier)
        clock.advance(300)
        try await source.start(pairingCode: nil)
        connection(source, sensor: sensor, identifier: identifier, glucose: glucose(102))

        let delivered = await collect(readings, count: 2)
        XCTAssertEqual(delivered.map(\.value), [.mgdl(101), .mgdl(102)])
        XCTAssertEqual(store.loadedSerial, "DXCM4F-\(identifier.uuidString.prefix(8))")
    }

    func test_invalidPairingCodeThrows() async {
        let source = makeSource(store: G7InMemoryCredentialStore(), clock: TestClock(), central: FakeCentral())
        do {
            try await source.pair(code: "123")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? G7StartError, .invalidPairingCode)
        }
        await source.forgetSensor()
    }
}

private extension G7InMemoryCredentialStore {
    var loadedSerial: String? { (try? load())?.serial }
}
