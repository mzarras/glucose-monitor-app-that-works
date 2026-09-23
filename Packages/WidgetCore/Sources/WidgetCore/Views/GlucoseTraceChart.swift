// The glucose line chart: Now screen (with axes), 1 D Trends trace, medium widget, and the Lock
// Screen sparkline. Draws only what `ChartSeries` returns (HANDOFF §7.5):
//   - real readings, joined by straight lines within a segment, never across a > 15 min gap (S1);
//   - LOW/HIGH flags as text markers at the bottom/top edge, never at 40/400 (S4);
//   - optional fingerstick markers, separate from the line (S1);
//   - the 70–180 target band.
// No forecast (HANDOFF §1.1, §7.5).

import Charts
import GlucoseCore
import SwiftUI

public struct GlucoseTraceChart: View {
    public struct Options: Sendable {
        public var showsAxes: Bool
        public var showsBand: Bool
        public var showsLatestDot: Bool
        public var lineWidth: CGFloat
        /// Hours between x-axis labels.
        public var hourStride: Int
        public var flagFontSize: CGFloat

        public init(showsAxes: Bool, showsBand: Bool = true, showsLatestDot: Bool = true, lineWidth: CGFloat = 2, hourStride: Int = 1, flagFontSize: CGFloat = 9) {
            self.showsAxes = showsAxes
            self.showsBand = showsBand
            self.showsLatestDot = showsLatestDot
            self.lineWidth = lineWidth
            self.hourStride = hourStride
            self.flagFontSize = flagFontSize
        }

        public static let nowScreen = Options(showsAxes: true)
        public static let widget = Options(showsAxes: false, lineWidth: 1.5, flagFontSize: 8)
        public static let sparkline = Options(showsAxes: false, showsBand: false, showsLatestDot: false, lineWidth: 1.5, flagFontSize: 7)
    }

    let points: [ChartPoint]
    let domain: ClosedRange<Date>
    let fingersticks: [FingerstickMarker]
    let options: Options
    let accessibilityTitle: String

    /// - Parameters:
    ///   - points: readings; those outside `domain` are ignored.
    ///   - domain: the time span shown, e.g. the last 3 hours ending now.
    ///   - accessibilityTitle: first words of the VoiceOver summary, e.g. "Last 3 hours".
    public init(points: [ChartPoint], domain: ClosedRange<Date>, fingersticks: [FingerstickMarker] = [], options: Options, accessibilityTitle: String) {
        self.points = points.filter { domain.contains($0.date) }
        self.domain = domain
        self.fingersticks = fingersticks.filter { domain.contains($0.date) }
        self.options = options
        self.accessibilityTitle = accessibilityTitle
    }

