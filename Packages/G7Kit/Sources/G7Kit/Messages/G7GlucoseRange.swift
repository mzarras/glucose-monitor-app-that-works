// Original to Sensor (no ported code).

import GlucoseCore

/// S4: how a G7 glucose number becomes a `GlucoseValue`.
///
/// How the G7 signals LOW/HIGH: it has no separate LOW/HIGH flag bit in either reference
/// implementation. It reports the number itself (low 12 bits of bytes 12-13 of `0x4E`, bytes 4-5 of a
/// backfill record), and its reportable range is 40...400 mg/dL. A number below 40 is the sensor's
/// LOW and a number above 400 is its HIGH:
/// - LoopKit G7SensorKit G7GlucoseMessage.swift:56-68 and G7BackfillMessage.swift:82-94
///   (`condition`: `glucose < GlucoseLimits.minimum` → `.belowRange`, `> maximum` → `.aboveRange`);
/// - G7SensorKit GlucoseLimits.swift:11-13 (`minimum = 40`, `maximum = 400`), which is also
///   `GlucoseValue.sensorReportableRange` in GlucoseCore.
/// xDrip4iOS 7.1.0 passes the raw number through unchanged (DexcomG7GlucoseDataRxMessage.swift:92-104).
/// No capture of an actual G7 LOW or HIGH packet exists in either repository, so the exact numbers
/// a real LOW/HIGH carries (e.g. 39 or 0; 401 or 4095) are unverified; every one of them maps to the
/// flag, never to 40/400 (S4). Verify on device (docs/g7-protocol.md, open items).
enum G7GlucoseRange {
    static func value(fromSensorMgdl raw: UInt16) -> GlucoseValue {
        let mgdl = Int(raw)
        if mgdl < GlucoseValue.sensorReportableRange.lowerBound { return .belowRange }
        if mgdl > GlucoseValue.sensorReportableRange.upperBound { return .aboveRange }
        return .mgdl(mgdl)
    }
}
