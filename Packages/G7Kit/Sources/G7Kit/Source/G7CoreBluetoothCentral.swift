// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// BluetoothTransmitter.swift carries no copyright header of its own.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/Generic/BluetoothTransmitter.swift @ 7.1.0 (0370937)
// Changes: only what G7 primary mode uses — CBCentralManager with a FIXED restore identifier
// (xDrip4iOS derived one from the device address or a random string, :1062-1098), scan for FEBC,
// pending connects, restoration (:1003-1040), service/characteristic discovery (:918-963), and
// forwarding every callback to G7Controller. No signal-strength, timers or UserDefaults.

import CoreBluetooth
import Foundation

/// The CoreBluetooth side of G7Kit. The only file that touches CoreBluetooth.
///
/// Threading: `CBCentralManager` is created with `queue`, so every delegate callback below runs on
/// `queue`, and G7Controller is only ever called on `queue` (from here or from G7CGMSource).
final class G7CoreBluetoothCentral: NSObject, G7CentralDriving, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let queue: DispatchQueue
    private let controller: G7Controller
    private let log: (String) -> Void
    private var manager: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var links: [UUID: G7CoreBluetoothLink] = [:]

    init(queue: DispatchQueue, controller: G7Controller, restoreIdentifier: String, log: @escaping (String) -> Void) {
        self.queue = queue
        self.controller = controller
        self.log = log
        super.init()
        var options: [String: Any] = [:]
        #if os(iOS)
        // State restoration (HANDOFF §4.6): with a fixed identifier iOS relaunches the app in the
        // background for this central's events after a system termination. The app must create
        // G7CGMSource early in launch so this manager exists when iOS delivers willRestoreState.
        options[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifier
        options[CBCentralManagerOptionShowPowerAlertKey] = true
        #endif
        manager = CBCentralManager(delegate: self, queue: queue, options: options)
    }

    // MARK: - G7CentralDriving

    func scanForSensors() {
        guard let manager, manager.state == .poweredOn, !manager.isScanning else { return }
        // A service filter is required for background scanning (CGMG7Transmitter.swift:150-151 FEBC).
        manager.scanForPeripherals(withServices: [CBUUID(string: G7GATT.advertisementServiceUUID)], options: nil)
    }

    func stopScanning() {
        guard let manager, manager.isScanning else { return }
        manager.stopScan()
    }

    func connect(peripheralIdentifier: UUID) -> Bool {
        guard let manager, manager.state == .poweredOn else { return false }
        let peripheral = peripherals[peripheralIdentifier]
            ?? manager.retrievePeripherals(withIdentifiers: [peripheralIdentifier]).first
        guard let peripheral else { return false }
        peripherals[peripheralIdentifier] = peripheral
        peripheral.delegate = self
        switch peripheral.state {
        case .connected:
            // Restored while connected: rediscover so every characteristic is subscribed again
            // (BluetoothTransmitter.swift:1024-1030).
            centralManager(manager, didConnect: peripheral)
        case .connecting:
            break
        case .disconnected, .disconnecting:
            manager.connect(peripheral, options: nil)
        @unknown default:
            manager.connect(peripheral, options: nil)
        }
        return true
    }

    func cancelConnection(peripheralIdentifier: UUID) {
        guard let manager, let peripheral = peripherals[peripheralIdentifier] else { return }
        manager.cancelPeripheralConnection(peripheral)
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        controller.bluetoothPowerChanged(Self.power(central.state))
    }

    #if os(iOS)
    /// Keep the restored peripherals; the controller reconnects once Bluetooth is powered on
    /// (BluetoothTransmitter.swift:1003-1040).
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for peripheral in restored {
            peripheral.delegate = self
            peripherals[peripheral.identifier] = peripheral
        }
        log("restored \(restored.count) peripheral(s) after relaunch")
    }
    #endif

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        // The advertised local name is "DXCMxx"; after connecting, `peripheral.name` can become
        // "Dexcomxx" (G7SensorKit G7Sensor.swift:246-247), so prefer the advertisement.
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        controller.didDiscover(name: name, identifier: peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripherals[peripheral.identifier] = peripheral
        links[peripheral.identifier] = G7CoreBluetoothLink(peripheral: peripheral, queue: queue) { [weak self] in
            self?.cancelConnection(peripheralIdentifier: peripheral.identifier)
        }
        peripheral.discoverServices([CBUUID(string: G7GATT.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("connect failed: \(error?.localizedDescription ?? "no error")")
        controller.didFailToConnect(peripheralIdentifier: peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        links[peripheral.identifier] = nil
        if let error { log("disconnected: \(error.localizedDescription)") }
        controller.didDisconnect(peripheralIdentifier: peripheral.identifier)
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: G7GATT.serviceUUID) }) else {
            log("G7 service not found: \(error?.localizedDescription ?? "missing")")
            cancelConnection(peripheralIdentifier: peripheral.identifier)
            return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let link = links[peripheral.identifier] else {
            log("characteristic discovery failed: \(error?.localizedDescription ?? "no link")")
            cancelConnection(peripheralIdentifier: peripheral.identifier)
            return
        }
        let available = link.register(service.characteristics ?? [])
        controller.didConnect(link: link, availableCharacteristics: available)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let g7 = G7Characteristic(rawValue: characteristic.uuid.uuidString) else { return }
        controller.notificationStateChanged(for: g7, isNotifying: characteristic.isNotifying, error: error.map(Self.linkError))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let g7 = G7Characteristic(rawValue: characteristic.uuid.uuidString) else { return }
        if let error {
            log("value update on \(g7) failed: \(error.localizedDescription)")
            return
        }
        guard let value = characteristic.value else { return }
        controller.valueUpdated(for: g7, value: value)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let error, let g7 = G7Characteristic(rawValue: characteristic.uuid.uuidString) else { return }
        controller.writeFailed(for: g7, error: Self.linkError(error))
    }

    // MARK: - Mapping

    /// S5: CBManagerState → G7BluetoothPower → SensorState.bluetoothUnavailable (G7SensorStatus).
    static func power(_ state: CBManagerState) -> G7BluetoothPower {
        switch state {
        case .poweredOn: return .poweredOn
        case .poweredOff: return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        case .resetting: return .resetting
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
    }

    /// The iOS pairing prompt: accessing the G7's encrypted characteristics makes iOS show the
    /// system pairing request (CGMG7Transmitter.swift:45-49). Accept → the operation succeeds.
    /// Cancel or timeout → the pending operation fails with insufficient authentication/encryption
    /// or an encryption timeout, mapped to `.pairingNotCompleted` (G7FailureReason).
    static func linkError(_ error: Error) -> G7LinkError {
        let nsError = error as NSError
        if nsError.domain == CBATTErrorDomain,
           nsError.code == CBATTError.Code.insufficientAuthentication.rawValue
            || nsError.code == CBATTError.Code.insufficientEncryption.rawValue {
            return .pairingNotCompleted
        }
        if nsError.domain == CBErrorDomain {
            if nsError.code == CBError.Code.encryptionTimedOut.rawValue { return .pairingNotCompleted }
            if nsError.code == CBError.Code.peerRemovedPairingInformation.rawValue { return .bondRemovedBySensor }
        }
        return .other(nsError.localizedDescription)
    }
}

/// `G7Link` over one connected `CBPeripheral`. Used only on the central's queue.
final class G7CoreBluetoothLink: G7Link {
    private let peripheral: CBPeripheral
    private let queue: DispatchQueue
    private let cancel: () -> Void
    private var characteristics: [G7Characteristic: CBCharacteristic] = [:]

    init(peripheral: CBPeripheral, queue: DispatchQueue, cancel: @escaping () -> Void) {
        self.peripheral = peripheral
        self.queue = queue
        self.cancel = cancel
    }

    var peripheralIdentifier: UUID { peripheral.identifier }
    var peripheralName: String? { peripheral.name }

    /// Caches this connection's characteristic objects; they are invalid after disconnect
    /// (CGMG7Transmitter.swift:301-307).
    func register(_ discovered: [CBCharacteristic]) -> Set<G7Characteristic> {
        for characteristic in discovered {
            if let g7 = G7Characteristic(rawValue: characteristic.uuid.uuidString) {
                characteristics[g7] = characteristic
            }
        }
        return Set(characteristics.keys)
    }

    func setNotify(_ enabled: Bool, for characteristic: G7Characteristic) {
        guard let cb = characteristics[characteristic] else { return }
        peripheral.setNotifyValue(enabled, for: cb)
    }

    func isNotifying(_ characteristic: G7Characteristic) -> Bool {
        characteristics[characteristic]?.isNotifying ?? false
    }

    func write(_ data: Data, to characteristic: G7Characteristic, withResponse: Bool) -> Bool {
        guard peripheral.state == .connected, let cb = characteristics[characteristic] else { return false }
        peripheral.writeValue(data, for: cb, type: withResponse ? .withResponse : .withoutResponse)
        return true
    }

    func disconnect() {
        cancel()
    }

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        let job = QueueBoundAction(run: action)
        queue.asyncAfter(deadline: .now() + delay) { job.run() }
    }
}

/// Carries a closure to a later turn of the same serial queue.
/// `@unchecked Sendable` because the closure captures queue-confined, non-Sendable state
/// (the auth session): it is created on `queue` and executed on `queue`, so it never runs
/// concurrently with any other access to that state.
private struct QueueBoundAction: @unchecked Sendable {
    let run: () -> Void
}
