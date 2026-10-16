// What a widget shows as a number, and how (D61). Widget only: the Now screen keeps
// `GlucoseDisplayState.displayedReading` and never shows an old number on its own (HANDOFF §7.3).
//
//   age < 10 min    current  ink / band colour, trend arrow, delta, live age
//   10–20 min       stale    muted number, "STALE · 12 min ago"; no arrow, no delta
//   ≥ 20 min        last     muted number, "LAST READING · 2:14 PM · 47 min ago", however old;
//                            no arrow, no delta
//
// The arrow and the delta describe the moment of the reading, and next to an old number they would
// read as the current direction, so only a current reading has them. The number is always the
// snapshot's own `latest`, unchanged (S1); a LOW/HIGH stays a flag (S4).

import Foundation
import GlucoseCore

public struct WidgetReading: Sendable, Equatable {
    public enum Age: Sendable, Equatable {
        /// Under 10 min old (`GlucoseDisplayState.current`).
        case current
        /// 10 ≤ age < 20 min (`.stale`).
        case stale
        /// 20 min or older (`.noData(last:)` with a reading), with no upper limit (D61).
        case last
    }

    public let reading: LatestReading
    public let age: Age

    public init(reading: LatestReading, age: Age) {
        self.reading = reading
        self.age = age
    }

    /// Muted colour (≥ 3:1, never faded by opacity) for every reading that is not current.
    public var isMuted: Bool { age != .current }

    /// The trend arrow, only while the reading is current.
    public var trend: TrendArrow? { age == .current ? reading.trend : nil }

    /// The delta, only while the reading is current.
    public var delta: GlucoseDelta? { age == .current ? reading.delta : nil }
}

extension GlucoseDisplayState {
    /// The reading a widget shows as a number in this state, and at which age (D61). `nil` for
    /// "No data" without any reading and for every message state (warm-up, expired, error,
    /// failed, calibration, not paired, clock mismatch). The Now screen does not use this.
    public var widgetReading: WidgetReading? {
        switch self {
        case .current(let reading): return WidgetReading(reading: reading, age: .current)
        case .stale(let reading): return WidgetReading(reading: reading, age: .stale)
        case .noData(let last?): return WidgetReading(reading: last, age: .last)
        case .noData(.none), .warmingUp, .sensorExpired, .sensorError, .sensorFailed, .calibrationNeeded, .calibrationRejected, .notPaired, .clockMismatch:
            return nil
        }
    }
}

/// Which local day a last reading was taken on, seen from a timeline entry (D61): "2:14 PM",
/// "Yesterday 11:02 PM", or "Oct 14 9:30 AM".
public enum ReadingDay: Sendable, Equatable {
    case sameDay
    case yesterday
    case earlier

    /// - Parameters:
    ///   - reading: the reading's date.
    ///   - entry: the timeline entry's date (the moment the label is on screen).
    public static func of(_ reading: Date, at entry: Date, calendar: Calendar) -> ReadingDay {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: reading), to: calendar.startOfDay(for: entry)).day ?? 0
        switch days {
        case ...0: return .sameDay
        case 1: return .yesterday
        default: return .earlier
        }
    }

    /// The local midnights at which `of(reading, at:)` changes: the first one after the reading
    /// (same day → yesterday) and the one after it (yesterday → a date). Calendar arithmetic, so a
    /// 23- or 25-hour day around a DST change is still one day.
    public static func changeDates(after reading: Date, calendar: Calendar) -> [Date] {
        let start = calendar.startOfDay(for: reading)
        return [1, 2].compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}
