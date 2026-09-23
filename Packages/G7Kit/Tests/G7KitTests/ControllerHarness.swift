// Original to Sensor (no ported code).

import Foundation
import GlucoseCore
@testable import G7Kit

/// Drives a `G7Controller` through whole sensor connections against `G7SensorSimulator`, the way
/// CoreBluetooth would, with a hand-moved clock.
final class ControllerHarness {
    let clock = TestClock()
    let store: G7InMemoryCredentialStore
    let log = RecordingDiagnosticLog()
    let central = FakeCentral()
    let sensor: G7SensorSimulator
    let identifier = UUID(uuidString: "1A2B3C4D-0000-4000-8000-000000000001")!
    let sensorName = "DXCM4F"
    var readings: [GlucoseReading] = []
    var states: [SensorState] = []
    var calibrations: [CalibrationUpdate] = []
    private(set) var controller: G7Controller!
    /// Phone time at which the sensor session started (the sensor clock is `now − sessionStart`).
    let sessionStart: Date

    init(sensorCode: String = "1234", sessionAge: TimeInterval = 2 * 86_400, store: G7InMemoryCredentialStore = G7InMemoryCredentialStore()) {
        self.store = store
        sensor = G7SensorSimulator(pairingCode: sensorCode)
        sessionStart = clock.now.addingTimeInterval(-sessionAge)
        controller = G7Controller(
            store: store,
            diagnostics: log,
            now: { [clock] in clock.now },
            slot: .mobileApp,
            output: G7Controller.Output(
                reading: { [unowned self] in readings.append($0) },
                state: { [unowned self] in states.append($0) },
                calibration: { [unowned self] in calibrations.append($0) }
            )
        )
        controller.central = central
        controller.bluetoothPowerChanged(.poweredOn)
    }

    var sensorClock: UInt32 { UInt32(clock.now.timeIntervalSince(sessionStart)) }

    /// A current `0x4E` whose reading happened `age` seconds ago.
    func currentGlucose(_ mgdl: UInt16?, state: UInt8 = 0x06, age: UInt16 = 5, flags: UInt8 = 0x0F) -> Data {
        Fixture.glucose(sensorClock: sensorClock, age: age, glucose: mgdl, state: state, flags: flags)
    }

    /// Pairs with the given code: start, discover, full J-PAKE connection, disconnect.
    @discardableResult
    func pair(code: String = "1234", glucose: Data? = nil) throws -> FakeLink {
        try controller.start(pairingCode: code)
        controller.didDiscover(name: sensorName, identifier: identifier)
        return connection(glucose: glucose)
    }

    /// One sensor wake: connect, exchange everything, disconnect. Returns the link for inspection.
    @discardableResult
    func connection(glucose: Data?, backfill: [Data] = [], failingNotify: [G7Characteristic: G7LinkError] = [:],
                    peripheral: UUID? = nil, disconnect: Bool = true) -> FakeLink {
        let peripheral = peripheral ?? identifier
        sensor.beginConnection()
        sensor.glucoseResponse = glucose
        sensor.backfillFrames = backfill
        let link = FakeLink(identifier: peripheral)
        let driver = LinkDriver(link: link, sensor: sensor,
                                deliverNotify: { [unowned self] in controller.notificationStateChanged(for: $0, isNotifying: $1, error: $2) },
                                deliverValue: { [unowned self] in controller.valueUpdated(for: $0, value: $1) })
        driver.failingNotify = failingNotify
        controller.didConnect(link: link, availableCharacteristics: Set(G7Characteristic.allCases))
        driver.pump()
        if disconnect { controller.didDisconnect(peripheralIdentifier: peripheral) }
        return link
    }

    var record: G7PairingRecord? { try? store.load() }
}
