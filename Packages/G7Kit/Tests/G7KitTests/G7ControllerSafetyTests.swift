// Original to Sensor (no ported code).

import CoreBluetooth
import GlucoseCore
import XCTest
@testable import G7Kit

/// Controller-level tests for the WS1 safety-review findings (B1, B2, M3 and minors).
final class G7ControllerSafetyTests: XCTestCase {
    // MARK: - B1

    /// Probe P1b: during a new pairing with the WRONG code, another app's `05 01 01` on the shared
    /// link must not authenticate us: nothing is published and no identity or key is saved.
    func test_S2_unsolicitedAuthStatusDuringNewPairingPublishesNothing() throws {
        let harness = ControllerHarness(sensorCode: "9999")
        try harness.controller.start(pairingCode: "1234")
        harness.controller.didDiscover(name: harness.sensorName, identifier: harness.identifier)
        let link = FakeLink(identifier: harness.identifier)
        harness.controller.didConnect(link: link, availableCharacteristics: Set(G7Characteristic.allCases))
        harness.controller.valueUpdated(for: .receiveAuthentication, value: Data([0x05, 0x01, 0x01]))
        link.notifying.insert(.writeControl)
        harness.controller.notificationStateChanged(for: .writeControl, isNotifying: true, error: nil)
        harness.controller.valueUpdated(for: .writeControl, value: harness.currentGlucose(111))
        XCTAssertTrue(harness.readings.isEmpty)
        XCTAssertNil(harness.record?.serial)
        XCTAssertNil(harness.record?.sharedKey)
        XCTAssertFalse(link.allWrites.contains { $0.data == Data([0x4E]) }, "no GetData without our own authentication")
    }

