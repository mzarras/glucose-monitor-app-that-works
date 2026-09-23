// Overnight vs day time in range (HANDOFF §6: TIR split 00:00–06:00 vs 06:00–24:00, window
// configurable).

import GlucoseCore

/// A daily window of local wall-clock time, `[start, end)` in minutes after midnight. When `start`
/// is after `end` the window wraps past midnight (e.g. 22:00–06:00).
public struct DailyWindow: Sendable, Equatable, Hashable {
    /// 0…1 439.
    public let startMinuteOfDay: Int
    /// 0…1 440 (1 440 = midnight at the end of the day).
    public let endMinuteOfDay: Int

    /// 00:00–06:00 (HANDOFF §6).
    public static let defaultOvernight = DailyWindow(validStart: 0, validEnd: 6 * 60)

    /// `nil` when a bound is out of range or the window is empty (`start == end`).
    public init?(startMinuteOfDay: Int, endMinuteOfDay: Int) {
        guard (0..<1_440).contains(startMinuteOfDay),
              (0...1_440).contains(endMinuteOfDay),
              startMinuteOfDay != endMinuteOfDay else { return nil }
        self.init(validStart: startMinuteOfDay, validEnd: endMinuteOfDay)
    }

    private init(validStart: Int, validEnd: Int) {
        startMinuteOfDay = validStart
        endMinuteOfDay = validEnd
    }

    /// Whether a local time of day (seconds after midnight) is inside the window.
    public func contains(secondOfDay: Int) -> Bool {
        let minute = secondOfDay / 60
        if startMinuteOfDay < endMinuteOfDay {
            return minute >= startMinuteOfDay && minute < endMinuteOfDay
        }
        return minute >= startMinuteOfDay || minute < endMinuteOfDay
    }
}

/// Time in range (70–180) among the readings of one part of the day.
public struct WindowTimeInRange: Sendable, Equatable {
    public let readingCount: Int
    public let inRangeCount: Int
    /// `inRangeCount / readingCount × 100`; `nil` without readings.
    public let inRangePercent: Double?

    init(readingCount: Int, inRangeCount: Int) {
        self.readingCount = readingCount
        self.inRangeCount = inRangeCount
        self.inRangePercent = percentage(inRangeCount, of: readingCount)
    }
}

/// TIR inside the overnight window vs the rest of the day ("day"). LOW/HIGH count in the
/// denominator and are never in range (S4). On a fall-back day both passes through 01:00–01:59
/// are overnight; that is what the wall clock said.
public struct OvernightAndDayTimeInRange: Sendable, Equatable {
    public let window: DailyWindow
    public let overnight: WindowTimeInRange
    /// Every reading outside `window`.
    public let day: WindowTimeInRange

    public init(_ period: PeriodReadings, window: DailyWindow) {
        var overnightCount = 0
        var overnightInRange = 0
        var dayCount = 0
        var dayInRange = 0
        period.forEachReading { _, reading in
            let inRange = reading.band == .inRange
            if window.contains(secondOfDay: reading.secondOfDay) {
                overnightCount += 1
                if inRange { overnightInRange += 1 }
            } else {
                dayCount += 1
                if inRange { dayInRange += 1 }
            }
        }
        self.window = window
        overnight = WindowTimeInRange(readingCount: overnightCount, inRangeCount: overnightInRange)
        day = WindowTimeInRange(readingCount: dayCount, inRangeCount: dayInRange)
    }
}
