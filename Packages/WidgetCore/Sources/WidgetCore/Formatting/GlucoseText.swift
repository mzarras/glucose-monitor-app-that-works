// Text for glucose values, trends, deltas and ages. Pure functions; unit-tested in
// FormattingTests. Shared by the app and the widget so both say exactly the same thing.

import Foundation
import GlucoseCore

public enum GlucoseText {
    public static let unit = "mg/dL"

    /// "105", or "LOW" / "HIGH" for the sensor flags. S4: a flag is never shown as 40 or 400.
    public static func value(_ value: GlucoseValue) -> String {
        switch value {
        case .mgdl(let mgdl): return String(mgdl)
        case .belowRange: return "LOW"
        case .aboveRange: return "HIGH"
        }
    }

    /// "105 mg/dL", or "LOW" / "HIGH" (a flag has no unit because it has no number).
    public static func valueWithUnit(_ value: GlucoseValue) -> String {
        switch value {
        case .mgdl: return "\(Self.value(value)) \(unit)"
        case .belowRange, .aboveRange: return Self.value(value)
        }
    }

    /// Caption shown under a LOW/HIGH hero in place of the unit.
    public static func flagCaption(_ value: GlucoseValue) -> String? {
        switch value {
        case .mgdl: return nil
        case .belowRange: return "below sensor range"
        case .aboveRange: return "above sensor range"
        }
    }

    /// VoiceOver: "105 milligrams per deciliter", "LOW, below the sensor's range".
    public static func spoken(_ value: GlucoseValue) -> String {
        switch value {
        case .mgdl(let mgdl): return "\(mgdl) milligrams per deciliter"
        case .belowRange: return "LOW, below the sensor's range"
        case .aboveRange: return "HIGH, above the sensor's range"
        }
    }
}

public enum TrendText {
    /// Lower-case word: "steady", "rising slowly", … Used in the state line and VoiceOver.
    public static func word(_ arrow: TrendArrow) -> String {
        switch arrow {
        case .doubleUp: return "rising fast"
        case .singleUp: return "rising"
        case .fortyFiveUp: return "rising slowly"
        case .flat: return "steady"
        case .fortyFiveDown: return "falling slowly"
        case .singleDown: return "falling"
        case .doubleDown: return "falling fast"
        case .notComputable: return "trend unavailable"
        }
    }

    /// One-character arrow for plain-text places (inline Lock Screen widget). Empty when the
    /// sensor reported no rate.
    public static func glyph(_ arrow: TrendArrow) -> String {
        switch arrow {
        case .doubleUp: return "⇈"
        case .singleUp: return "↑"
        case .fortyFiveUp: return "↗"
        case .flat: return "→"
        case .fortyFiveDown: return "↘"
        case .singleDown: return "↓"
        case .doubleDown: return "⇊"
        case .notComputable: return ""
        }
    }
}

public enum DeltaText {
    /// "−3 in 5 min", "+12 in 5 min", "±0 in 5 min". Uses U+2212 MINUS SIGN as in the mockup.
    public static func text(_ delta: GlucoseDelta) -> String {
        "\(signed(delta.mgdl)) in \(delta.minutes) min"
    }

    /// "−3", "+12", "±0".
    public static func signed(_ value: Int) -> String {
        if value > 0 { return "+\(value)" }
        if value < 0 { return "\u{2212}\(-value)" }
        return "±0"
    }

    /// VoiceOver: "down 3 in 5 minutes", "up 12 in 5 minutes", "no change in 5 minutes".
    public static func spoken(_ delta: GlucoseDelta) -> String {
        let minutes = delta.minutes == 1 ? "1 minute" : "\(delta.minutes) minutes"
        if delta.mgdl > 0 { return "up \(delta.mgdl) in \(minutes)" }
        if delta.mgdl < 0 { return "down \(-delta.mgdl) in \(minutes)" }
        return "no change in \(minutes)"
    }
}

public enum AgeText {
    /// Whole minutes from `date` to `now`, rounded down, never negative (a reading dated a few
    /// seconds ahead of the phone clock reads as "just now", not as a negative age).
    public static func wholeMinutes(from date: Date, to now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(date) / 60))
    }

    /// "just now", "3 min ago", "1 h 5 min ago", "2 d ago".
    public static func long(minutes: Int) -> String {
        if minutes < 1 { return "just now" }
        return compact(minutes: minutes) + " ago"
    }

    /// "JUST NOW", "3 MIN AGO", … for mono labels.
    public static func upper(minutes: Int) -> String {
        long(minutes: minutes).uppercased()
    }

    /// "now", "3m", "1h 5m", "2d" for the inline Lock Screen widget.
    public static func short(minutes: Int) -> String {
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 {
            let rest = minutes % 60
            return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(rest)m"
        }
        return "\(minutes / (24 * 60))d"
    }

    /// VoiceOver: "just now", "1 minute ago", "3 minutes ago", "1 hour 5 minutes ago".
    public static func spoken(minutes: Int) -> String {
        if minutes < 1 { return "just now" }
        if minutes < 60 { return plural(minutes, "minute") + " ago" }
        if minutes < 24 * 60 {
            let hours = plural(minutes / 60, "hour")
            let rest = minutes % 60
            return (rest == 0 ? hours : hours + " " + plural(rest, "minute")) + " ago"
        }
        return plural(minutes / (24 * 60), "day") + " ago"
    }

    private static func compact(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 24 * 60 {
            let rest = minutes % 60
            return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
        }
        return "\(minutes / (24 * 60)) d"
    }

    private static func plural(_ count: Int, _ unit: String) -> String {
        count == 1 ? "1 \(unit)" : "\(count) \(unit)s"
    }
}

public enum BandText {
    /// Upper-case range word for the state line. A LOW/HIGH flag says so explicitly rather than
    /// reusing the "LOW"/"HIGH" band words, so a flag is never confused with 54–69 or 181–250.
    public static func upper(_ value: GlucoseValue) -> String {
        switch value {
        case .belowRange: return "BELOW SENSOR RANGE"
        case .aboveRange: return "ABOVE SENSOR RANGE"
        case .mgdl:
            switch value.band {
            case .veryLow: return "VERY LOW"
            case .low: return "LOW"
            case .inRange: return "IN RANGE"
            case .high: return "HIGH"
            case .veryHigh: return "VERY HIGH"
            }
        }
    }
}

public enum HeroSpeech {
    /// VoiceOver label for the hero reading (HANDOFF §7.5):
    /// "105 milligrams per deciliter, steady, 3 minutes ago".
    public static func label(for reading: LatestReading, now: Date) -> String {
        let minutes = AgeText.wholeMinutes(from: reading.date, to: now)
        return [
            GlucoseText.spoken(reading.value),
            TrendText.word(reading.trend),
            AgeText.spoken(minutes: minutes),
        ].joined(separator: ", ")
    }
}