    /// B1: a `05` rejection seen after we authenticated is surfaced and ends the connection; the key
    /// is re-checked by the next connection's own status, which here succeeds again.
    func test_S2_rejectionAfterAuthenticationIsSurfacedAndRechecked() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(120))
        harness.clock.advance(300)
        let link = harness.connection(glucose: harness.currentGlucose(121), disconnect: false)
        harness.controller.valueUpdated(for: .receiveAuthentication, value: Data([0x05, 0x00, 0x02]))
        XCTAssertEqual(harness.states.last, .failed(reason: G7FailureReason.savedKeyRejected))
        XCTAssertEqual(link.disconnectCount, 1)
        XCTAssertEqual(harness.record?.requiresNewPairing, false, "decided by the next solicited status")
        harness.controller.didDisconnect(peripheralIdentifier: harness.identifier)
        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(122))
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(120), .mgdl(121), .mgdl(122)])
        if case .active = harness.states.last {} else { XCTFail("recovered: \(harness.states)") }
    }

    // MARK: - B2 (D28)

    /// Probe P2: `currentSession` survives the ~5-minute disconnect and an app relaunch (persisted),
    /// and the next connection continues the same session.
    func test_S2_currentSessionSurvivesDisconnectAndRelaunch() throws {
        let store = G7InMemoryCredentialStore()
        let first = ControllerHarness(store: store)
        XCTAssertNil(first.controller.currentSession, "nil before the first authenticated reading")
        try first.pair(glucose: first.currentGlucose(120))
        let session = try XCTUnwrap(first.controller.currentSession)
        XCTAssertEqual(session.start, first.sessionStart)
        XCTAssertEqual(session.serial, "DXCM4F-1A2B3C4D")

        let relaunched = ControllerHarness(store: store, relaunchOf: first)
        relaunched.controller.emitInitialState() // what G7CGMSource.init does at launch
        XCTAssertEqual(relaunched.controller.currentSession, session, "restored from the pairing record before any connection")
        try relaunched.controller.start(pairingCode: nil)
        XCTAssertEqual(relaunched.controller.currentSession, session)
        relaunched.clock.advance(300)
        relaunched.connection(glucose: relaunched.currentGlucose(125))
        XCTAssertEqual(relaunched.controller.currentSession, session)
        XCTAssertEqual(relaunched.readings.map(\.value), [.mgdl(125)])
    }

    /// Probe P2b: a failed sensor ends the session (also after a relaunch); separately, the grace end
    /// ends it with no connection at all (20 days later).
    func test_S2_currentSessionEndsOnFailureAndAfterGrace() throws {
        let failing = ControllerHarness()
        try failing.pair(glucose: failing.currentGlucose(120))
        failing.clock.advance(300)
        failing.connection(glucose: failing.currentGlucose(nil, state: 0x19))
        XCTAssertEqual(failing.states.last, .error(code: 0x19, description: "Sensor failed"))
        XCTAssertNil(failing.controller.currentSession)
        XCTAssertEqual(failing.record?.sessionEnded, true)
        let relaunchedFailing = ControllerHarness(store: failing.store, relaunchOf: failing)
        relaunchedFailing.controller.emitInitialState()
        XCTAssertNil(relaunchedFailing.controller.currentSession)

        let aging = ControllerHarness()
        try aging.pair(glucose: aging.currentGlucose(120))
        XCTAssertNotNil(aging.controller.currentSession)
        aging.clock.advance(20 * 86_400)
        XCTAssertNil(aging.controller.currentSession)
    }

    /// B2: unsupported sensor, a rejected key, and forget all leave no session.
    func test_S2_currentSessionNilForUnsupportedRejectedAndForgotten() throws {
        let fifteenDay = ControllerHarness()
        fifteenDay.sensor.extendedVersionResponse = Fixture.fifteenDayExtendedVersion
        try fifteenDay.pair(glucose: fifteenDay.currentGlucose(120))
        XCTAssertTrue(fifteenDay.readings.isEmpty, "minor 1: not even one reading from a 15-day sensor")
        XCTAssertNil(fifteenDay.controller.currentSession)
        XCTAssertEqual(fifteenDay.states.last, .failed(reason: G7FailureReason.unsupportedSensor))

        let rejected = ControllerHarness()
        try rejected.pair(glucose: rejected.currentGlucose(120))
        rejected.sensor.confirmedKeys[0x02] = G7Random.bytes(16)
        rejected.clock.advance(300)
        rejected.connection(glucose: rejected.currentGlucose(121))
        XCTAssertNil(rejected.controller.currentSession)

        let forgotten = ControllerHarness()
        try forgotten.pair(glucose: forgotten.currentGlucose(120))
        forgotten.controller.forget()
        XCTAssertNil(forgotten.controller.currentSession)
    }

    // MARK: - Minor 1

    /// `52` is written before GetData until the session length is known, then never again.
    func test_S2_sessionLengthIsRequestedBeforeGetData() throws {
        let harness = ControllerHarness()
        let first = try harness.pair(glucose: harness.currentGlucose(120))
        let firstControl = first.allWrites.filter { $0.characteristic == .writeControl }.map(\.data)
        XCTAssertEqual(firstControl, [Data([0x52]), Data([0x4E])])
        harness.clock.advance(300)
        let second = harness.connection(glucose: harness.currentGlucose(121))
        XCTAssertEqual(second.allWrites.filter { $0.characteristic == .writeControl }.map(\.data), [Data([0x4E])])

        // No answer usable: readings are withheld and the reason is surfaced.
        let silent = ControllerHarness()
        silent.sensor.extendedVersionResponse = Data([0x52, 0x00])
        try silent.pair(glucose: silent.currentGlucose(120))
        XCTAssertTrue(silent.readings.isEmpty)
        XCTAssertEqual(silent.states.last, .failed(reason: G7FailureReason.sessionLengthUnknown))
    }

    // MARK: - M3

    /// A credential store that cannot be read is a visible failure, never "not paired".
    func test_S5_unreadableCredentialsSurfaceAsFailure() {
        var states: [SensorState] = []
        let controller = G7Controller(
            store: UnreadableCredentialStore(), diagnostics: RecordingDiagnosticLog(), now: { Date() }, slot: .mobileApp,
            output: G7Controller.Output(reading: { _ in }, state: { states.append($0) }, calibration: { _ in })
        )
        controller.emitInitialState()
        XCTAssertEqual(states, [.failed(reason: G7FailureReason.credentialsUnavailable)])
        XCTAssertThrowsError(try controller.start(pairingCode: nil)) { error in
            guard case .credentialStoreFailed = error as? G7StartError else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(states.contains(.notPaired))
    }

    // MARK: - Minor 3

    /// A found sensor that never connects is given up after the timeout and scanning resumes; it is
    /// not tried again during this pairing.
    func test_newPairingCandidateThatNeverConnectsTimesOut() throws {
        let harness = ControllerHarness()
        try harness.controller.start(pairingCode: "1234")
        let scans = harness.central.scanCount
        harness.controller.didDiscover(name: "DXCM11", identifier: harness.identifier)
        XCTAssertEqual(harness.central.scheduled.first?.delay, G7Controller.candidateConnectTimeout)
        harness.central.fireScheduled()
        XCTAssertEqual(harness.central.cancelRequests, [harness.identifier])
        XCTAssertEqual(harness.central.scanCount, scans + 1)
        let connects = harness.central.connectRequests.count
        harness.controller.didDiscover(name: "DXCM11", identifier: harness.identifier)
        XCTAssertEqual(harness.central.connectRequests.count, connects, "timed-out sensor excluded")
        // A timer from an attempt that did connect does nothing.
        harness.controller.didDiscover(name: harness.sensorName, identifier: UUID(uuidString: "2B3C4D5E-0000-4000-8000-000000000002")!)
        harness.connection(glucose: harness.currentGlucose(120), peripheral: UUID(uuidString: "2B3C4D5E-0000-4000-8000-000000000002")!)
        let cancels = harness.central.cancelRequests.count
        harness.central.fireScheduled()
        XCTAssertEqual(harness.central.cancelRequests.count, cancels)
        XCTAssertEqual(harness.readings.count, 1)
    }

    /// Connect/disconnect callbacks for peripherals that are neither the paired sensor nor the
    /// candidate are ignored.
    func test_eventsFromOtherPeripheralsAreIgnored() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(120))
        let stranger = FakeLink(identifier: UUID())
        harness.controller.didConnect(link: stranger, availableCharacteristics: Set(G7Characteristic.allCases))
        XCTAssertEqual(stranger.disconnectCount, 1)
        XCTAssertTrue(stranger.notifyRequests.isEmpty, "no session started with it")

        harness.clock.advance(300)
        let link = harness.connection(glucose: harness.currentGlucose(121), disconnect: false)
        harness.controller.didDisconnect(peripheralIdentifier: stranger.peripheralIdentifier)
        harness.controller.valueUpdated(for: .writeControl, value: Data([0x59]))
        XCTAssertEqual(link.disconnectCount, 0)
        XCTAssertTrue(harness.log.messages.contains { $0.contains("unrelated peripheral ignored") })
    }
}

