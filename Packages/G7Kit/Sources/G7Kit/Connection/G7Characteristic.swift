// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// The original file carries no copyright header of its own.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/G7/CGMG7Transmitter.swift @ 7.1.0 (0370937)
// Changes: the private UUID enum is a standalone type; the unused Communication characteristic
// is kept only so discovery can name it.

/// GATT UUIDs of the G7 sensor. All characteristics live in one service.
enum G7GATT {
    /// 16-bit service UUID in the G7 advertisement; used as the scan filter so scanning works in
    /// the background (CGMG7Transmitter.swift:150-151; G7SensorKit BluetoothServices.swift:19).
    static let advertisementServiceUUID = "FEBC"
    /// The CGM service (CGMG7Transmitter.swift:153-154; G7SensorKit BluetoothServices.swift:20).
    static let serviceUUID = "F8083532-849E-531C-C594-30F1F86A4EA5"
    /// Advertised names of G7 10-day (and 15-day) sensors start with "DXCM"; ONE+ is "DX02" and
    /// Stelo "DX01", which this package does not support (G7SensorKit G7Sensor.swift:246-248;
    /// xDrip Tests/DexcomG7CalibrationTests.swift:141-148).
    static let sensorNamePrefix = "DXCM"
}

/// The five characteristics of the G7 service (CGMG7Transmitter.swift:129-148).
enum G7Characteristic: String, CaseIterable, Sendable {
    /// Read/notify; unused in primary mode (CGMG7Transmitter.swift:751).
    case communication = "F8083533-849E-531C-C594-30F1F86A4EA5"
    /// Write/indicate: GetData, calibration, extended version; glucose and command responses.
    case writeControl = "F8083534-849E-531C-C594-30F1F86A4EA5"
    /// Write/indicate: small authentication control packets.
    case receiveAuthentication = "F8083535-849E-531C-C594-30F1F86A4EA5"
    /// Notify: 9-byte backfill records.
    case backfill = "F8083536-849E-531C-C594-30F1F86A4EA5"
    /// Notify/write-without-response: J-PAKE payloads, certificates, signatures in 20-byte fragments.
    case authStream = "F8083538-849E-531C-C594-30F1F86A4EA5"

    /// The four characteristics primary mode cannot work without.
    static let required: Set<G7Characteristic> = [.writeControl, .receiveAuthentication, .backfill, .authStream]
}
