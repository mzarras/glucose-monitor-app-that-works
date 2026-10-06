// Original to Sensor (no ported code).

import GlucoseCore
import XCTest
@testable import G7Kit

/// Drives a listen-mode `G7Controller` (D45) the way CoreBluetooth would while the Dexcom app owns
/// the connection: the Dexcom app connects, this app attaches, the Dexcom app's own exchange
/// produces the `05` status and the Write_Control frames this app observes.
final class ListenHarness {
    let clock: TestClock
    let store: any G7CredentialStore
    let log = RecordingDiagnosticLog()
    let central = FakeCentral()
    let identifier = UUID(uuidString: "1A2B3C4D-0000-4000-8000-000000000001")!
    let sensorName = "DXCM4F"
    var readings: [GlucoseReading] = []
    var states: [SensorState] = []
    /// Every link this harness handed to the controller (checked for writes).
    var links: [FakeLink] = []
    private(set) var controller: G7Controller!
    /// Phone time at which the sensor session started.
    let sessionStart: Date

    init(store: any G7CredentialStore = G7InMemoryCredentialStore(), sessionAge: TimeInterval = 2 * 86_400,
         relaunchOf previous: ListenHarness? = nil, recordsRaw: Bool = false) {
        self.store = store
        clock = previous?.clock ?? TestClock()
        sessionStart = previous?.sessionStart ?? clock.now.addingTimeInterval(-sessionAge)
        controller = G7Controller(
            store: store, diagnostics: log, now: { [clock] in clock.now }, mode: .listen,
            recordsRawGlucosePackets: recordsRaw,
            output: G7Controller.Output(
                reading: { [unowned self] in readings.append($0) },
                state: { [unowned self] in states.append($0) },
                calibration: { _ in }
            )
        )
        controller.central = central
        controller.bluetoothPowerChanged(.poweredOn)
    }

    var sensorClock: UInt32 { UInt32(clock.now.timeIntervalSince(sessionStart)) }

    /// The Dexcom app's `0x4E` for a reading `age` seconds old.
    func dexcomGlucose(_ mgdl: UInt16?, state: UInt8 = 0x06, age: UInt16 = 5, trend: UInt8 = 0x10, flags: UInt8 = 0x0F, status: UInt8 = 0) -> Data {
        Fixture.glucose(status: status, sensorClock: sensorClock, age: age, glucose: mgdl, state: state, trend: trend, flags: flags)
    }

    /// One sensor wake observed: the Dexcom app connects (this app attaches), its exchange produces
    /// `auth`, then the `frames` arrive on Write_Control.
    @discardableResult
    func wake(auth: Data? = Data([0x05, 0x01, 0x01]), frames: [Data], peripheral: UUID? = nil, name: String? = nil,
              disconnect: Bool = true) -> FakeLink {
        let id = peripheral ?? identifier
        central.connected = [G7ConnectedSensor(name: name ?? sensorName, identifier: id)]
        controller.didDiscover(name: name ?? sensorName, identifier: id) // wake-up signal: attach
        let link = FakeLink(identifier: id)
        links.append(link)
        controller.didConnect(link: link, availableCharacteristics: Set(G7Characteristic.allCases))
        deliverNotifications(link)
        if let auth { controller.valueUpdated(for: .receiveAuthentication, value: auth) }
        deliverNotifications(link)
        for frame in frames { controller.valueUpdated(for: .writeControl, value: frame) }
        if disconnect {
            central.connected = []
            controller.didDisconnect(peripheralIdentifier: id)
        }
        return link
    }

    private func deliverNotifications(_ link: FakeLink) {
        while !link.notifyRequests.isEmpty {
            let (characteristic, enabled) = link.notifyRequests.removeFirst()
            if enabled { link.notifying.insert(characteristic) } else { link.notifying.remove(characteristic) }
            controller.notificationStateChanged(for: characteristic, isNotifying: enabled, error: nil)
        }
    }

    var record: G7PairingRecord? { try? store.load() }
}

final class G7ListenModeTests: XCTestCase {
    private var harnesses: [ListenHarness] = []

    private func makeHarness(store: any G7CredentialStore = G7InMemoryCredentialStore(), relaunchOf previous: ListenHarness? = nil,
                             recordsRaw: Bool = false) -> ListenHarness {
        let harness = ListenHarness(store: store, relaunchOf: previous, recordsRaw: recordsRaw)
        harnesses.append(harness)
        return harness
    }