/// A Keychain that refuses to be read (e.g. before the first unlock after a restart).
struct UnreadableCredentialStore: G7CredentialStore {
    struct Locked: Error {}
    func load() throws -> G7PairingRecord? { throw Locked() }
    func save(_ record: G7PairingRecord) throws { throw Locked() }
    func delete() throws { throw Locked() }
}

/// Minor 5: CoreBluetooth → G7Kit mappings, without a CBCentralManager.
final class G7CoreBluetoothMappingTests: XCTestCase {
    func test_S5_managerStatesMapToBluetoothPower() {
        XCTAssertEqual(G7CoreBluetoothCentral.power(.poweredOn), .poweredOn)
        XCTAssertEqual(G7CoreBluetoothCentral.power(.poweredOff), .poweredOff)
        XCTAssertEqual(G7CoreBluetoothCentral.power(.unauthorized), .unauthorized)
        XCTAssertEqual(G7CoreBluetoothCentral.power(.unsupported), .unsupported)
        XCTAssertEqual(G7CoreBluetoothCentral.power(.resetting), .resetting)
        XCTAssertEqual(G7CoreBluetoothCentral.power(.unknown), .unknown)
    }

    func test_pairingErrorsMapToLinkErrors() {
        func map(_ domain: String, _ code: Int) -> G7LinkError {
            G7CoreBluetoothCentral.linkError(NSError(domain: domain, code: code))
        }
        XCTAssertEqual(map(CBATTErrorDomain, CBATTError.Code.insufficientAuthentication.rawValue), .pairingNotCompleted)
        XCTAssertEqual(map(CBATTErrorDomain, CBATTError.Code.insufficientEncryption.rawValue), .pairingNotCompleted)
        XCTAssertEqual(map(CBErrorDomain, CBError.Code.encryptionTimedOut.rawValue), .pairingNotCompleted)
        XCTAssertEqual(map(CBErrorDomain, CBError.Code.peerRemovedPairingInformation.rawValue), .bondRemovedBySensor)
        guard case .other = map(CBATTErrorDomain, CBATTError.Code.writeNotPermitted.rawValue) else { return XCTFail() }
        guard case .other = map(CBErrorDomain, CBError.Code.connectionTimeout.rawValue) else { return XCTFail() }
    }
}
