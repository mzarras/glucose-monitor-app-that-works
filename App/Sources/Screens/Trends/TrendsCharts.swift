// Trends charts: the AGP percentile chart (≥ 7 D) and the daily overlay of real readings
// (1 D / 3 D). X is hour of day (0–24) so days line up.

import Charts
import GlucoseCore
import SwiftUI
import WidgetCore

enum TimeOfDayAxis {
    static let hourMarks = [0, 6, 12, 18, 24]

    /// Hours since local midnight of `dayStart`, e.g. 13.5 for 1:30 PM. A DST day is 23 or 25 hours
    /// long; points keep their real offset from midnight, so the last hour may extend past 24 or
    /// stop at 23 on those days.
    static func hourOfDay(_ date: Date, dayStart: Date) -> Double {
        date.timeIntervalSince(dayStart) / 3_600
    }

    @AxisContentBuilder
    static var xAxis: some AxisContent {
        AxisMarks(values: hourMarks) { value in
            AxisValueLabel {
                if let hour = value.as(Int.self) {
                    Text(verbatim: HourLabel.text(hourOfDay: hour))
                        .font(Typography.fixedLabel(size: 10))
                        .foregroundStyle(Theme.muted)
                        .fixedSize()
                }
            }
        }
    }

    @AxisContentBuilder
    static var yAxis: some AxisContent {
        AxisMarks(position: .leading, values: [GlucoseThresholds.lowBelow, GlucoseThresholds.inRangeUpperBound]) { value in
            AxisValueLabel {
                if let mgdl = value.as(Int.self) {
                    Text(verbatim: String(mgdl))
                        .font(Typography.fixedLabel(size: 10))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }
}

/// Ambulatory glucose profile: 25–75 band filled in the accent, 5th and 95th as dashed lines,
/// median solid. Statistics from GlucoseStats, not readings; buckets more than an hour apart are
/// not joined. A percentile that is the sensor's LOW/HIGH flag is drawn at the chart's floor/
/// ceiling (`AGPLineValue.chartY`), never as a number (S4).
struct AGPChart: View {
    let buckets: [AGPBucket]

    var body: some View {
        let segments = AGPSegmentation.segments(buckets)
        let upper = AGPChartScale.upperBound(buckets)
        let floor = Double(ChartScale.yLowerBound)
        let ceiling = Double(upper)
        func y(_ value: AGPLineValue) -> Double { value.chartY(floor: floor, ceiling: ceiling) }
        return Chart {
            RectangleMark(xStart: .value("Start", 0), xEnd: .value("End", 24), yStart: .value("Low", 70), yEnd: .value("High", 180))
                .foregroundStyle(Theme.rangeBand)
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                ForEach(segment, id: \.minuteOfDay) { bucket in
                    AreaMark(
                        x: .value("Hour", Double(bucket.minuteOfDay) / 60),
                        yStart: .value("25th", y(bucket.p25)),
                        yEnd: .value("75th", y(bucket.p75)),
                        series: .value("Band", "iqr-\(index)")
                    )
                    .foregroundStyle(Theme.accent.opacity(0.22))
                }
                ForEach(segment, id: \.minuteOfDay) { bucket in
                    LineMark(x: .value("Hour", Double(bucket.minuteOfDay) / 60), y: .value("5th", y(bucket.p5)), series: .value("Line", "p5-\(index)"))
                        .foregroundStyle(Theme.muted)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                ForEach(segment, id: \.minuteOfDay) { bucket in
                    LineMark(x: .value("Hour", Double(bucket.minuteOfDay) / 60), y: .value("95th", y(bucket.p95)), series: .value("Line", "p95-\(index)"))
                        .foregroundStyle(Theme.muted)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                ForEach(segment, id: \.minuteOfDay) { bucket in
                    LineMark(x: .value("Hour", Double(bucket.minuteOfDay) / 60), y: .value("Median", y(bucket.p50)), series: .value("Line", "p50-\(index)"))
                        .foregroundStyle(Theme.ink)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
            }
        }
        .chartXScale(domain: 0...24)
        .chartYScale(domain: ChartScale.yLowerBound...upper)
        .chartXAxis { TimeOfDayAxis.xAxis }
        .chartYAxis { TimeOfDayAxis.yAxis }
        .chartPlotStyle { $0.overlay(alignment: .bottom) { Rectangle().fill(Theme.ink).frame(height: 1) } }
        .chartOverlay { proxy in
            // A percentile that is the sensor's HIGH/LOW flag is drawn at the top/bottom edge; a
            // "HIGH"/"LOW" label at the start of each run says so, so the edge never reads as a value
            // (S4, Phase 2 review nit).
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let plot = geometry[anchor]
                    ForEach(AGPFlagMarkers.runs(buckets)) { marker in
                        if let x = proxy.position(forX: Double(marker.minuteOfDay) / 60) {
                            Text(verbatim: marker.isHigh ? "HIGH" : "LOW")
                                .font(Typography.fixedLabel(size: 8, medium: true))
                                .foregroundStyle(Theme.band(marker.isHigh ? .veryHigh : .veryLow))
                                .fixedSize()
                                .position(x: min(max(plot.minX + x, plot.minX + 14), plot.maxX - 14),
                                          y: marker.isHigh ? plot.minY + 7 : plot.maxY - 8)
                        }
                    }
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: TrendsText.agpSpeech(buckets)))
    }
}

/// Where the AGP chart labels a flag (S4): the first bucket of each run of buckets whose 95th
/// percentile is HIGH, or whose 5th is LOW. Runs break where buckets are more than an hour apart
/// (the lines break there too, `AGPSegmentation`).
enum AGPFlagMarkers {
    struct Marker: Equatable, Identifiable, Sendable {
        let minuteOfDay: Int
        let isHigh: Bool
        var id: String { "\(isHigh ? "H" : "L")\(minuteOfDay)" }
    }

    static func runs(_ buckets: [AGPBucket]) -> [Marker] {
        var markers: [Marker] = []
        for segment in AGPSegmentation.segments(buckets) {
            var previousHigh = false
            var previousLow = false
            for bucket in segment {
                let high = bucket.p95 == .aboveRange
                let low = bucket.p5 == .belowRange
                if high && !previousHigh { markers.append(Marker(minuteOfDay: bucket.minuteOfDay, isHigh: true)) }
                if low && !previousLow { markers.append(Marker(minuteOfDay: bucket.minuteOfDay, isHigh: false)) }
                previousHigh = high
                previousLow = low
            }
        }
        return markers
    }
}

/// The AGP chart's y-axis top (review m1, S4): as for every glucose chart, unless a percentile is
/// the sensor's HIGH flag — then 400, the sensor's top, so the HIGH line sits above every number
/// instead of at a ceiling such as 250 that would read as a value of 250.
enum AGPChartScale {
    static let highFlagCeiling = 400

    static func upperBound(_ buckets: [AGPBucket]) -> Int {
        let lines = buckets.flatMap { [$0.p5, $0.p25, $0.p50, $0.p75, $0.p95] }
        if lines.contains(.aboveRange) { return highFlagCeiling }
        return ChartScale.yUpperBound(maxPlotted: lines.compactMap(\.mgdl).max().map { Int($0.rounded(.up)) })
    }
}

/// 1 D: today's readings. 3 D: each day's readings overlaid by time of day, today emphasised and
/// the earlier days lighter (HANDOFF §7.3.2). Real readings only; the same segmentation as every
/// other chart (gaps > 15 min break the line, LOW/HIGH are edge markers, S1/S4).
///
/// Scrubbing (press-and-hold, then drag) selects today's nearest real reading (ChartScrub); the
/// callout also lists the other days' readings at the same time of day, or "no data".
struct DayOverlayChart: View {
    let days: [DayTrace]
    @State private var scrubHour: Double?
    @State private var accessibilityReading: ChartPoint?

    /// - Parameter initialScrubHour: previews and screenshots only — start with the finger here.
    init(days: [DayTrace], initialScrubHour: Double? = nil) {
        self.days = days
        _scrubHour = State(initialValue: initialScrubHour)
    }

    private struct Line: Identifiable {
        let id: String
        let isToday: Bool
        let points: [PlottedPoint]
        let dayStart: Date
    }

    private struct Flag: Identifiable {
        let id: String
        let hour: Double
        let isLow: Bool
        let isToday: Bool
        /// First reading of a run of flags: carries the "LOW"/"HIGH" label; the rest get a tick only.
        let isRunStart: Bool
    }

    /// The trace the scrub highlight and haptics follow: today, or the newest day.
    private var primary: DayTrace? {
        days.first(where: \.isToday) ?? days.max { $0.dayStart < $1.dayStart }
    }

    private func selection(for day: DayTrace) -> ScrubSelection {
        guard let scrubHour else { return .none }
        return ChartScrub.select(at: day.dayStart.addingTimeInterval(scrubHour * 3_600), in: day.points)
    }

    var body: some View {
        let ordered = days.sorted { $0.isToday == $1.isToday ? $0.dayStart < $1.dayStart : !$0.isToday }
        var lines: [Line] = []
        var flags: [Flag] = []
        for day in ordered {
            let series = ChartSeries(points: day.points)
            for (index, segment) in series.segments.enumerated() {
                lines.append(Line(id: "\(day.dayStart.timeIntervalSince1970)-\(index)", isToday: day.isToday, points: segment, dayStart: day.dayStart))
            }
            for run in series.lowFlagRuns {
                for (index, date) in run.enumerated() {
                    flags.append(Flag(id: "L\(date.timeIntervalSince1970)", hour: TimeOfDayAxis.hourOfDay(date, dayStart: day.dayStart), isLow: true, isToday: day.isToday, isRunStart: index == 0))
                }
            }
            for run in series.highFlagRuns {
                for (index, date) in run.enumerated() {
                    flags.append(Flag(id: "H\(date.timeIntervalSince1970)", hour: TimeOfDayAxis.hourOfDay(date, dayStart: day.dayStart), isLow: false, isToday: day.isToday, isRunStart: index == 0))
                }
            }
        }
        let maxValue = lines.flatMap(\.points).map(\.mgdl).max()
        let upper = ChartScale.yUpperBound(maxPlotted: maxValue)
        let primarySelection = primary.map(selection(for:)) ?? .none

        return Chart {
            RectangleMark(xStart: .value("Start", 0), xEnd: .value("End", 24), yStart: .value("Low", 70), yEnd: .value("High", 180))
                .foregroundStyle(Theme.rangeBand)
            ForEach(lines) { line in
                if line.points.count == 1, let only = line.points.first {
                    PointMark(x: .value("Hour", TimeOfDayAxis.hourOfDay(only.date, dayStart: line.dayStart)), y: .value("mg/dL", only.mgdl))
                        .symbolSize(20)
                        .foregroundStyle(line.isToday ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.muted))
                } else {
                    ForEach(line.points, id: \.date) { point in
                        LineMark(
                            x: .value("Hour", TimeOfDayAxis.hourOfDay(point.date, dayStart: line.dayStart)),
                            y: .value("mg/dL", point.mgdl),
                            series: .value("Segment", line.id)
                        )
                        // Earlier days: the muted token, thinner (≥ 3:1 on the band; review m7).
                        .foregroundStyle(line.isToday ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.muted))
                        .lineStyle(StrokeStyle(lineWidth: line.isToday ? 2 : 1, lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
        .chartXScale(domain: 0...24)
        .chartYScale(domain: ChartScale.yLowerBound...upper)
        .chartXAxis { TimeOfDayAxis.xAxis }
        .chartYAxis { TimeOfDayAxis.yAxis }
        .chartPlotStyle { $0.overlay(alignment: .bottom) { Rectangle().fill(Theme.ink).frame(height: 1) } }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let plot = geometry[anchor]
                    ZStack(alignment: .topLeading) {
                        ForEach(flags) { flag in
                            if let x = proxy.position(forX: flag.hour) {
                                Rectangle()
                                    .fill(Theme.band(flag.isLow ? .veryLow : .veryHigh))
                                    .frame(width: 2, height: 6)
                                    .opacity(flag.isToday ? 1 : Emphasis.otherDayFlagTickOpacity)
                                    .position(x: plot.minX + x, y: flag.isLow ? plot.maxY - 3 : plot.minY + 3)
                                if flag.isRunStart {
                                    // Full opacity for every day: text must keep 4.5:1 (review m7).
                                    Text(verbatim: flag.isLow ? "LOW" : "HIGH")
                                        .font(Typography.fixedLabel(size: 8, medium: true))
                                        .foregroundStyle(Theme.band(flag.isLow ? .veryLow : .veryHigh))
                                        .fixedSize()
                                        .position(x: min(max(plot.minX + x, plot.minX + 12), plot.maxX - 12), y: flag.isLow ? plot.maxY - 14 : plot.minY + 14)
                                }
                            }
                        }
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .scrubGesture(
                                onChange: { location in
                                    scrubHour = proxy.value(atX: location.x - plot.minX, as: Double.self).map { min(max($0, 0), 24) }
                                },
                                onEnd: { scrubHour = nil }
                            )
                        scrubMarks(proxy: proxy, plot: plot, selection: primarySelection)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .scrubHaptics(primarySelection)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: summary))
        .accessibilityValue(Text(verbatim: accessibilityReading.flatMap { ChartScrub.callout(.reading($0), time: { TimeText.time($0) })?.spoken } ?? ""))
        .accessibilityHint(Text("Swipe up or down to move through today's readings."))
        .accessibilityAdjustableAction { direction in
            guard let primary else { return }
            let forward = direction == .increment
            accessibilityReading = ChartScrub.step(from: accessibilityReading, forward: forward, in: primary.points) ?? accessibilityReading
        }
        .accessibilityChartDescriptor(GlucoseChartDescriptor(
            title: primary?.isToday == true ? "Today" : "Readings",
            summary: summary,
            points: primary.map { Array(ChartSeries(points: $0.points).segments.joined()) } ?? [],
            domain: (primary?.dayStart ?? Date())...(primary?.dayStart ?? Date()).addingTimeInterval(86_400)
        ))
    }

    @ViewBuilder
    private func scrubMarks(proxy: ChartProxy, plot: CGRect, selection: ScrubSelection) -> some View {
        if let primary, let scrubHour, let callout = ChartScrub.callout(selection, time: { TimeText.time($0) }) {
            let hour: Double = selection.reading.map { TimeOfDayAxis.hourOfDay($0.date, dayStart: primary.dayStart) } ?? scrubHour
            if let x = proxy.position(forX: hour) {
                Rectangle()
                    .fill(selection.reading == nil ? AnyShapeStyle(Theme.muted) : AnyShapeStyle(Theme.ink))
                    .frame(width: 1, height: plot.height)
                    .position(x: plot.minX + x, y: plot.midY)
                let pointY: CGFloat? = selection.reading?.value.numericMgdl.flatMap { proxy.position(forY: $0) }.map { plot.minY + $0 }
                if let pointY {
                    Circle()
                        .fill(Theme.background)
                        .overlay(Circle().stroke(Theme.ink, lineWidth: 2))
                        .frame(width: 11, height: 11)
                        .position(x: plot.minX + x, y: pointY)
                }
                PlacedScrubCallout(callout: callout, extraLines: otherDaysLines(primary: primary), x: plot.minX + x, plot: plot)
            }
        }
    }

    /// "SEP 22 · 98", "SEP 21 · LOW", "SEP 20 · no data" — the other days at the same time of day.
    private func otherDaysLines(primary: DayTrace) -> [String] {
        days.filter { $0.dayStart != primary.dayStart }
            .sorted { $0.dayStart > $1.dayStart }
            .map { day in
                let label = TimeText.shortDay(day.dayStart).uppercased()
                switch selection(for: day) {
                case .reading(let point): return "\(label) · \(GlucoseText.value(point.value))"
                case .gap, .none: return "\(label) · no data"
                }
            }
    }

    private var summary: String {
        days.sorted { $0.dayStart > $1.dayStart }.map { day in
            ChartSummary.text(title: day.isToday ? "Today" : TimeText.shortDay(day.dayStart), points: day.points)
        }.joined(separator: " ")
    }
}
