// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// The original file carries no copyright header of its own.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/G7/CGMG7Transmitter.swift @ 7.1.0 (0370937)
// Changes: the two `getCBUUID_*` answers (:875-876) plus the peripheral identifier, as one value.
// G7Kit never writes them anywhere; TrioBridge publishes them (see docs/g7-protocol.md "Trio heartbeat").

import Foundation

/// What a second app (Trio) needs to connect to the same G7 as a "heartbeat" central, so the
/// sensor's ~5-minute connection wakes it.
///
/// xDrip4iOS 7.1.0 publishes exactly these three values into the loop app's App Group under
/// `cgmTransmitterDeviceAddress`, `cgmTransmitter_CBUUID_Service`, `cgmTransmitter_CBUUID_Receive`
/// (BluetoothPeripheralManager.swift:614-642), whenever the active CGM's peripheral address changes
/// (:49-68) and only while sharing to the loop app is permitted; it removes them otherwise
/// (:647-655, LoopManager.swift:797-806). For the G7 the characteristic is Receive_Authentication
/// (CGMG7Transmitter.swift:876): it is readable without link encryption, so a second central can
/// subscribe without an iOS pairing prompt, and it carries only authentication traffic, not data.
public struct G7HeartbeatTarget: Sendable, Equatable {
    /// `CBPeripheral.identifier` of the paired sensor (xDrip4iOS `deviceAddress` is this UUID string).
    public let peripheralIdentifier: UUID
    /// The G7 CGM service, F8083532-… (CGMG7Transmitter.swift:153-154, :875).
    public let serviceUUID: String
    /// Receive_Authentication, F8083535-… (CGMG7Transmitter.swift:135, :876).
    public let characteristicUUID: String

    init(peripheralIdentifier: UUID) {
        self.peripheralIdentifier = peripheralIdentifier
        self.serviceUUID = G7GATT.serviceUUID
        self.characteristicUUID = G7Characteristic.receiveAuthentication.rawValue
    }
}
