// Quiet hours (HANDOFF §5): "a schedule that silences non-urgent alerts. Urgent low always sounds."

import Foundation

/// A daily window, in the phone's local time, during which every alert except urgent low is
/// delivered silently (still posted, still shown in the app, no sound and no in-app audio).
public struct QuietHours: Sendable, Equatable, Hashable, Encodable {
    public static let minutesPerDay = 24 * 60

    public var isEnabled: Bool
    /// Minutes after local midnight, 0…1439. Clamped on every assignment.
    public var startMinuteOfDay: Int {
        didSet { startMinuteOfDay = Self.clampMinute(startMinuteOfDay) }
    }
    /// Minutes after local midnight, 0…1439. The window is `start ..< end`, wrapping past midnight
    /// when `end <= start`. `start == end` is an empty window.
    public var endMinuteOfDay: Int {
        didSet { endMinuteOfDay = Self.clampMinute(endMinuteOfDay) }
    }

    public init(isEnabled: Bool, startMinuteOfDay: Int, endMinuteOfDay: Int) {
        self.isEnabled = isEnabled
        self.startMinuteOfDay = Self.clampMinute(startMinuteOfDay)
        self.endMinuteOfDay = Self.clampMinute(endMinuteOfDay)
    }

    /// Off by default; 22:00–07:00 when turned on.
    public static let `default` = QuietHours(isEnabled: false, startMinuteOfDay: 22 * 60, endMinuteOfDay: 7 * 60)

    /// Whether `date` falls inside the window, in `calendar`'s time zone.
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard isEnabled, startMinuteOfDay != endMinuteOfDay else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinuteOfDay < endMinuteOfDay {
            return minute >= startMinuteOfDay && minute < endMinuteOfDay
        }
        return minute >= startMinuteOfDay || minute < endMinuteOfDay
    }

    static func clampMinute(_ minute: Int) -> Int {
        AlertLimits.clamp(minute, to: 0...(minutesPerDay - 1))
    }
}
