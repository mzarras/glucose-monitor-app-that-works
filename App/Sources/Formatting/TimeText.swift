// Clock times, dates and durations for UI copy. Locale and time zone are parameters so tests are
// deterministic; the app passes `.current`.

import Foundation

struct DisplayContext: Sendable {
    var locale: Locale
    var timeZone: TimeZone

    static var current: DisplayContext {
        DisplayContext(locale: .autoupdatingCurrent, timeZone: .autoupdatingCurrent)
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        return calendar
    }
}

enum TimeText {
    /// Clock time in the user's 12/24-hour style: "12:35" or "12:35 PM".
    static func time(_ date: Date, _ context: DisplayContext = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = context.locale
        style.timeZone = context.timeZone
        return date.formatted(style)
    }

    /// Now header date: "Wed, Sep 23" (en_US) / "Wed 23 Sep" (en_GB).
    static func headerDate(_ date: Date, _ context: DisplayContext = .current) -> String {
        var style = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
        style.locale = context.locale
        style.timeZone = context.timeZone
        return date.formatted(style)
    }

    /// "SEP 10", for the Trends date range.
    static func shortDay(_ date: Date, _ context: DisplayContext = .current) -> String {
        var style = Date.FormatStyle().month(.abbreviated).day()
        style.locale = context.locale
        style.timeZone = context.timeZone
        return date.formatted(style)
    }

    /// Compact duration, two largest units: "4d 7h", "1h 12m", "35m", "0m". Rounds down.
    static func duration(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int(interval / 60))
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

    /// "1 min", "12 min", "1 h 5 min", for sentences.
    static func minutesPhrase(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }
}