    /// Every listen-mode test also checks the hard constraint (D45, D49): the only write ever made is
    /// the `52` session-length query on Write_Control with response, at most once per connection;
    /// the Dexcom app's link is never dropped; only Receive_Authentication and Write_Control are
    /// subscribed. The D49 conditions for that one write are checked by the tests below.
    override func tearDown() {
        for harness in harnesses {
            for link in harness.links {
                let other = link.writes.filter { !($0.data == Data([0x52]) && $0.characteristic == .writeControl && $0.withResponse) }
                XCTAssertTrue(other.isEmpty, "listen mode wrote something other than the 52 query: \(other.map(\.data.hexString))")
                XCTAssertLessThanOrEqual(link.writes.count, 1, "more than one write in one connection")
                XCTAssertEqual(link.disconnectCount, 0, "listen mode dropped the Dexcom app's link")
                XCTAssertTrue(Set(link.notifying).isSubset(of: [.receiveAuthentication, .writeControl]))
            }
        }
        harnesses = []
        super.tearDown()
    }

    // MARK: - S2

    /// An observed authenticated, bonded status, the Dexcom app's `52` answer and its `0x4E`: the
    /// reading is published, the sensor is followed (same serial as primary mode), the state is active.
    func test_S2_observedAuthenticationThenGlucosePublishes() throws {
        let harness = makeHarness()
        try harness.controller.start(pairingCode: nil)
        XCTAssertEqual(harness.states, [.searching])
        let link = harness.wake(frames: [Fixture.tenDayExtendedVersion, harness.dexcomGlucose(123)])
        let reading = try XCTUnwrap(harness.readings.first)
        XCTAssertEqual(harness.readings.count, 1)
        XCTAssertEqual(reading.id, "DXCM4F-1A2B3C4D:\(harness.sensorClock - 5)")
        XCTAssertEqual(reading.date, harness.sessionStart.addingTimeInterval(TimeInterval(harness.sensorClock - 5)))
        XCTAssertEqual(reading.value, .mgdl(123))
        XCTAssertEqual(reading.trendRate, 1.6)
        XCTAssertFalse(reading.isBackfill)
        XCTAssertEqual(harness.record?.serial, "DXCM4F-1A2B3C4D", "the advertised form, as primary mode")
        XCTAssertTrue(harness.record?.isListenRecord == true)
        XCTAssertEqual(harness.record?.sharedKey, nil)
        if case .active = harness.states.last {} else { XCTFail("\(harness.states)") }
        XCTAssertEqual(link.allWrites.count, 0)
        XCTAssertEqual(harness.controller.currentSession?.serial, "DXCM4F-1A2B3C4D")
        XCTAssertNoThrow(try LiveReadingGate.validate(reading, session: harness.controller.currentSession, now: harness.clock.now))
    }

