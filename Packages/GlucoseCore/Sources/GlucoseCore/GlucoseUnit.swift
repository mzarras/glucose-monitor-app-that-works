// Contract. mg/dL only in v1; the type exists so mmol/L can be added without touching call sites
// (HANDOFF §7.3 Settings, §12).

public enum GlucoseUnit: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case mgdL
}
