// Fixed inputs to the engine that are not user settings.

import Foundation

public struct AlertEngineConfiguration: Sendable {
    /// Time zone and calendar for quiet hours and for the times written in notification text. The
    /// default follows the phone, including a time-zone change while the app runs (travel, DST).
    public var calendar: Calendar
    public var locale: Locale

    #if DEBUG
    /// DEBUG builds only (PROGRESS.md D11): accept `.replay` readings, so alerts can be exercised
    /// on ReplayKit scenarios (HANDOFF §10 gate 4, §11 step 1). The property does not exist in
    /// Release builds, so a Release engine cannot be configured to accept replay (S6). `.imported`
    /// and `.mock` are refused regardless.
    public var acceptsReplayReadings: Bool = false
    #endif

    public init(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) {
        self.calendar = calendar
        self.locale = locale
    }
}