    /// No observed authenticated + bonded status (none, a rejection, or authenticated but not
    /// bonded): nothing is forwarded or published, Write_Control is never subscribed, and two such
    /// wakes in a row are surfaced.
    func test_S2_noObservedAuthenticationPublishesNothing() throws {
        let harness = makeHarness()
        try harness.controller.start(pairingCode: nil)
        for auth in [nil, Data([0x05, 0x00, 0x02]), Data([0x05, 0x01, 0x02])] as [Data?] {
            let link = harness.wake(auth: auth, frames: [Fixture.tenDayExtendedVersion, harness.dexcomGlucose(123)])
            XCTAssertFalse(link.notifying.contains(.writeControl), "Write_Control is subscribed only after observed authentication")
            harness.clock.advance(300)
        }
        XCTAssertTrue(harness.readings.isEmpty)
        XCTAssertNil(harness.record?.serial, "no sensor is followed without an observed authentication")
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.listenNoAuthenticatedConnection))
        XCTAssertTrue(harness.log.messages.contains { $0.contains("without proof of an authenticated link ignored") })
    }

    /// The session must come from what the sensor sends: without an observed `52` (only the Dexcom app
    /// can ask for it here) nothing is published and the reason is shown; once seen, readings flow.
    func test_S2_listenSessionNeedsTheObservedSessionLength() throws {
        let harness = makeHarness()
        try harness.controller.start(pairingCode: nil)
        harness.wake(frames: [harness.dexcomGlucose(120)])
        XCTAssertTrue(harness.readings.isEmpty)
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.listenSessionLengthUnknown))
        XCTAssertNil(harness.controller.currentSession)
        harness.clock.advance(300)
        harness.wake(frames: [Fixture.tenDayExtendedVersion, harness.dexcomGlucose(121)])
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(121)])
    }

    /// Once a sensor is followed, another sensor's connection is not attached, and its packets are
    /// refused even if a connection is delivered; a 15-day sensor's `52` is refused as unsupported.
    func test_S2_otherSensorsPacketsAreRefused() throws {
        let harness = makeHarness()
        try harness.controller.start(pairingCode: nil)
        harness.wake(frames: [Fixture.tenDayExtendedVersion, harness.dexcomGlucose(120)])
        XCTAssertEqual(harness.readings.count, 1)

        let other = UUID(uuidString: "9F9F9F9F-0000-4000-8000-000000000009")!
        harness.clock.advance(300)
        let connectsBefore = harness.central.connectRequests.count
        harness.central.connected = [G7ConnectedSensor(name: "DXCM7Q", identifier: other)]
        harness.controller.didDiscover(name: "DXCM7Q", identifier: other)
        XCTAssertFalse(harness.central.connectRequests.dropFirst(connectsBefore).contains(other), "never attached")
        harness.wake(frames: [harness.dexcomGlucose(180)], peripheral: other, name: "DXCM7Q")
        XCTAssertEqual(harness.readings.count, 1, "the other sensor's packets are not used")
        XCTAssertTrue(harness.central.cancelRequests.contains(other))
        XCTAssertEqual(harness.record?.serial, "DXCM4F-1A2B3C4D")

        let fifteenDay = makeHarness()
        try fifteenDay.controller.start(pairingCode: nil)
        fifteenDay.wake(frames: [Fixture.fifteenDayExtendedVersion, fifteenDay.dexcomGlucose(120)])
        XCTAssertTrue(fifteenDay.readings.isEmpty)
        XCTAssertEqual(fifteenDay.states.last, .failed(G7FailureReason.unsupportedSensor))
    }

    /// A rejection observed after the authentication: nothing more from this connection is used
    /// (no reading, no `0x31`/`0x25` pair), the state says why, and this app does not drop the link.
    func test_S2_rejectionAfterObservedAuthenticationStopsForwarding() throws {
        let harness = makeHarness()
        try harness.controller.start(pairingCode: nil)
        harness.wake(frames: [Fixture.tenDayExtendedVersion, harness.dexcomGlucose(120)])
        harness.clock.advance(300)
        let link = harness.wake(frames: [], disconnect: false)
        harness.controller.valueUpdated(for: .receiveAuthentication, value: Data([0x05, 0x00, 0x02]))
        harness.controller.valueUpdated(for: .writeControl, value: harness.dexcomGlucose(181))
        harness.controller.valueUpdated(for: .receiveAuthentication, value: Data([0x05, 0x01, 0x01]))
        harness.controller.valueUpdated(for: .writeControl, value: harness.dexcomGlucose(182))
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(120)])
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.listenConnectionRejected))
        XCTAssertEqual(link.disconnectCount, 0)
        harness.controller.didDisconnect(peripheralIdentifier: harness.identifier)
        harness.clock.advance(300)
        harness.wake(frames: [harness.dexcomGlucose(122)])
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(120), .mgdl(122)], "the next wake is checked again")
    }

    /// The hard constraint, end to end, when the session length is observed (another app asked
    /// `52`): a whole listen session — attach, observe, readings in both formats, the Dexcom app's
    /// other traffic, a calibration attempt, relaunch, recording on — writes nothing at all, never
    /// drops the link, subscribes only to Receive_Authentication and Write_Control, and refuses
    /// calibration.
    func test_S2_listenModeWritesNothingWhenTheSessionLengthIsObserved() throws {
        let store = G7InMemoryCredentialStore()
        let harness = makeHarness(store: store, recordsRaw: true)
        try harness.controller.start(pairingCode: nil)
        let first = harness.wake(frames: [Fixture.tenDayExtendedVersion, harness.dexcomGlucose(120)], disconnect: false)
        // Everything the Dexcom app's traffic may carry on the shared link:
        harness.controller.valueUpdated(for: .authStream, value: Data(repeating: 0xAB, count: 20))
        harness.controller.valueUpdated(for: .receiveAuthentication, value: Data([0x03] + Array(repeating: 0x11, count: 16)))
        harness.controller.valueUpdated(for: .backfill, value: Fixture.backfill(timestamp: harness.sensorClock - 305, glucose: 119))
        harness.controller.valueUpdated(for: .writeControl, value: Data([0x59]))
        harness.controller.valueUpdated(for: .writeControl, value: Data([0x34, 0x00, 0x00, 0x00]))
        XCTAssertThrowsError(try harness.controller.submitCalibration(CalibrationRequest(mgdl: 120, takenAt: harness.clock.now))) {
            XCTAssertEqual($0 as? CalibrationRefusal, .notAuthenticated)
        }
        harness.controller.didDisconnect(peripheralIdentifier: harness.identifier)
        XCTAssertEqual(Set(first.notifying), [.receiveAuthentication, .writeControl])
        XCTAssertEqual(harness.readings.count, 1, "backfill is never used in listen mode")

        harness.clock.advance(300)
        harness.wake(frames: [Fixture.transmitterTime(current: 20_000_000 + harness.sensorClock, sessionStart: 20_000_000),
                              Fixture.coexistenceGlucose(readingTransmitterTime: 20_000_000 + harness.sensorClock - 5, glucose: 125)])
        XCTAssertEqual(harness.readings.count, 2)

        let relaunched = makeHarness(store: store, relaunchOf: harness)
        relaunched.controller.emitInitialState()
        try relaunched.controller.start(pairingCode: nil)
        relaunched.clock.advance(300)
        relaunched.wake(frames: [relaunched.dexcomGlucose(126)])
        XCTAssertEqual(relaunched.readings.map(\.value), [.mgdl(126)])
        XCTAssertThrowsError(try relaunched.controller.start(pairingCode: "1234")) { XCTAssertEqual($0 as? G7StartError, .notAvailableInListenMode) }
        XCTAssertThrowsError(try relaunched.controller.pairAgain(pairingCode: "1234")) { XCTAssertEqual($0 as? G7StartError, .notAvailableInListenMode) }
        XCTAssertNil(relaunched.controller.heartbeatTarget, "no Trio handoff while listening (D45)")
        XCTAssertFalse(relaunched.controller.hasStoredSensor)
        for link in harness.links + relaunched.links {
            XCTAssertTrue(link.allWrites.isEmpty)
            XCTAssertTrue(Set(link.notifying).isSubset(of: [.receiveAuthentication, .writeControl]))
        }
    }

    // MARK: - D49: proof of an authenticated link

    /// The `05` arriving after this app subscribed (the normal order) proves the link.
    func test_S2_statusArrivingAfterOurSubscriptionIsHandled() throws {
        let harness = makeHarness()
        try harness.controller.start(pairingCode: nil)
        harness.central.connected = [G7ConnectedSensor(name: "DXCM4F", identifier: harness.identifier)]
        harness.controller.didDiscover(name: "DXCM4F", identifier: harness.identifier)
        let link = FakeLink(identifier: harness.identifier)
        harness.links.append(link)
        harness.controller.didConnect(link: link, availableCharacteristics: Set(G7Characteristic.allCases))
        XCTAssertEqual(link.notifyRequests.map { $0.0 }, [.receiveAuthentication], "not followed yet: Write_Control waits for proof")
        link.notifying.insert(.receiveAuthentication)
        harness.controller.notificationStateChanged(for: .receiveAuthentication, isNotifying: true, error: nil)
        harness.controller.valueUpdated(for: .receiveAuthentication, value: Data([0x05, 0x01, 0x01]))
        XCTAssertEqual(link.notifyRequests.last?.0, .writeControl)
        link.notifying.insert(.writeControl)
        harness.controller.valueUpdated(for: .writeControl, value: Fixture.tenDayExtendedVersion)
        harness.controller.valueUpdated(for: .writeControl, value: harness.dexcomGlucose(118))
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(118)])
        XCTAssertTrue(harness.log.messages.contains { $0.contains("proven by authenticated and bonded 05") })
    }

    /// D49: the followed sensor's Write_Control is subscribed at once, so if the `05` was missed, a
    /// valid status-0 `0x4E` (encrypted link, sent only to an authenticated client) proves the link
    /// and the wake is not lost.
    func test_S2_missedStatusButValidGlucoseIsProof() throws {
        let harness = makeHarness()
        try harness.controller.start(pairingCode: nil)
        harness.wake(frames: [Fixture.tenDayExtendedVersion, harness.dexcomGlucose(120)])
        harness.clock.advance(300)
        let link = harness.wake(auth: nil, frames: [harness.dexcomGlucose(121)])
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(120), .mgdl(121)])
        XCTAssertTrue(link.notifying.contains(.writeControl))
        XCTAssertTrue(harness.log.messages.contains { $0.contains("proven by status-0 0x4E on Write_Control") })
        XCTAssertNotEqual(harness.states.last, .failed(G7FailureReason.listenNoAuthenticatedConnection))
    }

    /// D49: a non-zero-status `0x4E` (a status reply that may be cached) or a `0x31`/`0x25` pair is not
    /// proof; nor is a status-0 `0x4E` from a sensor that is not followed yet. Nothing is published or
    /// written.
    func test_S2_nonZeroStatusGlucoseAloneIsNotProof() throws {
        let harness = makeHarness()
        try harness.controller.start(pairingCode: nil)
        harness.wake(frames: [Fixture.tenDayExtendedVersion, harness.dexcomGlucose(120)])
        let base: UInt32 = 9_000_000
        for _ in 0..<2 {
            harness.clock.advance(300)
            harness.wake(auth: nil, frames: [harness.dexcomGlucose(130, status: 0x80),
                                             Fixture.coexistenceGlucose(readingTransmitterTime: base + harness.sensorClock - 5, glucose: 131),
                                             Fixture.transmitterTime(current: base + harness.sensorClock, sessionStart: base)])
        }
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(120)])
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.listenNoAuthenticatedConnection))
        XCTAssertTrue(harness.links.allSatisfy { $0.writes.isEmpty })

        let unfollowed = makeHarness()
        try unfollowed.controller.start(pairingCode: nil)
        unfollowed.wake(auth: nil, frames: [Fixture.tenDayExtendedVersion, unfollowed.dexcomGlucose(140)])
        XCTAssertTrue(unfollowed.readings.isEmpty)
        XCTAssertNil(unfollowed.record?.serial)
    }

    // MARK: - D49: the one 52 query

    /// No `52` observed: none is sent at the first wake with proof (other apps may still ask); from
    /// the second, exactly one per connection, after a glucose report; its answer establishes the
    /// session; then no more queries.
    func test_S2_sessionLengthQueriedOnceFromTheSecondProvenWake() throws {
        let harness = makeHarness()
        try harness.controller.start(pairingCode: nil)
        let first = harness.wake(frames: [harness.dexcomGlucose(120)])
        XCTAssertTrue(first.writes.isEmpty, "first wake with proof: only observe")
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.listenSessionLengthUnknown))

        harness.clock.advance(300)
        let base: UInt32 = 3_000_000
        let second = harness.wake(frames: [harness.dexcomGlucose(121),
                                           Fixture.coexistenceGlucose(readingTransmitterTime: base + harness.sensorClock - 4, glucose: 121),
                                           Fixture.transmitterTime(current: base + harness.sensorClock, sessionStart: base),
                                           harness.dexcomGlucose(121, age: 4)], disconnect: false)
        XCTAssertEqual(second.writes.map(\.data), [Data([0x52])], "one query in this connection")
        XCTAssertEqual(second.writes.first?.characteristic, .writeControl)
        XCTAssertEqual(second.writes.first?.withResponse, true)
        harness.controller.valueUpdated(for: .writeControl, value: Fixture.tenDayExtendedVersion) // its answer
        harness.controller.didDisconnect(peripheralIdentifier: harness.identifier)
        XCTAssertEqual(harness.record?.reportedSessionLength, 907_200)
        XCTAssertNil(harness.controller.currentSession, "the start comes from the next status-0 reading")

        harness.clock.advance(300)
        let third = harness.wake(frames: [harness.dexcomGlucose(122)])
        XCTAssertTrue(third.writes.isEmpty, "the session length is known")
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(122)])
        XCTAssertNotNil(harness.controller.currentSession)
        XCTAssertTrue(harness.log.messages.contains { $0.contains("one 52 query sent (D49)") })
    }

    /// A `52` answer another app asked for (Trio's G7SensorKit, the Dexcom app) is used and nothing is
    /// written; without proof nothing is written either, at any wake.
    func test_S2_observedSessionLengthOrNoProofMeansNoWrite() throws {
        let harness = makeHarness()
        try harness.controller.start(pairingCode: nil)
        harness.wake(frames: [harness.dexcomGlucose(120)])
        harness.clock.advance(300)
        harness.wake(frames: [Fixture.tenDayExtendedVersion, harness.dexcomGlucose(121)])
        harness.clock.advance(300)
        harness.wake(frames: [harness.dexcomGlucose(122)])
        XCTAssertTrue(harness.links.allSatisfy { $0.writes.isEmpty })
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(121), .mgdl(122)])

        let unproven = makeHarness()
        try unproven.controller.start(pairingCode: nil)
        unproven.wake(frames: [unproven.dexcomGlucose(120)]) // followed, session length unknown
        for _ in 0..<3 {
            unproven.clock.advance(300)
            unproven.wake(auth: nil, frames: [unproven.dexcomGlucose(121, status: 0x80)])
            unproven.wake(auth: Data([0x05, 0x00, 0x02]), frames: [])
        }
        XCTAssertTrue(unproven.links.allSatisfy { $0.writes.isEmpty }, "no proof, no write")
    }

    /// A malformed answer establishes no session (the next connection may ask once more); a 15-day
    /// answer refuses the sensor and stops the queries.
    func test_S2_malformedSessionLengthResponseEstablishesNoSession() throws {
        let harness = makeHarness()
        try harness.controller.start(pairingCode: nil)
        harness.wake(frames: [harness.dexcomGlucose(120)])
        harness.clock.advance(300)
        harness.wake(frames: [harness.dexcomGlucose(121), Data([0x52, 0x00])])
        XCTAssertNil(harness.record?.reportedSessionLength)
        XCTAssertNil(harness.controller.currentSession)
        XCTAssertTrue(harness.log.messages.contains { $0.contains("malformed 0x52") })
        harness.clock.advance(300)
        let third = harness.wake(frames: [harness.dexcomGlucose(122), Fixture.fifteenDayExtendedVersion])
        XCTAssertEqual(third.writes.count, 1, "one more query in a new connection")
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.unsupportedSensor))
        harness.clock.advance(300)
        let fourth = harness.wake(frames: [harness.dexcomGlucose(123)])
        XCTAssertTrue(fourth.writes.isEmpty, "an unsupported sensor is not asked again")
        XCTAssertTrue(harness.readings.isEmpty)
        XCTAssertEqual(harness.links.map(\.writes.count), [0, 1, 1, 0])
    }

    // MARK: - S3

    /// D49 item 3: if the `0x31`/`0x25` time base disagrees with `0x4E`'s, it shows as a clock
    /// mismatch, never as silently wrong dates.
    func test_S3_timeBaseDisagreementShowsAsClockMismatch() throws {
        let harness = makeHarness()
        try harness.controller.start(pairingCode: nil)
        harness.wake(frames: [Fixture.tenDayExtendedVersion, harness.dexcomGlucose(120)])
        harness.clock.advance(300)
        let base: UInt32 = 5_000_000
        // The pair's session time is 3 600 s more than 0x4E's sensor clock for the same moment.
        harness.wake(frames: [Fixture.coexistenceGlucose(readingTransmitterTime: base + harness.sensorClock + 3_600 - 5, glucose: 121),
                              Fixture.transmitterTime(current: base + harness.sensorClock + 3_600, sessionStart: base)])
        XCTAssertEqual(harness.readings.count, 1)
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.sensorClockMismatch))
    }

    /// The captured G7 coexistence pair (xDrip Tests/DexcomG7CalibrationTests.swift:344-357): the
    /// reading is put in session time (transmitter time − session start = 233 027 s), dated from the
    /// sensor's clocks relative to the receipt, and gets the id primary mode's `0x4E` would give.
    func test_S3_observedCoexistencePairIsDatedFromSensorTime() throws {
        let harness = makeHarness()
        try harness.controller.start(pairingCode: nil)
        let glucose = Data(hex: "31008eaf0000335bd7009900060582be")
        let clock = Data(hex: "25003e5bd700f0ccd30001000000a0f2")
        harness.wake(frames: [Fixture.tenDayExtendedVersion, glucose, clock])
        let reading = try XCTUnwrap(harness.readings.first)
        XCTAssertEqual(reading.id, "DXCM4F-1A2B3C4D:233027")
        XCTAssertEqual(reading.date, harness.clock.now.addingTimeInterval(-11), "11 s before the 0x25 was received")
        XCTAssertEqual(reading.value, .mgdl(153))
        XCTAssertEqual(reading.trendRate, 0.5)
        XCTAssertEqual(harness.record?.sessionStart, harness.clock.now.addingTimeInterval(-233_038))

        // Either order joins, a pair is used once, and the same reading seen again dedupes.
        harness.clock.advance(300)
        harness.wake(frames: [Fixture.coexistenceGlucose(readingTransmitterTime: 13_880_560 + 233_327, glucose: 150),
                              Fixture.transmitterTime(current: 13_880_560 + 233_338, sessionStart: 13_880_560),
                              Fixture.transmitterTime(current: 13_880_560 + 233_339, sessionStart: 13_880_560)])
        XCTAssertEqual(harness.readings.map(\.id), ["DXCM4F-1A2B3C4D:233027", "DXCM4F-1A2B3C4D:233327"])
    }

    /// The same sensor reading through `0x4E` and through the pair gets the same id and date (the
    /// anchor check would flag a disagreement instead), and dates stay monotonic and deduplicated.
    func test_S3_listenReadingsMatchPrimaryIdsAndDates() throws {
        let harness = makeHarness()
        try harness.controller.start(pairingCode: nil)
        harness.wake(frames: [Fixture.tenDayExtendedVersion, harness.dexcomGlucose(120)])
        let viaFourE = try XCTUnwrap(harness.readings.last)
        let base: UInt32 = 50_000_000
        harness.clock.advance(1)
        harness.wake(frames: [Fixture.coexistenceGlucose(readingTransmitterTime: base + harness.sensorClock - 6, glucose: 120),
                              Fixture.transmitterTime(current: base + harness.sensorClock, sessionStart: base)])
        XCTAssertEqual(harness.readings.count, 1, "the same sensor time is the same reading: deduplicated")
        harness.clock.advance(299)
        harness.wake(frames: [Fixture.coexistenceGlucose(readingTransmitterTime: base + harness.sensorClock - 5, glucose: 121),
                              Fixture.transmitterTime(current: base + harness.sensorClock, sessionStart: base)])
        let viaPair = try XCTUnwrap(harness.readings.last)
        XCTAssertEqual(viaPair.id, "DXCM4F-1A2B3C4D:\(harness.sensorClock - 5)")
        XCTAssertEqual(viaPair.date.timeIntervalSince(viaFourE.date), 300, accuracy: 0.001)
    }

    // MARK: - S4 / S1

    /// LOW and HIGH stay flags in both observed formats; display-only values (calibration echoes)
    /// are never readings; a corrupted or status `0x31` is not used.
    func test_S4_listenLowHighStayFlagsAndDisplayOnlyIsWithheld() throws {
        let harness = makeHarness()
        try harness.controller.start(pairingCode: nil)
        harness.wake(frames: [Fixture.tenDayExtendedVersion, harness.dexcomGlucose(38)])
        let base: UInt32 = 7_000_000
        harness.clock.advance(300)
        harness.wake(frames: [Fixture.coexistenceGlucose(readingTransmitterTime: base + harness.sensorClock - 5, glucose: 425),
                              Fixture.transmitterTime(current: base + harness.sensorClock, sessionStart: base)])
        XCTAssertEqual(harness.readings.map(\.value), [.belowRange, .aboveRange])
        XCTAssertNil(harness.readings.compactMap(\.value.numericMgdl).first, "never 40 or 400")

        harness.clock.advance(300)
        harness.wake(frames: [harness.dexcomGlucose(130, flags: 0x1F)])
        harness.clock.advance(300)
        harness.wake(frames: [Fixture.coexistenceGlucose(readingTransmitterTime: base + harness.sensorClock - 5, glucose: 131, displayOnlyNibble: 0x1),
                              Fixture.transmitterTime(current: base + harness.sensorClock, sessionStart: base)])
        harness.clock.advance(300)
        var corrupted = [UInt8](Fixture.coexistenceGlucose(readingTransmitterTime: base + harness.sensorClock - 5, glucose: 132))
        corrupted[10] ^= 0x01
        harness.wake(frames: [Data(corrupted), Fixture.transmitterTime(current: base + harness.sensorClock, sessionStart: base),
                              Fixture.coexistenceGlucose(status: 0x80, readingTransmitterTime: base + harness.sensorClock - 4, glucose: 133),
                              Fixture.transmitterTime(current: base + harness.sensorClock + 1, sessionStart: base)])
        XCTAssertEqual(harness.readings.count, 2, "display-only, corrupted and status frames are not readings")
        XCTAssertTrue(harness.log.messages.contains { $0.contains("bad length or CRC dropped") })
    }

    /// S1 at the parser: the captured `0x31` is not display-only; a set high nibble is.
    func test_S1_coexistenceDisplayOnlyBitsAreRead() throws {
        let captured = try XCTUnwrap(G7CoexistenceGlucoseMessage(Data(hex: "31008eaf0000335bd7009900060582be")))
        XCTAssertFalse(captured.isDisplayOnly)
        XCTAssertEqual(captured.readingTransmitterTime, 14_113_587)
        XCTAssertEqual(captured.glucoseField, 153)
        XCTAssertEqual(captured.algorithmState, .ok)
        let flagged = try XCTUnwrap(G7CoexistenceGlucoseMessage(Fixture.coexistenceGlucose(readingTransmitterTime: 10, glucose: 99, displayOnlyNibble: 0x8)))
        XCTAssertTrue(flagged.isDisplayOnly)
        let clock = try XCTUnwrap(G7TransmitterTimeMessage(Data(hex: "25003e5bd700f0ccd30001000000a0f2")))
        XCTAssertEqual(clock.currentTransmitterTime, 14_113_598)
        XCTAssertEqual(clock.sessionStartTransmitterTime, 13_880_560)
        XCTAssertNil(G7ObservedGlucosePair(glucose: captured, clock: try XCTUnwrap(G7TransmitterTimeMessage(
            Fixture.transmitterTime(current: 100, sessionStart: G7TransmitterTimeMessage.noSession)))), "no session: not usable")
        XCTAssertNil(G7CoexistenceGlucoseMessage(Data(hex: "31008eaf0000335bd7009900060582bf")), "bad CRC")
        XCTAssertNil(G7TransmitterTimeMessage(Data(hex: "25003e5bd700f0ccd30001000000a0f2") + Data([0x00])), "wrong length")
    }

    // MARK: - S5

    /// Reconnect and relaunch: after the first observed wake the sensor is followed with a pending
    /// connection; a relaunch restores it, shows `.searching` (no pairing), and readings continue in
    /// the same session.
    func test_S5_reconnectAndRelaunchContinueListening() throws {
        let store = G7InMemoryCredentialStore()
        let harness = makeHarness(store: store)
        try harness.controller.start(pairingCode: nil)
        harness.wake(frames: [Fixture.tenDayExtendedVersion, harness.dexcomGlucose(120)])
        XCTAssertEqual(harness.central.connectRequests.last, harness.identifier, "pending connection to the followed sensor")
        let session = try XCTUnwrap(harness.controller.currentSession)

        let relaunched = makeHarness(store: store, relaunchOf: harness)
        relaunched.controller.emitInitialState()
        XCTAssertEqual(relaunched.states.last, .searching)
        XCTAssertEqual(relaunched.controller.currentSession, session)
        try relaunched.controller.start(pairingCode: nil)
        XCTAssertEqual(relaunched.central.connectRequests.last, relaunched.identifier)
        relaunched.clock.advance(300)
        relaunched.wake(frames: [relaunched.dexcomGlucose(124)])
        XCTAssertEqual(relaunched.readings.map(\.value), [.mgdl(124)])
        XCTAssertEqual(relaunched.controller.currentSession, session)
        XCTAssertEqual(relaunched.readings.first?.id, "DXCM4F-1A2B3C4D:\(relaunched.sensorClock - 5)")
    }

    /// The mode is visible: transient progress states, the summary text, no calibration and no Trio
    /// heartbeat. A latched end works as in primary mode.
    func test_S5_listenStatesAndSessionEnd() throws {
        let harness = makeHarness()
        try harness.controller.start(pairingCode: nil)
        harness.central.connected = [G7ConnectedSensor(name: "Dexcom4F", identifier: harness.identifier)]
        harness.controller.didDiscover(name: "DXCM4F", identifier: harness.identifier)
        let link = FakeLink(identifier: harness.identifier)
        harness.controller.didConnect(link: link, availableCharacteristics: Set(G7Characteristic.allCases))
        XCTAssertEqual(harness.states, [.searching, .authenticating])
        harness.controller.didDisconnect(peripheralIdentifier: harness.identifier)
        XCTAssertEqual(harness.controller.mode, .listen)
        XCTAssertEqual(G7ConnectionMode.listen.summary, "Listening; the Dexcom app owns the connection")
        XCTAssertNil(harness.controller.heartbeatTarget)

        for _ in 0..<2 {
            harness.clock.advance(300)
            harness.wake(frames: [Fixture.tenDayExtendedVersion, harness.dexcomGlucose(nil, state: 0x19)])
        }
        XCTAssertEqual(harness.states.last, .failed(G7FailureReason.sensorFailed))
        XCTAssertEqual(harness.record?.sessionEnd, .sensorFailed)
        XCTAssertNil(harness.controller.currentSession)
    }

    /// Switching modes drops the other mode's stored state, with nothing orphaned: a primary pairing
    /// (code, key) is deleted when the source starts in listen mode, and `setMode` back to primary
    /// deletes the listen record and reports `.notPaired`.
    func test_S5_switchingModesDropsStoredStateCleanly() throws {
        let store = G7InMemoryCredentialStore()
        let primary = ControllerHarness(store: store)
        try primary.pair(glucose: primary.currentGlucose(120))
        XCTAssertNotNil(primary.record?.sharedKey)

        let listening = makeHarness(store: store)
        listening.controller.emitInitialState()
        XCTAssertNil(try store.load(), "the primary code and key are gone")
        XCTAssertEqual(listening.states.last, .searching)
        try listening.controller.start(pairingCode: nil)
        XCTAssertEqual(try store.load()?.isListenRecord, true)
        XCTAssertTrue(listening.log.messages.contains { $0.contains("stored primary-mode pairing dropped") })
        listening.wake(frames: [Fixture.tenDayExtendedVersion, listening.dexcomGlucose(121)])
        XCTAssertNotNil(listening.record?.serial)

        try listening.controller.setMode(.primary(slot: .mobileApp))
        XCTAssertNil(try store.load())
        XCTAssertEqual(listening.states.last, .notPaired)
        XCTAssertNil(listening.controller.currentSession)
        XCTAssertEqual(listening.controller.mode, .primary(slot: .mobileApp))
        try listening.controller.setMode(.primary(slot: .mobileApp)) // same mode: nothing happens
        XCTAssertEqual(listening.states.last, .notPaired)
    }

    // MARK: - D47

    /// Raw recording: off by default; when on, every glucose packet's hex, valid ones included, is
    /// logged with its time — `0x4E` in both modes, `0x31`/`0x25` in listen mode.
    func test_rawGlucosePacketsAreRecordedOnlyWhenEnabled() throws {
        let quiet = makeHarness()
        try quiet.controller.start(pairingCode: nil)
        quiet.wake(frames: [Fixture.tenDayExtendedVersion, quiet.dexcomGlucose(120)])
        XCTAssertFalse(quiet.log.messages.contains { $0.contains("raw ") })

        let recording = makeHarness(recordsRaw: true)
        try recording.controller.start(pairingCode: nil)
        let valid = recording.dexcomGlucose(120)
        let pairGlucose = Fixture.coexistenceGlucose(readingTransmitterTime: 1_000_000, glucose: 99)
        recording.wake(frames: [Fixture.tenDayExtendedVersion, valid, pairGlucose])
        XCTAssertTrue(recording.log.messages.contains("G7: raw listen packet \(valid.hexString)"))
        XCTAssertTrue(recording.log.messages.contains("G7: raw listen packet \(pairGlucose.hexString)"))
        XCTAssertFalse(recording.log.messages.contains { $0.contains("raw listen packet 52") }, "only glucose packets")

        let primary = ControllerHarness()
        primary.controller.recordsRawGlucosePackets = true
        try primary.pair(glucose: primary.currentGlucose(120))
        let low = primary.currentGlucose(38)
        primary.clock.advance(300)
        let lowPacket = primary.currentGlucose(38)
        primary.connection(glucose: lowPacket)
        XCTAssertTrue(primary.log.messages.contains("G7: raw primary packet \(lowPacket.hexString)"), "\(low.hexString)")
        recording.controller.recordsRawGlucosePackets = false
        recording.clock.advance(300)
        let after = recording.dexcomGlucose(121)
        recording.wake(frames: [after])
        XCTAssertFalse(recording.log.messages.contains { $0.contains(after.hexString) })
    }
}
