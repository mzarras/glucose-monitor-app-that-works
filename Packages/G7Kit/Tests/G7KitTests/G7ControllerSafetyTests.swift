// Original to Sensor (no ported code).

import CoreBluetooth
import GlucoseCore
import os
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
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.rejectedAfterAuthentication), "not \"pair again\" yet")
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

    /// Probe P2b: a failed sensor (reported on two connections, N1) ends the session, also after a
    /// relaunch; separately, the grace end ends it with no connection at all (20 days later).
    func test_S2_currentSessionEndsOnFailureAndAfterGrace() throws {
        let failing = ControllerHarness()
        try failing.pair(glucose: failing.currentGlucose(120))
        failing.clock.advance(300)
        failing.connection(glucose: failing.currentGlucose(nil, state: 0x19))
        XCTAssertEqual(failing.states.last, .error(code: 0x19, description: "Sensor failed"))
        XCTAssertNotNil(failing.controller.currentSession, "one report is not enough")
        failing.clock.advance(300)
        failing.connection(glucose: failing.currentGlucose(nil, state: 0x19))
        XCTAssertEqual(failing.states.last, .failed(G7FailureReason.sensorFailed))
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

    // MARK: - N2

    /// Probe P10: after a post-authentication `05` rejection nothing more from the connection is
    /// published before `didDisconnect` (live, backfill, a batch received before the rejection).
    func test_S2_nothingIsPublishedAfterARejectionBeforeTheDisconnect() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(120))
        harness.clock.advance(300)
        let link = harness.connection(glucose: harness.currentGlucose(121), disconnect: false)
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(120), .mgdl(121)])
        harness.controller.valueUpdated(for: .backfill, value: Fixture.backfill(timestamp: harness.sensorClock - 150, glucose: 170))
        harness.controller.valueUpdated(for: .receiveAuthentication, value: Data([0x05, 0x00, 0x02]))
        XCTAssertEqual(link.disconnectCount, 1, "the disconnect is requested after the cycle is finished")
        harness.clock.advance(1)
        harness.controller.valueUpdated(for: .writeControl, value: Fixture.glucose(sensorClock: harness.sensorClock + 300, age: 2, glucose: 180, state: 0x06))
        harness.controller.valueUpdated(for: .backfill, value: Fixture.backfill(timestamp: harness.sensorClock - 100, glucose: 175))
        harness.controller.valueUpdated(for: .writeControl, value: Data([0x59]))
        harness.controller.didDisconnect(peripheralIdentifier: harness.identifier)
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(120), .mgdl(121)])
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.rejectedAfterAuthentication))
        XCTAssertTrue(harness.log.messages.contains { $0.contains("of a rejected connection discarded") })
    }

    /// Probe P1c at the controller: our key was evicted; another app's `05 01 01` lands between our
    /// `04` and the sensor's real rejection. Nothing is published, the connection ends at the real
    /// rejection, and the next connection's own status asks to pair again.
    func test_S2_spoofedStatusBeforeTheRealRejectionPublishesNothing() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(120))
        harness.sensor.confirmedKeys[0x02] = G7Random.bytes(16)
        harness.clock.advance(300)
        let link = harness.connection(glucose: harness.currentGlucose(121), disconnect: false) { [unowned harness] data, characteristic in
            guard characteristic == .receiveAuthentication, data.first == 0x04 else { return }
            harness.controller.valueUpdated(for: .receiveAuthentication, value: Data([0x05, 0x01, 0x01]))
        }
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.rejectedAfterAuthentication))
        XCTAssertEqual(link.disconnectCount, 1)
        harness.controller.valueUpdated(for: .writeControl, value: harness.currentGlucose(122))
        harness.controller.valueUpdated(for: .backfill, value: Fixture.backfill(timestamp: harness.sensorClock - 305, glucose: 121))
        harness.controller.valueUpdated(for: .writeControl, value: Data([0x59]))
        harness.controller.didDisconnect(peripheralIdentifier: harness.identifier)
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(120)])

        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(123))
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.savedKeyRejected))
        XCTAssertEqual(harness.record?.requiresNewPairing, true)
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(120)])
    }

    /// D35 (pinned residual P1c risk, accepted): if another app's genuine `0x4E` lands inside the
    /// milliseconds between a spoofed `05 01 01` and the sensor's real rejection of our `04`, that
    /// one live reading is published (it is real data from this sensor, but it was not authenticated
    /// to us). Everything else from the window is not: backfill is discarded, and nothing after the
    /// real rejection is forwarded. If this test starts failing because the reading is no longer
    /// published, the residual risk is gone: update D35 and docs/g7-protocol.md §3.1.
    func test_S2_residualP1cRaceIsBoundedToOneLiveReading() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(120))
        harness.sensor.confirmedKeys[0x02] = G7Random.bytes(16)
        harness.clock.advance(300)
        let othersReading = harness.currentGlucose(121)
        let othersBackfill = Fixture.backfill(timestamp: harness.sensorClock - 150, glucose: 119) // a new timestamp
        let link = harness.connection(glucose: nil, disconnect: false) { [unowned harness] data, characteristic in
            if characteristic == .receiveAuthentication, data.first == 0x04 {
                harness.controller.valueUpdated(for: .receiveAuthentication, value: Data([0x05, 0x01, 0x01])) // spoof
            }
            if characteristic == .writeControl, data == Data([0x4E]) {
                // The other app's GetData answer and backfill, before the sensor's real `05 02 02`.
                harness.controller.valueUpdated(for: .writeControl, value: othersReading)
                harness.controller.valueUpdated(for: .backfill, value: othersBackfill)
            }
        }
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(120), .mgdl(121)], "the one residual live reading")
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.rejectedAfterAuthentication))
        XCTAssertEqual(link.disconnectCount, 1)
        harness.controller.valueUpdated(for: .writeControl, value: Data([0x59]))
        harness.controller.didDisconnect(peripheralIdentifier: harness.identifier)
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(120), .mgdl(121)], "the window's backfill is discarded")

        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(122))
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.savedKeyRejected))
        XCTAssertEqual(harness.readings.count, 2)
    }

    /// Probe P9: the rejection recurs while our own authentication keeps succeeding: the status names
    /// the likely cause (another app) and never says "pair again"; a clean connection resets it.
    func test_S5_recurringRejectionAfterAuthenticationNamesAnotherApp() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(120))
        var reasons: [SensorState?] = []
        for value: UInt16 in [121, 122, 123] {
            harness.clock.advance(300)
            harness.connection(glucose: harness.currentGlucose(value), disconnect: false)
            harness.controller.valueUpdated(for: .receiveAuthentication, value: Data([0x05, 0x00, 0x02]))
            harness.controller.didDisconnect(peripheralIdentifier: harness.identifier)
            reasons.append(harness.states.last)
        }
        XCTAssertEqual(reasons, [
            .failed(G7FailureReason.rejectedAfterAuthentication),
            .failed(G7FailureReason.otherAppRejected),
            .failed(G7FailureReason.otherAppRejected),
        ])
        XCTAssertFalse(harness.states.contains(.failed(G7FailureReason.savedKeyRejected)))
        XCTAssertEqual(harness.record?.requiresNewPairing, false)
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(120), .mgdl(121), .mgdl(122), .mgdl(123)])
        XCTAssertNotEqual(G7FailureReason.otherAppRejected, G7FailureReason.savedKeyRejected)

        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(124))
        if case .active = harness.states.last {} else { XCTFail("clean connection: \(harness.states)") }
        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(125), disconnect: false)
        harness.controller.valueUpdated(for: .receiveAuthentication, value: Data([0x05, 0x00, 0x02]))
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.rejectedAfterAuthentication), "streak reset by the clean connection")
    }

    // MARK: - N1 (D28)

    /// Probe P8b: one status-0 "stopped" report is shown but does not end the session; the next OK
    /// reading is published, the status is active and the session is still there.
    func test_S5_oneEndReportDoesNotEndTheSession() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(120))
        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(nil, state: 0x01))
        XCTAssertEqual(harness.states.last, .error(code: 1, description: "Session stopped"))
        XCTAssertNotNil(harness.controller.currentSession)
        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(125))
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(120), .mgdl(125)])
        if case .active = harness.states.last {} else { XCTFail("expected active: \(harness.states)") }
        XCTAssertNotNil(harness.controller.currentSession)
        XCTAssertNil(harness.record?.sessionEnd)
    }

    /// N1: the end reported on two connections is latched and persisted; afterwards an OK packet shows
    /// the end (never active), publishes nothing, and the same holds after a relaunch and after
    /// Bluetooth is switched off and on.
    func test_S5_latchedEndStaysVisibleAndPersists() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(120))
        for _ in 0..<2 {
            harness.clock.advance(300)
            harness.connection(glucose: harness.currentGlucose(nil, state: 0x19))
        }
        let ended = SensorState.failed(G7FailureReason.sensorFailed)
        XCTAssertEqual(harness.states.last, ended)
        XCTAssertEqual(harness.record?.sessionEnd, .sensorFailed)
        XCTAssertNil(harness.controller.currentSession)
        let emittedBefore = harness.states.count

        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(130))
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(120)])
        XCTAssertFalse(harness.states[emittedBefore...].contains { if case .active = $0 { return true } else { return false } })
        XCTAssertEqual(harness.states.last, ended)
        harness.controller.bluetoothPowerChanged(.poweredOff)
        harness.controller.bluetoothPowerChanged(.poweredOn)
        XCTAssertEqual(harness.states.last, ended)
        XCTAssertThrowsError(try harness.controller.submitCalibration(CalibrationRequest(mgdl: 120, takenAt: harness.clock.now)))

        let relaunched = ControllerHarness(store: harness.store, relaunchOf: harness)
        relaunched.controller.emitInitialState()
        XCTAssertEqual(relaunched.states.last, ended)
        XCTAssertNil(relaunched.controller.currentSession)
        try relaunched.controller.start(pairingCode: nil)
        relaunched.clock.advance(300)
        relaunched.connection(glucose: relaunched.currentGlucose(131))
        XCTAssertTrue(relaunched.readings.isEmpty)
        XCTAssertFalse(relaunched.states.contains { if case .active = $0 { return true } else { return false } })
        XCTAssertEqual(relaunched.states.last, ended)
    }

    /// Probe P8c with relaunch: iOS terminates the app between every sensor wake. The first failed
    /// report is persisted, so the second one (after a relaunch) latches the end.
    func test_S5_endLatchesWhenTheAppIsRelaunchedBetweenReports() throws {
        var harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(120))
        for report in 1...2 {
            let relaunched = ControllerHarness(store: harness.store, relaunchOf: harness)
            relaunched.controller.emitInitialState()
            try relaunched.controller.start(pairingCode: nil)
            relaunched.clock.advance(300)
            relaunched.connection(glucose: relaunched.currentGlucose(nil, state: 0x19))
            harness = relaunched
            if report == 1 {
                XCTAssertEqual(harness.record?.unconfirmedSessionEnd?.end, .sensorFailed, "persisted")
                XCTAssertNil(harness.record?.sessionEnd)
                XCTAssertNotNil(harness.controller.currentSession)
            }
        }
        XCTAssertEqual(harness.record?.sessionEnd, .sensorFailed)
        XCTAssertNil(harness.record?.unconfirmedSessionEnd)
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.sensorFailed))
        XCTAssertNil(harness.controller.currentSession)
    }

    /// Last minor: the save that clears a first end report fails, the app is relaunched with the stale
    /// report, and hours later the sensor reports an end once: that single report does not latch.
    func test_S5_staleRestoredEndReportCannotLatchWithOneLaterReport() throws {
        let store = FlakyCredentialStore()
        let harness = ControllerHarness(store: store)
        try harness.pair(glucose: harness.currentGlucose(120))
        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(nil, state: 0x19))
        XCTAssertNotNil(harness.record?.unconfirmedSessionEnd)
        store.failSaves = true
        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(121)) // clears it in memory only
        store.failSaves = false
        XCTAssertNotNil(harness.record?.unconfirmedSessionEnd, "the clearing save failed")

        let relaunched = ControllerHarness(store: store, relaunchOf: harness)
        relaunched.controller.emitInitialState()
        try relaunched.controller.start(pairingCode: nil)
        relaunched.clock.advance(2 * 3_600)
        relaunched.connection(glucose: relaunched.currentGlucose(nil, state: 0x19))
        XCTAssertNil(relaunched.record?.sessionEnd, "one report after the stale one does not end the session")
        XCTAssertNotNil(relaunched.controller.currentSession)
        XCTAssertEqual(relaunched.states.last, .error(code: 0x19, description: "Sensor failed"))
        relaunched.clock.advance(300)
        relaunched.connection(glucose: relaunched.currentGlucose(nil, state: 0x19))
        XCTAssertEqual(relaunched.record?.sessionEnd, .sensorFailed, "a real end latches at the next wake")
    }

    // MARK: - D37 M1: pair again

    /// The sensor refused this phone (another device took the slot); "Pair again" with the code runs
    /// a full J-PAKE against the same sensor, keeps its serial and session, replaces the key, and
    /// readings resume.
    func test_S5_pairAgainReconnectsToTheSameSensor() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(120))
        let before = try XCTUnwrap(harness.record)
        let session = try XCTUnwrap(harness.controller.currentSession)
        harness.sensor.confirmedKeys[0x02] = G7Random.bytes(16)
        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(121))
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.savedKeyRejected))
        XCTAssertEqual(harness.record?.requiresNewPairing, true)

        let connectsBefore = harness.central.connectRequests.count
        try harness.controller.pairAgain(pairingCode: "1234")
        XCTAssertEqual(harness.central.connectRequests.dropFirst(connectsBefore).last, harness.identifier, "a connect to the stored sensor")
        XCTAssertEqual(harness.states.last, .searching, "progress is shown again")
        XCTAssertNil(harness.record?.sharedKey, "the next connection runs the full J-PAKE")
        harness.clock.advance(300)
        let link = harness.connection(glucose: harness.currentGlucose(122))
        XCTAssertTrue(link.allWrites.contains { $0.characteristic == .receiveAuthentication && $0.data.first == 0x0A }, "full J-PAKE")
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(120), .mgdl(122)])
        if case .active = harness.states.last {} else { XCTFail("\(harness.states)") }
        let after = try XCTUnwrap(harness.record)
        XCTAssertEqual(after.serial, before.serial)
        XCTAssertEqual(after.sessionStart, before.sessionStart)
        XCTAssertFalse(after.requiresNewPairing)
        XCTAssertNotNil(after.sharedKey)
        XCTAssertNotEqual(after.sharedKey, before.sharedKey, "a new key")
        XCTAssertEqual(harness.controller.currentSession, session)

        // Found again by name (iOS could not reconnect by identifier): the same sensor is accepted.
        harness.sensor.confirmedKeys[0x02] = G7Random.bytes(16)
        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(123))
        try harness.controller.pairAgain(pairingCode: "1234")
        let connects = harness.central.connectRequests.count
        harness.controller.didDiscover(name: harness.sensorName, identifier: harness.identifier)
        XCTAssertEqual(harness.central.connectRequests.count, connects + 1, "rediscovering the same sensor connects")
    }

    /// Coordinator decision after D37: during a new-sensor pairing, the previous (still running)
    /// sensor refusing the new code is expected — logged, excluded, scanning continues, and no
    /// `.failed(pairingCodeRejected)` (it would raise a false sensor alert). The previous sensor keeps
    /// its own pairing and nothing is published from it; another sensor refusing still surfaces, and
    /// the new sensor then pairs.
    func test_S5_previousSensorRefusingANewCodeIsSilentlySkipped() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(120))
        let previousKey = harness.sensor.confirmedKeys[0x02]
        let statesBefore = harness.states.count

        try harness.controller.start(pairingCode: "5678")
        harness.controller.didDiscover(name: harness.sensorName, identifier: harness.identifier)
        harness.clock.advance(60)
        let refused = harness.connection(glucose: harness.currentGlucose(121))
        XCTAssertEqual(refused.disconnectCount, 1)
        XCTAssertFalse(harness.states[statesBefore...].contains(.failed(G7FailureReason.pairingCodeRejected)), "\(harness.states)")
        XCTAssertFalse(harness.states[statesBefore...].contains { if case .failed = $0 { return true } else { return false } })
        XCTAssertTrue(harness.log.messages.contains { $0.contains("previous sensor \(harness.sensorName) did not accept the new code") })
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(120)], "nothing from the previous sensor")
        XCTAssertEqual(harness.sensor.confirmedKeys[0x02], previousKey, "the previous sensor's own pairing is untouched")
        XCTAssertNil(harness.record?.serial)
        XCTAssertNil(harness.record?.sessionEnd)
        let connects = harness.central.connectRequests.count
        harness.controller.didDiscover(name: harness.sensorName, identifier: harness.identifier)
        XCTAssertEqual(harness.central.connectRequests.count, connects, "excluded for the rest of this pairing")

        // Any other sensor refusing the code still surfaces.
        let stranger = G7SensorSimulator(pairingCode: "0000")
        let strangerID = UUID()
        harness.controller.didDiscover(name: "DXCM2Z", identifier: strangerID)
        harness.connection(glucose: nil, peripheral: strangerID, sensor: stranger)
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.pairingCodeRejected))

        // The new sensor pairs and publishes.
        let newSensor = G7SensorSimulator(pairingCode: "5678")
        let newID = UUID(uuidString: "7A7B7C7D-0000-4000-8000-000000000002")!
        harness.controller.didDiscover(name: "DXCM7Q", identifier: newID)
        harness.connection(glucose: Fixture.glucose(sensorClock: 3 * 86_400, age: 5, glucose: 131, state: 0x06), peripheral: newID, sensor: newSensor)
        XCTAssertEqual(harness.record?.serial, "DXCM7Q-7A7B7C7D")
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(120), .mgdl(131)])
        if case .active = harness.states.last {} else { XCTFail("\(harness.states)") }
    }

    /// Re-review N1: the skip is decided by CoreBluetooth identifier, never by name. A new sensor that
    /// happens to share the previous sensor's name ("DXCM" + 2 characters) and refuses a mistyped
    /// code is reported; the previous sensor itself (same identifier) is still skipped.
    func test_S5_sameNameDifferentIdentifierRefusalSurfaces() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(120))
        try harness.controller.start(pairingCode: "5678")
        let twin = G7SensorSimulator(pairingCode: "1111") // new sensor, code mistyped as 5678
        let twinID = UUID(uuidString: "3C4D5E6F-0000-4000-8000-000000000003")!
        harness.controller.didDiscover(name: harness.sensorName, identifier: twinID)
        harness.connection(glucose: nil, peripheral: twinID, sensor: twin)
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.pairingCodeRejected))

        let statesBefore = harness.states.count
        harness.controller.didDiscover(name: harness.sensorName, identifier: harness.identifier)
        harness.connection(glucose: harness.currentGlucose(121))
        XCTAssertFalse(harness.states[statesBefore...].contains { if case .failed = $0 { return true } else { return false } },
                       "the previous sensor (same identifier) is skipped")
        XCTAssertTrue(harness.log.messages.contains { $0.contains("previous sensor \(harness.sensorName) did not accept the new code; skipped") })
    }

    /// Re-review N1: the silent skip is time-limited. If no sensor authenticates within 10 minutes of
    /// the pairing start, the skipped refusal is reported, naming the previous sensor and pointing
    /// to entering its code again; a refusal by the previous sensor after the limit is reported at once; and a
    /// pairing that succeeded in time reports nothing.
    func test_S5_previousSensorSkipIsTimeLimited() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(120))
        try harness.controller.start(pairingCode: "5678")
        harness.controller.didDiscover(name: harness.sensorName, identifier: harness.identifier)
        harness.connection(glucose: harness.currentGlucose(121))
        XCTAssertFalse(harness.states.contains { if case .failed = $0 { return true } else { return false } })
        harness.clock.advance(G7Controller.previousSensorSkipLimit)
        harness.central.fireScheduled()
        let expected = G7FailureReason.previousSensorRejectedCode(sensorName: harness.sensorName)
        XCTAssertEqual(harness.states.last, .failed(expected))
        XCTAssertEqual(expected.kind, .pairingRejected)
        XCTAssertEqual(expected.message, "The sensor DXCM4F refused the new code, and no other sensor accepted it. If you meant to keep using DXCM4F, enter its 4-digit code again. If you are pairing a new sensor, check the code on the new applicator.")
        XCTAssertFalse(expected.message.contains("Pair again"), "onboarding offers only \"Try again\" (pair(code:)), which reaches the worn sensor")

        let late = ControllerHarness()
        try late.pair(glucose: late.currentGlucose(120))
        try late.controller.start(pairingCode: "5678")
        late.clock.advance(G7Controller.previousSensorSkipLimit + 1)
        late.controller.didDiscover(name: late.sensorName, identifier: late.identifier)
        late.connection(glucose: late.currentGlucose(121))
        XCTAssertEqual(late.states.last, .failed(G7FailureReason.previousSensorRejectedCode(sensorName: late.sensorName)))

        let succeeded = ControllerHarness()
        try succeeded.pair(glucose: succeeded.currentGlucose(120))
        try succeeded.controller.start(pairingCode: "5678")
        succeeded.controller.didDiscover(name: succeeded.sensorName, identifier: succeeded.identifier)
        succeeded.connection(glucose: succeeded.currentGlucose(121))
        let newSensor = G7SensorSimulator(pairingCode: "5678")
        let newID = UUID(uuidString: "7A7B7C7D-0000-4000-8000-000000000002")!
        succeeded.controller.didDiscover(name: "DXCM7Q", identifier: newID)
        succeeded.connection(glucose: Fixture.glucose(sensorClock: 3 * 86_400, age: 5, glucose: 131, state: 0x06), peripheral: newID, sensor: newSensor)
        succeeded.clock.advance(G7Controller.previousSensorSkipLimit)
        succeeded.central.fireScheduled()
        if case .active = succeeded.states.last {} else { XCTFail("\(succeeded.states)") }
    }

    /// Re-review N1: once a sensor has authenticated (e.g. during onboarding), `hasStoredSensor` tells
    /// the app to route a code retry to `pairAgain(code:)`; a mistyped code is then reported at once
    /// (not skipped as the "previous" sensor), and the right code resumes readings with the same key
    /// slot and session.
    func test_S5_retryAfterAuthenticationUsesPairAgain() throws {
        let harness = ControllerHarness()
        XCTAssertFalse(harness.controller.hasStoredSensor)
        XCTAssertNil(harness.controller.storedSensorSerial)
        try harness.controller.start(pairingCode: "1234")
        XCTAssertFalse(harness.controller.hasStoredSensor, "a pairing in progress has no stored sensor yet")
        harness.controller.didDiscover(name: harness.sensorName, identifier: harness.identifier)
        harness.connection(glucose: harness.currentGlucose(120), failingNotify: [.writeControl: .pairingNotCompleted])
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.bluetoothPairingNotCompleted))
        XCTAssertTrue(harness.controller.hasStoredSensor, "authenticated: a retry must use pairAgain")
        XCTAssertEqual(harness.controller.storedSensorSerial, "DXCM4F-1A2B3C4D")

        try harness.controller.pairAgain(pairingCode: "1243") // typo
        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(121))
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.pairingCodeRejected), "reported, never skipped")
        try harness.controller.pairAgain(pairingCode: "1234")
        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(122))
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(122)])
        XCTAssertEqual(harness.record?.serial, "DXCM4F-1A2B3C4D")
    }

    /// Pair again: a wrong code is reported and the sensor stays refused until the right code; without
    /// a sensor this phone ever connected to, or with an invalid code, nothing starts.
    func test_S5_pairAgainWithAWrongCodeOrNoSensor() throws {
        let fresh = ControllerHarness()
        XCTAssertThrowsError(try fresh.controller.pairAgain(pairingCode: "1234")) { XCTAssertEqual($0 as? G7StartError, .noSensorToPairAgain) }

        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(120))
        XCTAssertThrowsError(try harness.controller.pairAgain(pairingCode: "12a4")) { XCTAssertEqual($0 as? G7StartError, .invalidPairingCode) }
        try harness.controller.pairAgain(pairingCode: "9999")
        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(121))
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.pairingCodeRejected))
        XCTAssertEqual(harness.record?.requiresNewPairing, true)
        XCTAssertEqual(harness.readings.count, 1)
        try harness.controller.pairAgain(pairingCode: "1234")
        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(122))
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(120), .mgdl(122)])
    }

    /// M1: a new-sensor pairing may connect to the previous sensor while its session is running, but
    /// ignores it once its session has ended or when it was unsupported.
    func test_newSensorPairingIgnoresOnlyAnEndedOrUnsupportedPreviousSensor() throws {
        func connectsToPrevious(_ harness: ControllerHarness) throws -> Bool {
            try harness.controller.start(pairingCode: "5678")
            let before = harness.central.connectRequests.count
            harness.controller.didDiscover(name: harness.sensorName, identifier: harness.identifier)
            return harness.central.connectRequests.count > before
        }
        let running = ControllerHarness()
        try running.pair(glucose: running.currentGlucose(120))
        XCTAssertTrue(try connectsToPrevious(running), "a running previous sensor may be the one being paired")

        let ended = ControllerHarness()
        try ended.pair(glucose: ended.currentGlucose(120))
        for _ in 0..<2 {
            ended.clock.advance(300)
            ended.connection(glucose: ended.currentGlucose(nil, state: 0x19))
        }
        XCTAssertEqual(ended.record?.sessionEnd, .sensorFailed)
        XCTAssertFalse(try connectsToPrevious(ended))

        let unsupported = ControllerHarness()
        unsupported.sensor.extendedVersionResponse = Fixture.fifteenDayExtendedVersion
        try unsupported.pair(glucose: unsupported.currentGlucose(120))
        XCTAssertEqual(unsupported.record?.isUnsupportedSensor, true)
        XCTAssertFalse(try connectsToPrevious(unsupported))
        let before = unsupported.central.connectRequests.count
        unsupported.controller.didDiscover(name: "DXCM7Q", identifier: UUID())
        XCTAssertEqual(unsupported.central.connectRequests.count, before + 1, "another sensor is still found")
    }

    // MARK: - D37 minor: calibration during a clock mismatch

    /// While the last surfaced failure is a clock mismatch, the fingerstick → sensor-time conversion
    /// is not trusted: calibration is refused with `invalidTime`; once the clocks agree it is accepted.
    func test_S3_calibrationRefusedDuringClockMismatch() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(120))
        harness.clock.advance(300)
        harness.connection(glucose: Fixture.glucose(sensorClock: harness.sensorClock + 3_600, age: 5, glucose: 121, state: 0x06))
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.sensorClockMismatch))
        XCTAssertThrowsError(try harness.controller.submitCalibration(CalibrationRequest(mgdl: 120, takenAt: harness.clock.now))) {
            XCTAssertEqual($0 as? CalibrationRefusal, .invalidTime)
        }
        XCTAssertTrue(harness.calibrations.isEmpty)
        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(122))
        if case .active = harness.states.last {} else { XCTFail("\(harness.states)") }
        XCTAssertNoThrow(try harness.controller.submitCalibration(CalibrationRequest(mgdl: 120, takenAt: harness.clock.now)))
    }

    // MARK: - Save failures

    /// Follow-up 2: repeated failures to save the pairing record are surfaced (S5), not only logged;
    /// a single failure is not; a successful save clears it.
    func test_S5_repeatedPairingRecordSaveFailuresAreSurfaced() throws {
        let store = FlakyCredentialStore()
        let harness = ControllerHarness(store: store)
        try harness.pair(glucose: harness.currentGlucose(120))
        let unavailable = SensorState.failed(G7FailureReason.credentialsUnavailable)

        store.failSaves = true
        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(121)) // two failed saves (identity, newest reading)
        XCTAssertFalse(harness.states.contains(unavailable), "fewer than \(G7Controller.saveFailuresBeforeSurfacing) failures")
        if case .active = harness.states.last {} else { XCTFail("\(harness.states)") }
        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(122))
        XCTAssertEqual(harness.states.last, unavailable)
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(120), .mgdl(121), .mgdl(122)], "readings continue")
        XCTAssertTrue(harness.log.messages.contains { $0.contains("could not save the pairing record (3 in a row)") })

        store.failSaves = false
        harness.clock.advance(300)
        harness.connection(glucose: harness.currentGlucose(123))
        if case .active = harness.states.last {} else { XCTFail("recovered: \(harness.states)") }
        XCTAssertEqual(harness.record?.newestReading?.date, harness.readings.last?.date, "saved again")
    }

    /// P4: the newest published reading is persisted with the session.
    func test_S3_newestReadingIsPersisted() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(120))
        let reading = try XCTUnwrap(harness.readings.last)
        XCTAssertEqual(harness.record?.newestReading?.date, reading.date)
        XCTAssertEqual(harness.record.flatMap { $0.newestReading.map { "\($0.sensorTimestamp)" } }, reading.id.split(separator: ":").last.map(String.init))
    }

    /// B2: unsupported sensor, a rejected key, and forget all leave no session.
    func test_S2_currentSessionNilForUnsupportedRejectedAndForgotten() throws {
        let fifteenDay = ControllerHarness()
        fifteenDay.sensor.extendedVersionResponse = Fixture.fifteenDayExtendedVersion
        try fifteenDay.pair(glucose: fifteenDay.currentGlucose(120))
        XCTAssertTrue(fifteenDay.readings.isEmpty, "minor 1: not even one reading from a 15-day sensor")
        XCTAssertNil(fifteenDay.controller.currentSession)
        XCTAssertEqual(fifteenDay.states.last, .failed(G7FailureReason.unsupportedSensor))

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
        XCTAssertEqual(silent.states.last, .failed(G7FailureReason.sessionLengthUnknown))
    }

    /// Probe P7: `52` is never answered during a new pairing, so GetData is never sent; when the
    /// connection ends the reason is surfaced (not left at "authenticating"), and `52` is asked again.
    func test_S5_unansweredSessionLengthIsSurfacedAtDisconnect() throws {
        let harness = ControllerHarness()
        harness.sensor.extendedVersionResponse = nil
        let link = try harness.pair(glucose: harness.currentGlucose(120))
        XCTAssertEqual(link.allWrites.filter { $0.characteristic == .writeControl }.map(\.data), [Data([0x52])])
        XCTAssertTrue(harness.readings.isEmpty)
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.sessionLengthUnknown))
        XCTAssertNil(harness.record?.reportedSessionLength)
        harness.clock.advance(300)
        harness.sensor.extendedVersionResponse = Fixture.tenDayExtendedVersion
        harness.connection(glucose: harness.currentGlucose(121))
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(121)])
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
        XCTAssertEqual(states, [.failed(G7FailureReason.credentialsUnavailable)])
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
        XCTAssertEqual(harness.central.scheduled.map(\.delay), [G7Controller.previousSensorSkipLimit, G7Controller.candidateConnectTimeout])
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
/// Saves fail while `failSaves` is set; everything else goes to an in-memory store.
final class FlakyCredentialStore: G7CredentialStore {
    struct SaveFailed: Error {}
    private let inner = G7InMemoryCredentialStore()
    private let failing = OSAllocatedUnfairLock(initialState: false)

    var failSaves: Bool {
        get { failing.withLock { $0 } }
        set { failing.withLock { $0 = newValue } }
    }

    func load() throws -> G7PairingRecord? { try inner.load() }
    func save(_ record: G7PairingRecord) throws {
        if failSaves { throw SaveFailed() }
        try inner.save(record)
    }
    func delete() throws { try inner.delete() }
}

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
