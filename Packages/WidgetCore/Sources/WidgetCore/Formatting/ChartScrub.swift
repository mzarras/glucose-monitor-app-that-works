// What a finger (or VoiceOver's adjustable action) selects on a glucose chart. Pure; unit-tested
// in ChartScrubTests.
//
// S1: the selection is always one real reading, snapped by time — never a value between points.
//     Inside a gap longer than 15 minutes (the same limit that breaks the line) the selection is
//     the gap itself: "No data" with its time span, no point, no haptic tick.
// S4: a LOW/HIGH flag is selected as the flag and shown as "LOW"/"HIGH", never as 40/400.

import Foundation
import GlucoseCore

public enum ScrubSelection: Sendable, Equatable {
    /// A real reading, exactly as stored.
    case reading(ChartPoint)
    /// The finger is inside a gap: readings at `from` and `to`, nothing in between.
    case gap(from: Date, to: Date)
    /// Nothing selectable (no readings, or the finger is beyond the data).
    case none

    public var reading: ChartPoint? {
        if case .reading(let point) = self { return point }
        return nil
    }
}

/// Which haptic, if any, a selection change plays.
public enum ScrubFeedback: Sendable, Equatable {
    /// A different reading, same range band: light selection tick.
    case selection
    /// A different reading in a different range band (e.g. in range → low): slightly stronger tick.
    case bandChange
}

/// Text for the callout above the scrub rule.
public struct ScrubCallout: Sendable, Equatable {
    /// "105", "LOW", "HIGH", or "No data".
    public let headline: String
    /// "mg/dL", "below sensor range", "above sensor range", or the gap's span "1:05 PM – 1:50 PM".
    public let detail: String
    /// The reading's time; nil for a gap (its span is in `detail`).
    public let time: String?
    /// VoiceOver: "105 milligrams per deciliter at 2:15 PM", "No data from 1:05 PM to 1:50 PM".
    public let spoken: String
}

public enum ChartScrub {
    /// A finger this close (in time) to a reading at the edge of a gap still selects it: half of
    /// the G7's 5-minute cadence.
    public static let snapTolerance: TimeInterval = 150

    /// Readings sorted by date, one per date — the same order and dedupe as `ChartSeries`.
    public static func ordered(_ points: [ChartPoint]) -> [ChartPoint] {
        var seen = Set<Date>()
        return points
            .enumerated()
            .sorted { $0.element.date == $1.element.date ? $0.offset < $1.offset : $0.element.date < $1.element.date }
            .map(\.element)
            .filter { seen.insert($0.date).inserted }
    }

    /// The selection for the time under the finger.
    public static func select(at date: Date, in points: [ChartPoint]) -> ScrubSelection {
        let sorted = ordered(points)
        guard !sorted.isEmpty else { return .none }
        // First reading at or after `date`.
        let nextIndex = sorted.firstIndex { $0.date >= date }
        let next = nextIndex.map { sorted[$0] }
        let previous: ChartPoint? = {
            let upper = nextIndex ?? sorted.count
            return upper > 0 ? sorted[upper - 1] : nil
        }()

        switch (previous, next) {
        case (nil, let next?):
            // Before the first reading.
            return next.date.timeIntervalSince(date) <= snapTolerance ? .reading(next) : .none
        case (let previous?, nil):
            // After the last reading.
            return date.timeIntervalSince(previous.date) <= snapTolerance ? .reading(previous) : .none
        case (let previous?, let next?):
            if next.date == date { return .reading(next) }
            let toPrevious = date.timeIntervalSince(previous.date)
            let toNext = next.date.timeIntervalSince(date)
            let nearest = toPrevious <= toNext ? previous : next
            if next.date.timeIntervalSince(previous.date) > ChartSeries.maxGap && min(toPrevious, toNext) > snapTolerance {
                return .gap(from: previous.date, to: next.date)
            }
            return .reading(nearest)
        case (nil, nil):
            return .none
        }
    }

    /// Haptic for a change of selection: only when a *different real reading* is selected.
    /// Entering a gap, leaving the data, or re-selecting the same reading plays nothing.
    public static func feedback(from old: ScrubSelection, to new: ScrubSelection) -> ScrubFeedback? {
        guard let newReading = new.reading, newReading != old.reading else { return nil }
        if let oldReading = old.reading, oldReading.value.band != newReading.value.band {
            return .bandChange
        }
        return .selection
    }

    /// Next/previous real reading for VoiceOver's adjustable action. Starts at the latest reading
    /// when nothing is selected. Returns nil at either end.
    public static func step(from current: ChartPoint?, forward: Bool, in points: [ChartPoint]) -> ChartPoint? {
        let sorted = ordered(points)
        guard let current, let index = sorted.firstIndex(where: { $0.date == current.date }) else {
            return sorted.last
        }
        let target = forward ? index + 1 : index - 1
        return sorted.indices.contains(target) ? sorted[target] : nil
    }

    /// Callout text. `time` formats a clock time (the app passes its locale-aware formatter).
    public static func callout(_ selection: ScrubSelection, time: (Date) -> String) -> ScrubCallout? {
        switch selection {
        case .none:
            return nil
        case .gap(let from, let to):
            return ScrubCallout(
                headline: "No data",
                detail: "\(time(from)) – \(time(to))",
                time: nil,
                spoken: "No data from \(time(from)) to \(time(to))"
            )
        case .reading(let point):
            return ScrubCallout(
                headline: GlucoseText.value(point.value),
                detail: GlucoseText.flagCaption(point.value) ?? GlucoseText.unit,
                time: time(point.date),
                spoken: "\(GlucoseText.spoken(point.value)) at \(time(point.date))"
            )
        }
    }

    /// Default clock-time formatter ("2:15 PM" / "14:15").
    public static func shortTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
