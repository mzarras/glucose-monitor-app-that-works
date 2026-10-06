// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// The original file carries no copyright header of its own.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/DexcomG7CalibrationMessages.swift @ 7.1.0 (0370937)
// Changes: `DexcomG7TransmitterClockReference` generalised into the one clock used for readings,
// backfill, the session and calibration; anchored to the sensor clock at receipt (see below).

import Foundation
import GlucoseCore

/// The sensor's session clock anchored to the phone's clock at the moment a `0x4E` arrived (S3).
///
/// The sensor reports its session age (seconds since the session started) in bytes 2-5 of `0x4E`.
/// Receiving it at phone time `receivedAt` gives `sessionStart = receivedAt − sensorClock`
/// (LoopKit G7SensorKit G7Sensor.swift:129: `activationDate = Date() − messageTimestamp`).
/// Every sensor-reported time `t` (seconds since session start) then maps to `sessionStart + t`.
/// G7ReadingPipeline keeps the first anchor's session start for the whole session and uses later
/// anchors only to check it (30 s rule), so reading dates never jitter between connections.
/// Nothing is assumed: no fixed cadence, no "now" as a reading time.
///
/// The same anchor converts a fingerstick time to sensor time for calibration
/// (DexcomG7CalibrationMessages.swift:273-288, `transmitterTime(for:)`). xDrip4iOS paired the clock
/// field with `receivedAt − age` (CGMG7Transmitter.swift:1114-1117), which by the evidence in
/// G7GlucoseMessage (Sensor change 2) shifts calibration times `age` seconds into the future; here the
/// clock field is paired with the receipt time it describes.
struct G7SessionClock: Equatable, Sendable {
    /// Bytes 2-5 of the `0x4E` that anchored this clock.
    let sensorClockAtReceipt: UInt32
    let receivedAt: Date

    var sessionStart: Date {
        receivedAt.addingTimeInterval(-TimeInterval(sensorClockAtReceipt))
    }

    /// Sensor time for a phone time, rounded to whole seconds; nil before the session started
    /// (DexcomG7CalibrationMessages.swift:281-288). Used for calibration with this connection's own
    /// anchor, the freshest reading of the sensor clock.
    func sensorTime(for date: Date) -> UInt32? {
        let resolved = Double(sensorClockAtReceipt) + date.timeIntervalSince(receivedAt)
        guard resolved >= 0, resolved <= Double(UInt32.max) else { return nil }
        return UInt32(resolved.rounded())
    }
}
