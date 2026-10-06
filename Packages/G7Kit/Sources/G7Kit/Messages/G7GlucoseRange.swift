// Original to Sensor (no ported code).

import GlucoseCore

/// What one G7 glucose field (bytes 12-13 of `0x4E`, bytes 4-5 of a backfill record) means.
enum G7GlucoseSample: Equatable {
    case value(GlucoseValue)
    /// No usable value: withheld, logged and surfaced, never LOW/HIGH (D31, S4/S5).
    case noValue(field: UInt16)
}

/// S4 and D31: how a G7 glucose field becomes a `GlucoseValue`.
///
/// No value (PROGRESS.md D31): the field `0xFFFF` (the documented "none" sentinel,
/// DexcomG7GlucoseDataRxMessage.swift:92-104), the field `0xFFFE`, and a masked value of 0 or
/// `0x0FFF`. These are the values a misread or garbled packet produces; mapping them to LOW/HIGH
/// would send a flag (HIGH = 401 downstream) that the sensor never reported.
///
/// Otherwise the value is the low 12 bits (the upper 4 are flags) and the G7 signals LOW/HIGH with
/// the number itself: it has no separate LOW/HIGH bit in either reference. Below 40 is LOW, above
/// 400 is HIGH — LoopKit G7SensorKit G7GlucoseMessage.swift:56-68 and G7BackfillMessage.swift:82-94
/// (`condition`), GlucoseLimits.swift:11-13 (40, 400) = `GlucoseValue.sensorReportableRange`.
/// No capture of a real G7 LOW or HIGH packet exists in any reference (docs/g7-protocol.md §5.3,
/// a HANDOFF §11 item).
enum G7GlucoseRange {
    static func classify(field: UInt16) -> G7GlucoseSample {
        if field == 0xFFFF || field == 0xFFFE { return .noValue(field: field) }
        let raw = field & 0x0FFF
        if raw == 0 || raw == 0x0FFF { return .noValue(field: field) }
        let mgdl = Int(raw)
        if mgdl < GlucoseValue.sensorReportableRange.lowerBound { return .value(.belowRange) }
        if mgdl > GlucoseValue.sensorReportableRange.upperBound { return .value(.aboveRange) }
        return .value(.mgdl(mgdl))
    }
}