    public var body: some View {
        let series = ChartSeries(points: points)
        let upper = ChartScale.yUpperBound(maxPlotted: max(series.maxPlottedMgdl ?? 0, fingersticks.map(\.mgdl).max() ?? 0))
        chart(series: series, upper: upper)
            .chartXScale(domain: domain)
            .chartYScale(domain: ChartScale.yLowerBound...upper)
            .chartOverlay { proxy in flagOverlay(proxy: proxy, series: series) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        var text = ChartSummary.text(title: accessibilityTitle, points: points)
        if !fingersticks.isEmpty {
            text += fingersticks.count == 1 ? " 1 fingerstick marked." : " \(fingersticks.count) fingersticks marked."
        }
        return text
    }

    /// The newest reading in view, if it is numeric (a newest LOW/HIGH shows as a flag instead).
    private var latestPlotted: PlottedPoint? {
        guard let latest = points.max(by: { $0.date < $1.date }), let mgdl = latest.value.numericMgdl else { return nil }
        return PlottedPoint(date: latest.date, mgdl: mgdl)
    }

    @ChartContentBuilder
    private func marks(series: ChartSeries) -> some ChartContent {
        if options.showsBand {
            RectangleMark(
                xStart: .value("Start", domain.lowerBound),
                xEnd: .value("End", domain.upperBound),
                yStart: .value("Target low", GlucoseThresholds.lowBelow),
                yEnd: .value("Target high", GlucoseThresholds.inRangeUpperBound)
            )
            .foregroundStyle(Theme.rangeBand)
        }
        ForEach(Array(series.segments.enumerated()), id: \.offset) { index, segment in
            if segment.count == 1, let only = segment.first {
                PointMark(x: .value("Time", only.date), y: .value("mg/dL", only.mgdl))
                    .symbolSize(options.lineWidth * 12)
                    .foregroundStyle(Theme.ink)
            } else {
                ForEach(segment, id: \.date) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("mg/dL", point.mgdl),
                        series: .value("Segment", index)
                    )
                    .foregroundStyle(Theme.ink)
                    .lineStyle(StrokeStyle(lineWidth: options.lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
        }
        ForEach(fingersticks, id: \.self) { marker in
            PointMark(x: .value("Time", marker.date), y: .value("Fingerstick", marker.mgdl))
                .symbol {
                    FingerstickSymbol()
                        .stroke(style: StrokeStyle(lineWidth: 1.5))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 10, height: 10)
                }
        }
        if options.showsLatestDot, let latest = latestPlotted {
            PointMark(x: .value("Time", latest.date), y: .value("mg/dL", latest.mgdl))
                .symbol {
                    Circle()
                        .fill(Theme.accent)
                        .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                        .frame(width: 11, height: 11)
                }
        }
    }

    @ViewBuilder
    private func chart(series: ChartSeries, upper: Int) -> some View {
        let base = Chart { marks(series: series) }
            .chartPlotStyle { plot in
                plot.overlay(alignment: .bottom) {
                    if options.showsAxes { Rectangle().fill(Theme.ink).frame(height: 1) }
                }
                .overlay(alignment: .top) {
                    if options.showsAxes { Rectangle().fill(Theme.rule).frame(height: 1) }
                }
            }
        if options.showsAxes {
            base
                .chartYAxis {
                    AxisMarks(position: .leading, values: ChartScale.yAxisLabels(upperBound: upper)) { value in
                        AxisValueLabel {
                            if let mgdl = value.as(Int.self) {
                                Text(verbatim: String(mgdl))
                                    .font(Typography.fixedLabel(size: 10))
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: options.hourStride)) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(verbatim: HourLabel.text(date))
                                    .font(Typography.fixedLabel(size: 10))
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
        } else {
            base
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
        }
    }

    /// LOW markers along the bottom edge and HIGH markers along the top edge of the plot area.
    /// Only the x position comes from the chart; the y position is the edge (S4).
    private func flagOverlay(proxy: ChartProxy, series: ChartSeries) -> some View {
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame {
                let plot = geometry[anchor]
                ForEach(series.lowFlags, id: \.self) { date in
                    if let x = proxy.position(forX: date) {
                        FlagMarker(text: "LOW", band: .veryLow, fontSize: options.flagFontSize)
                            .position(x: plot.minX + x, y: plot.maxY - options.flagFontSize)
                    }
                }
                ForEach(series.highFlags, id: \.self) { date in
                    if let x = proxy.position(forX: date) {
                        FlagMarker(text: "HIGH", band: .veryHigh, fontSize: options.flagFontSize)
                            .position(x: plot.minX + x, y: plot.minY + options.flagFontSize)
                    }
                }
            }
        }
    }
}

/// "LOW" / "HIGH" label drawn at a chart edge.
struct FlagMarker: View {
    let text: String
    let band: GlucoseBand
    let fontSize: CGFloat

    var body: some View {
        Text(verbatim: text)
            .font(Typography.fixedLabel(size: fontSize, medium: true))
            .foregroundStyle(Theme.band(band))
            .padding(.horizontal, 2)
            .background(Theme.background.opacity(0.85))
            .fixedSize()
    }
}

/// Outline diamond for fingerstick markers, so they cannot be mistaken for sensor points.
struct FingerstickSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}
