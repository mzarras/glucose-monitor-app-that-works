// Original to Sensor (no ported code).

import Foundation

/// One live BLE connection to a sensor, as the protocol logic sees it. The CoreBluetooth
/// implementation is `G7CoreBluetoothLink`; tests use a fake that records every call. This is the
/// peripheral abstraction that makes the connection/auth message flow testable without Bluetooth.
///
/// All methods are called on, and all callbacks arrive on, the one serial queue that owns the
/// connection (see `G7CGMSource`).
protocol G7Link: G7ObservingLink {
    /// - Returns: false if the write could not be queued (characteristic unknown or not connected).
    @discardableResult
    func write(_ data: Data, to characteristic: G7Characteristic, withResponse: Bool) -> Bool
    func disconnect()
    /// Runs `action` on the connection's queue after `delay` seconds. Used to space Auth_Stream
    /// writes without response (DexcomG7AuthSession.swift:632-659).
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void)
}

/// The read-only view of a link that listen mode (D45) gets: it can subscribe to notifications but
/// has no way to write to the sensor or to drop the connection, so "never write in listen mode" is
/// enforced by the type system for `G7ListenCycle`.
protocol G7ObservingLink: AnyObject {
    var peripheralIdentifier: UUID { get }
    /// The name iOS reports for the connected peripheral (may be "Dexcom…" rather than the
    /// advertised "DXCM…", G7SensorKit G7Sensor.swift:246-247); a fallback only.
    var peripheralName: String? { get }
    func setNotify(_ enabled: Bool, for characteristic: G7Characteristic)
    func isNotifying(_ characteristic: G7Characteristic) -> Bool
}

/// Why a link operation (notify or write) failed, reduced to what the state machine acts on.
enum G7LinkError: Error, Equatable, Sendable {
    /// iOS could not complete the encrypted link: the user cancelled the system pairing prompt,
    /// ignored it until it timed out, or the bond is missing (CBATTError.insufficientAuthentication,
    /// .insufficientEncryption, CBError.encryptionTimedOut).
    case pairingNotCompleted
    /// The sensor forgot this phone's bond (CBError.peerRemovedPairingInformation).
    case bondRemovedBySensor
    case other(String)
}
