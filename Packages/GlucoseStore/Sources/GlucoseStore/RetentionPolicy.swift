// Data retention (HANDOFF §4.4, §4.5): 90 days / 1 year / 2 years (default) / forever.

import Foundation

public enum RetentionPolicy: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case days90
    case oneYear
    case twoYears
    case forever

    /// HANDOFF §4.4: "Keep 2 years by default".
    public static let `default`: RetentionPolicy = .twoYears

    /// How long readings are kept, in seconds. Fixed-length days (86 400 s), not calendar years:
    /// storage works in UTC instants, so there is no time zone or DST to account for.
    /// `nil` = keep forever.
    public var maximumAge: TimeInterval? {
        let day: TimeInterval = 86_400
        switch self {
        case .days90: return 90 * day
        case .oneYear: return 365 * day
        case .twoYears: return 730 * day
        case .forever: return nil
        }
    }

    /// Readings dated strictly before this instant are purged. `nil` = nothing is purged.
    public func cutoff(now: Date) -> Date? {
        maximumAge.map { now.addingTimeInterval(-$0) }
    }
}
