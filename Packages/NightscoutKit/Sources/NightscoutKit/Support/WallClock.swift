// The phone's clock, injectable so tests never sleep and never depend on the real date.

import Foundation

/// Source of "now" for importers and uploaders.
public protocol WallClock: Sendable {
    func now() -> Date
}

/// The system clock. Production default.
public struct SystemWallClock: WallClock {
    public init() {}
    public func now() -> Date { Date() }
}
