// Pure text for the Trends screen. Unit-tested in TrendsFormattingTests.

import Foundation
import GlucoseCore

enum TrendsText {
    /// Minimum period for GMI (HANDOFF §7.3.2).
    static let gmiMinimumDays = 14
    /// Below this coverage the data-sufficiency warning shows (HANDOFF §6, AGP standard).
    static let sufficiencyWarningBelow: Double = 70

    /// Screen title: "Fourteen days".
    static func title(_ period: TrendsPeriod) -> String {
        switch period {
        case .oneDay: return "Today"
        case .threeDays: return "Three days"
        case .sevenDays: return "Seven days"
        case .fourteenDays: return "Fourteen days"
        case .thirtyDays: return "Thirty days"
        case .ninetyDays: return "Ninety days"
        }
    }

    /// "SEP 10 – SEP 23" (or "SEP 23" for a single day).
    static func dateRange(_ interval: DateInterval?, context: DisplayContext = .current) -> String {
        guard let interval else { return "NO DATA" }
        let start = TimeText.shortDay(interval.start, context).uppercased()
        // The end is exclusive or "now"; label the last day covered.
        let end = TimeText.shortDay(interval.end.addingTimeInterval(-1), context).uppercased()
        return start == end ? start : "\(start) – \(end)"
    }

    /// "vs yesterday", "vs prior 3 days", "vs prior 14d".
    static func comparison(_ period: TrendsPeriod) -> String {
        switch period {
        case .oneDay: return "vs yesterday"
        case .threeDays: return "vs prior 3 days"
        default: return "vs prior \(period.days)d"
        }
    }

    /// VoiceOver form of `comparison`: "compared with yesterday", "compared with the prior 14 days".
    static func spokenComparison(_ period: TrendsPeriod) -> String {
        period == .oneDay ? "compared with yesterday" : "compared with the prior \(period.days) days"
    }

    /// "+4 pts vs prior 14d", or "no prior data" when there is nothing to compare with.
    static func change(_ points: Double?, period: TrendsPeriod) -> String {
        guard let points else { return "no prior data to compare" }
        let rounded = Int(points.rounded())
        let signed: String
        if rounded > 0 { signed = "+\(rounded)" } else if rounded < 0 { signed = "\u{2212}\(-rounded)" } else { signed = "±0" }
        return "\(signed) pts \(comparison(period))"
    }

    /// "78%" or "—".
    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    /// Range-bar label percentages: "<1%" for a non-zero bin that rounds to 0, so a real low never
    /// reads as none.
    static func binPercent(_ value: Double) -> String {
        if value > 0 && value < 0.5 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }

    static func mgdl(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))"
    }

    /// GMI only for 14 D and longer; below that "needs 14 days" (HANDOFF §7.3.2).
    static func gmi(_ value: Double?, period: TrendsPeriod) -> String {
        guard period.days >= gmiMinimumDays else { return "needs \(gmiMinimumDays) days" }
        guard let value else { return "—" }
        return String(format: "%.1f%%", value)
    }

    /// "11h 20m".
    static func streak(_ interval: TimeInterval?) -> String {
        guard let interval else { return "—" }
        return TimeText.duration(interval)
    }

    /// "4 of 6 between 2–5 AM".
    static func lowsNote(_ lows: LowsSummary) -> String? {
        guard lows.count > 0, let window = lows.peakWindow else { return nil }
        return "\(window.count) of \(lows.count) between \(hourRange(window.startHour, window.endHour))"
    }

    /// "avg 32m".
    static func lowsDuration(_ lows: LowsSummary) -> String? {
        guard lows.count > 0, let minutes = lows.meanDurationMinutes else { return nil }
        return "avg \(TimeText.duration(TimeInterval(minutes * 60)))"
    }

    /// "2–5 AM", "10 PM–1 AM", "11 AM–2 PM".
    static func hourRange(_ start: Int, _ end: Int) -> String {
        func hour(_ h: Int) -> (Int, String) {
            let h24 = ((h % 24) + 24) % 24
            return (h24 % 12 == 0 ? 12 : h24 % 12, h24 < 12 ? "AM" : "PM")
        }
        let (s, sp) = hour(start)
        let (e, ep) = hour(end)
        return sp == ep ? "\(s)–\(e) \(ep)" : "\(s) \(sp)–\(e) \(ep)"
    }

    /// Warning under 70 % coverage (HANDOFF §6), on every period.
    static func sufficiencyWarning(_ coverage: Double) -> String? {
        guard coverage < sufficiencyWarningBelow else { return nil }
        return "Only \(Int(coverage.rounded()))% of expected readings in this period. Patterns and statistics may not be reliable."
    }

    /// Footnote for periods that include imported history (HANDOFF §4.5 step 4).
    static func importedFootnote(_ note: ImportedDataNote?, context: DisplayContext = .current) -> String? {
        guard let note else { return nil }
        let names = note.origins.map { origin -> String in
            switch origin {
            case .nightscout: return "Nightscout"
            case .clarityCSV: return "a Clarity export"
            }
        }
        let sources = names.count == 2 ? "\(names[0]) and \(names[1])" : names.joined(separator: ", ")
        let start = TimeText.shortDay(note.interval.start, context)
        let end = TimeText.shortDay(note.interval.end.addingTimeInterval(-1), context)
        let span = start == end ? start : "\(start) – \(end)"
        return "Includes history imported from \(sources) (\(span)). Imported readings are used for charts and statistics only."
    }

    /// VoiceOver for the hero: "78 percent time in range, 70 to 180, up 4 points vs prior 14 days".
    static func heroSpeech(_ state: TrendsViewState) -> String {
        guard let tir = state.timeInRange else { return "Time in range: no readings in this period" }
        var text = "\(Int(tir.rounded())) percent time in range, 70 to 180 milligrams per deciliter"
        if let change = state.timeInRangeChange {
            let rounded = Int(change.rounded())
            let direction = rounded > 0 ? "up \(rounded) points" : rounded < 0 ? "down \(-rounded) points" : "no change"
            text += ", \(direction) \(spokenComparison(state.period))"
        }
        return text
    }

    /// VoiceOver for the range bar.
    static func binsSpeech(_ bins: RangeBins) -> String {
        "Below 54: \(binPercent(bins.veryLow)). 54 to 69: \(binPercent(bins.low)). 70 to 180: \(binPercent(bins.inRange)). 181 to 250: \(binPercent(bins.high)). Above 250: \(binPercent(bins.veryHigh))."
    }

    /// VoiceOver summary for the AGP chart.
    static func agpSpeech(_ buckets: [AGPBucket]) -> String {
        guard let low = buckets.min(by: { $0.p50 < $1.p50 }), let high = buckets.max(by: { $0.p50 < $1.p50 }) else {
            return "A typical day: not enough data."
        }
        return "A typical day: the median ranges from \(Int(low.p50.rounded())) at \(HourLabelText.spoken(minuteOfDay: low.minuteOfDay)) to \(Int(high.p50.rounded())) at \(HourLabelText.spoken(minuteOfDay: high.minuteOfDay)) milligrams per deciliter."
    }
}

enum HourLabelText {
    /// "2:15 AM" for VoiceOver.
    static func spoken(minuteOfDay: Int) -> String {
        let hour = (minuteOfDay / 60) % 24
        let minute = minuteOfDay % 60
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        let suffix = hour < 12 ? "AM" : "PM"
        return minute == 0 ? "\(twelve) \(suffix)" : String(format: "%d:%02d %@", twelve, minute, suffix)
    }
}
