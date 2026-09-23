// Contract (HANDOFF §7.5, §8A). Owned by the orchestrator; change only through PROGRESS.md.

/// Trend arrow derived from the sensor-reported rate of change. Never derived from a model or
/// from differences between readings.
public enum TrendArrow: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case doubleUp
    case singleUp
    case fortyFiveUp
    case flat
    case fortyFiveDown
    case singleDown
    case doubleDown
    /// No rate reported, or the rate is not a finite number.
    case notComputable

    /// The only place the arrow thresholds live (HANDOFF §7.5). Units: mg/dL per minute, applied to |rate|.
    ///
    ///     |r| < 1          flat
    ///     1 ≤ |r| < 2      forty-five degrees
    ///     2 ≤ |r| ≤ 3      single
    ///     |r| > 3          double
    ///
    /// The handoff's "1–2" and "2–3" ranges share the point 2; 2 maps to single, 3 maps to single.
    public enum Threshold {
        public static let flatBelow: Double = 1
        public static let fortyFiveBelow: Double = 2
        public static let singleUpToInclusive: Double = 3
    }

    public init(rate: Double?) {
        guard let rate, rate.isFinite else {
            self = .notComputable
            return
        }
        let magnitude = abs(rate)
        let rising = rate > 0
        if magnitude < Threshold.flatBelow {
            self = .flat
        } else if magnitude < Threshold.fortyFiveBelow {
            self = rising ? .fortyFiveUp : .fortyFiveDown
        } else if magnitude <= Threshold.singleUpToInclusive {
            self = rising ? .singleUp : .singleDown
        } else {
            self = rising ? .doubleUp : .doubleDown
        }
    }

    /// Nightscout `direction` string for this arrow (HANDOFF §8A step 1).
    public var nightscoutDirection: String {
        switch self {
        case .doubleUp: return "DoubleUp"
        case .singleUp: return "SingleUp"
        case .fortyFiveUp: return "FortyFiveUp"
        case .flat: return "Flat"
        case .fortyFiveDown: return "FortyFiveDown"
        case .singleDown: return "SingleDown"
        case .doubleDown: return "DoubleDown"
        case .notComputable: return "NOT COMPUTABLE"
        }
    }
}
