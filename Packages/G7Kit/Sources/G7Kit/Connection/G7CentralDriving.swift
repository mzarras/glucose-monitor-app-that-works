// Original to Sensor (no ported code).

import Foundation

/// What the controller asks of the Bluetooth central. `G7CoreBluetoothCentral` implements it with
/// CoreBluetooth; tests use a recorder. Called on the controller's queue.
protocol G7CentralDriving: AnyObject {
    /// Scans for the G7 advertisement service (FEBC), which also works in the background.
    func scanForSensors()
    func stopScanning()
    /// Requests a connection to a peripheral iOS already knows. The request never times out, so
    /// iOS connects whenever the sensor next advertises, even with the app suspended — the design
    /// for the G7's ~5-minute advertise/connect cycle (HANDOFF §4.6). Returns false if iOS does not
    /// know the identifier (then the caller scans).
    func connect(peripheralIdentifier: UUID) -> Bool
    func cancelConnection(peripheralIdentifier: UUID)
    /// Runs `action` on the controller's queue after `delay` seconds (connect timeouts).
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void)
    /// Listen mode (D45): G7 peripherals that are connected to this phone right now — by the Dexcom
    /// app — found by the G7 service (CBCentralManager.retrieveConnectedPeripherals, as
    /// CGMG7Transmitter.swift:2082-2087 / BluetoothTransmitter.swift:561-586).
    func connectedSensors() -> [G7ConnectedSensor]
}

/// A G7 peripheral another app on this phone is connected to.
struct G7ConnectedSensor: Equatable {
    /// `CBPeripheral.name`: "DXCMxx" or, once connected, sometimes "Dexcomxx" (G7SensorKit
    /// G7Sensor.swift:246-247).
    let name: String?
    let identifier: UUID
}

/// The sensor serial used in reading ids and `SensorSession.serial`.
enum G7SensorSerial {
    /// `"<advertised name>-<first 8 hex digits of the iOS peripheral identifier>"`, fixed once at
    /// the first authenticated connection and stored in the pairing record.
    ///
    /// Why not the advertised name alone: G7 names are "DXCM" + 2 characters (G7SensorKit
    /// G7Sensor.swift:246-250 matches on `suffix(2)`), about 1 300 values, so over a few years two
    /// sensors will share a name. Sensor timestamps restart near 0 every session, so
    /// `GlucoseReading.sensorID` would then collide and the store's insert-or-ignore (S3 dedupe)
    /// would silently drop the second sensor's readings. The iOS identifier is random per peripheral
    /// and stable for a bonded one, which makes the serial unique per physical sensor.
    static func make(sensorName: String, peripheralIdentifier: UUID) -> String {
        "\(sensorName)-\(peripheralIdentifier.uuidString.prefix(8))"
    }
}
