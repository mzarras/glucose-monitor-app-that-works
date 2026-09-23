// Contract (HANDOFF §4.3, §6, S4). Owned by the orchestrator; change only through PROGRESS.md.

/// A glucose value exactly as the sensor reported it.
///
/// S4: LOW and HIGH are flags, not numbers. Never turn `.belowRange` into 40 or
/// `.aboveRange` into 400 and present or transmit it as an ordinary value.
public enum GlucoseValue: Sendable, Equatable, Hashable, Codable {
    /// A numeric value inside `GlucoseValue.sensorReportableRange` (40...400), as reported.
    /// Values outside that range are refused by `LiveReadingGate` (S2).
    case mgdl(Int)
    /// Sensor LOW flag (below the sensor's reportable range).
    case belowRange
    /// Sensor HIGH flag (above the sensor's reportable range).
    case aboveRange

    /// The G7's numeric reporting range in mg/dL. Anything the sensor cannot measure is reported as
    /// the LOW/HIGH flag instead. Source: LoopKit G7SensorKit `GlucoseLimits.swift`
    /// (`minimum = 40`, `maximum = 400`), vendor-ref/Trio/G7SensorKit/G7SensorKit/GlucoseLimits.swift.
    public static let sensorReportableRange: ClosedRange<Int> = 40...400

    /// The numeric value, or `nil` for the LOW/HIGH flags (S4).
    /// Statistics exclude `nil` values from mean/SD (HANDOFF §6).
    public var numericMgdl: Int? {
        if case .mgdl(let value) = self { return value }
        return nil
    }

    /// Consensus range bin (HANDOFF §6). LOW counts as `.veryLow`, HIGH as `.veryHigh`.
    public var band: GlucoseBand {
        switch self {
        case .belowRange: return .veryLow
        case .aboveRange: return .veryHigh
        case .mgdl(let value): return GlucoseBand(mgdl: value)
        }
    }
}

/// The five International Consensus on Time in Range bins, also used for UI colour (HANDOFF §6, §7.1).
public enum GlucoseBand: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// < 54 mg/dL, and the sensor LOW flag.
    case veryLow
    /// 54–69 mg/dL.
    case low
    /// 70–180 mg/dL.
    case inRange
    /// 181–250 mg/dL.
    case high
    /// > 250 mg/dL, and the sensor HIGH flag.
    case veryHigh

    public init(mgdl value: Int) {
        switch value {
        case ..<GlucoseThresholds.veryLowBelow: self = .veryLow
        case ..<GlucoseThresholds.lowBelow: self = .low
        case ...GlucoseThresholds.inRangeUpperBound: self = .inRange
        case ...GlucoseThresholds.highUpperBound: self = .high
        default: self = .veryHigh
        }
    }
}

/// Consensus range-bin boundaries in mg/dL. One place, so stats, UI and widgets agree (HANDOFF §6).
///
/// These are statistics bins, not alert thresholds: 70 is "in range" here, while the Low alert
/// (HANDOFF §5, "≤ 70") fires at 70. Alert thresholds are inclusive and live in AlertEngine.
public enum GlucoseThresholds {
    /// Values below this are "very low" (< 54).
    public static let veryLowBelow = 54
    /// Values below this are "low" (< 70). Also the lower bound of the target range.
    public static let lowBelow = 70
    /// Upper bound of the target range, inclusive (70–180).
    public static let inRangeUpperBound = 180
    /// Upper bound of "high", inclusive (181–250).
    public static let highUpperBound = 250
    /// Upper bound of the tight range, inclusive (70–140).
    public static let tightRangeUpperBound = 140
}
