// Optional heartbeat advertisement for Trio (docs/trio-bridge.md, "When Trio reads").
//
// Trio polls the App Group on a one-minute timer that only runs while Trio is awake
// (`Trio/Sources/APS/FetchGlucoseManager.swift:45, :89-124`). To be woken in the background it can open
// its own CoreBluetooth connection to the CGM peripheral named in the App Group and poll on every
// disconnect or notification (`Trio/Sources/APS/CGM/HeartBeatManager.swift:25-75`,
// `Trio/Sources/APS/CGM/BluetoothTransmitter.swift:256-260`). xDrip4iOS 7.1.0 advertises its G7 this way,
// naming the G7 service and its authentication characteristic
// (`xDrip/BluetoothTransmitter/CGM/Dexcom/G7/CGMG7Transmitter.swift:875-876`).
//
// The bridge only writes these three strings when the app asks it to. Whether this app should let Trio
// connect to the sensor it authenticates to is a BLE decision (G7Kit / Phase 2), not the bridge's.

import Foundation

/// The CGM peripheral Trio should use as its heartbeat.
public struct TrioHeartbeatPeripheral: Sendable, Equatable, Hashable {
    /// `CBPeripheral.identifier` of the sensor, as this phone knows it.
    public let peripheralIdentifier: UUID
    /// Service UUID Trio discovers, as a string (`CBUUID(string:)` form).
    public let serviceUUID: String
    /// Characteristic UUID Trio subscribes to, as a string.
    public let receiveCharacteristicUUID: String

    public init(peripheralIdentifier: UUID, serviceUUID: String, receiveCharacteristicUUID: String) {
        self.peripheralIdentifier = peripheralIdentifier
        self.serviceUUID = serviceUUID
        self.receiveCharacteristicUUID = receiveCharacteristicUUID
    }
}
