// Turns readings into what a chart may draw (HANDOFF §7.5, S1, S4):
//   - numeric readings, grouped into line segments; a gap > 15 min between consecutive readings
//     starts a new segment, so the line is never drawn across missing data;
//   - LOW/HIGH flags, returned separately as marker times. A flag is never given a y value (it is
//     not 40 or 400), and it also breaks the line, because the value there is unknown.
// Charts connect points within a segment with straight lines; that is the only thing drawn
// between real readings (S1).

import Foundation
import GlucoseCore

/// A reading as a chart sees it. Also the snapshot's format for the widget's 3-hour history.
public struct ChartPoint: Sendable, Equatable, Hashable, Codable {
    public let date: Date
    public let value: GlucoseValue

    public init(date: Date, value: GlucoseValue) {
        self.date = date
        self.value = value
    }

    public init(_ reading: GlucoseReading) {
        self.init(date: reading.date, value: reading.value)
    }
}

/// A numeric reading placed on the chart.
public struct PlottedPoint: Sendable, Equatable, Hashable {
    public let date: Date
    public let mgdl: Int

    public init(date: Date, mgdl: Int) {
        self.date = date
        self.mgdl = mgdl
    }
}

public struct ChartSeries: Sendable, Equatable {
    /// Each segment is drawn as its own line. A one-point segment is drawn as a dot.
    public let segments: [[PlottedPoint]]
    /// Times of sensor LOW flags, drawn as "LOW" markers at the chart's bottom edge.
    public let lowFlags: [Date]
    /// Times of sensor HIGH flags, drawn as "HIGH" markers at the chart's top edge.
    public let highFlags: [Date]
    /// Number of places where consecutive readings are more than `maxGap` apart.
    public let gapCount: Int

    /// Line-break threshold (HANDOFF §7.5: "Gaps > 15 min break the line"). Exactly 15 min joins.
    public static let maxGap: TimeInterval = 15 * 60

    /// - Parameter points: readings in any order. Points with identical dates are kept once
    ///   (the first in input order); the store already deduplicates by sensor timestamp (S3).
    public init(points: [ChartPoint]) {
        var seenDates = Set<Date>()
        let ordered = points
            .enumerated()
            .sorted { $0.element.date == $1.element.date ? $0.offset < $1.offset : $0.element.date < $1.element.date }
            .map(\.element)
            .filter { seenDates.insert($0.date).inserted }

        var segments: [[PlottedPoint]] = []
        var current: [PlottedPoint] = []
        var lowFlags: [Date] = []
        var highFlags: [Date] = []
        var gapCount = 0
        var previousDate: Date?

        for point in ordered {
            if let previousDate, point.date.timeIntervalSince(previousDate) > Self.maxGap {
                gapCount += 1
                if !current.isEmpty { segments.append(current) }
                current = []
            }
            previousDate = point.date
            switch point.value {
            case .mgdl(let mgdl):
                current.append(PlottedPoint(date: point.date, mgdl: mgdl))
            case .belowRange:
                lowFlags.append(point.date)
                if !current.isEmpty { segments.append(current) }
                current = []
            case .aboveRange:
                highFlags.append(point.date)
                if !current.isEmpty { segments.append(current) }
                current = []
            }
        }
        if !current.isEmpty { segments.append(current) }

        self.segments = segments
        self.lowFlags = lowFlags
        self.highFlags = highFlags
        self.gapCount = gapCount
    }

    public var isEmpty: Bool { segments.isEmpty && lowFlags.isEmpty && highFlags.isEmpty }

    /// Largest plotted value, for sizing the y axis. Flags do not count (they have no value).
    public var maxPlottedMgdl: Int? { segments.joined().map(\.mgdl).max() }
    public var minPlottedMgdl: Int? { segments.joined().map(\.mgdl).min() }
}

public enum ChartSummary {
    /// VoiceOver summary for a glucose chart, e.g.
    /// "Last 3 hours: 36 readings, 82 to 120 milligrams per deciliter, latest 105. 1 LOW reading.
    ///  The line breaks at 1 gap longer than 15 minutes."
    public static func text(title: String, points: [ChartPoint]) -> String {
        let series = ChartSeries(points: points)
        let count = series.segments.joined().count + series.lowFlags.count + series.highFlags.count
        guard count > 0 else { return "\(title): no readings." }

        var parts: [String] = []
        var first = "\(title): \(count == 1 ? "1 reading" : "\(count) readings")"
        if let low = series.minPlottedMgdl, let high = series.maxPlottedMgdl {
            first += low == high
                ? ", \(low) milligrams per deciliter"
                : ", \(low) to \(high) milligrams per deciliter"
        }
        if let latest = points.max(by: { $0.date < $1.date }) {
            first += ", latest \(GlucoseText.value(latest.value))"
        }
        parts.append(first + ".")
        if !series.lowFlags.isEmpty {
            parts.append(series.lowFlags.count == 1 ? "1 LOW reading." : "\(series.lowFlags.count) LOW readings.")
        }
        if !series.highFlags.isEmpty {
            parts.append(series.highFlags.count == 1 ? "1 HIGH reading." : "\(series.highFlags.count) HIGH readings.")
        }
        if series.gapCount > 0 {
            parts.append(series.gapCount == 1
                ? "The line breaks at 1 gap longer than 15 minutes."
                : "The line breaks at \(series.gapCount) gaps longer than 15 minutes.")
        }
        return parts.joined(separator: " ")
    }
}
