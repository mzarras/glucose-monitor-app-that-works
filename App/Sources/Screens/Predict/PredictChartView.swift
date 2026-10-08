// The Predict chart (PROGRESS D57): the last 3 hours of the app's stored readings, drawn exactly as
// on Now (`ChartSeries`: line segments that break at gaps > 15 min, S1; LOW/HIGH as markers at the
// bottom/top edge, never at 40/400, S4), plus — only while the run is current — the forecast as a
// dashed accent line with hollow markers at +5/+30/+60/+120, a "now" rule and a legend, so a reader
// can never mistake it for readings. No scrubbing: nothing here is selectable as a reading.
//
// WidgetCore's `GlucoseTraceChart` draws no forecast by design (HANDOFF §7.5), so this is its own
// chart; the readings part follows the same rules with the same public helpers.

import Charts
import GlucoseCore
import SwiftUI
import WidgetCore

struct PredictChartSection: View {
    let chart: PredictChart

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PredictChartView(chart: chart)
                .frame(height: 210)
            legend
        }
    }

    /// One line when it fits, one entry per line otherwise (large text sizes).
    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { legendEntries }
            VStack(alignment: .leading, spacing: 4) { legendEntries }
        }
        .font(Typography.label(size: 10))
        .foregroundStyle(Theme.muted)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge) // like the axis labels: a compact key
        .accessibilityHidden(true) // the chart's own label says which part is predicted
    }

    @ViewBuilder
    private var legendEntries: some View {
        HStack(spacing: 6) {
            Rectangle().fill(Theme.ink).frame(width: 18, height: 2)
            Text(verbatim: "readings").fixedSize()
        }
        if let forecast = chart.forecastLegend {
            HStack(spacing: 6) {
                LegendDash()
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: 18, height: 2)
                Circle().stroke(Theme.accent, lineWidth: 1.5).frame(width: 7, height: 7)
                Text(verbatim: forecast).fixedSize()
            }
        }
    }
}

private struct LegendDash: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

struct PredictChartView: View {
    let chart: PredictChart

    /// Hours between x-axis labels (the axis spans 3–5 h).
    static let hourStride = 1

    var body: some View {
        let series = ChartSeries(points: chart.readings)
        let forecastMax = chart.forecast.map { Int($0.mgdl.rounded()) }.max()
        let upper = ChartScale.yUpperBound(maxPlotted: max(series.maxPlottedMgdl ?? 0, forecastMax ?? 0))
        Chart {
            RectangleMark(
                xStart: .value("Start", chart.domain.lowerBound),
                xEnd: .value("End", chart.domain.upperBound),
                yStart: .value("Target low", GlucoseThresholds.lowBelow),
                yEnd: .value("Target high", GlucoseThresholds.inRangeUpperBound)
            )
            .foregroundStyle(Theme.rangeBand)
            readingMarks(series)
            RuleMark(x: .value("Now", chart.now))
                .foregroundStyle(Theme.muted)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .annotation(position: .top, alignment: .center, spacing: 2) {
                    Text(verbatim: "NOW")
                        .font(Typography.fixedLabel(size: 9))
                        .foregroundStyle(Theme.muted)
                }
            forecastMarks
        }
        .chartXScale(domain: chart.domain)
        .chartYScale(domain: ChartScale.yLowerBound...upper)
        .chartPlotStyle { plot in
            plot
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.ink).frame(height: 1) }
                .overlay(alignment: .top) { Rectangle().fill(Theme.rule).frame(height: 1) }
        }
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
            AxisMarks(values: .stride(by: .hour, count: Self.hourStride)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(verbatim: HourLabel.text(date))
                            .font(Typography.fixedLabel(size: 10))
                            .foregroundStyle(Theme.muted)
                            .fixedSize()
                    }
                }
            }
        }
        .chartOverlay { proxy in
            PredictFlagOverlay(proxy: proxy, series: series)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: chart.accessibilityLabel))
        .accessibilityIdentifier("predict.chart")
    }

    /// Real readings in ink, joined only within a segment (S1); a one-reading segment is a dot.
    @ChartContentBuilder
    private func readingMarks(_ series: ChartSeries) -> some ChartContent {
        ForEach(Array(series.segments.enumerated()), id: \.offset) { index, segment in
            if segment.count == 1, let only = segment.first {
                PointMark(x: .value("Time", only.date), y: .value("mg/dL", only.mgdl))
                    .symbolSize(24)
                    .foregroundStyle(Theme.ink)
            } else {
                ForEach(segment, id: \.date) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("mg/dL", point.mgdl),
                        series: .value("Line", "reading-\(index)")
                    )
                    .foregroundStyle(Theme.ink)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    /// The forecast: dashed accent line, hollow markers on the predicted points (not on the reading
    /// it starts from). Empty unless the run is current.
    @ChartContentBuilder
    private var forecastMarks: some ChartContent {
        ForEach(chart.forecast, id: \.self) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Predicted mg/dL", point.mgdl),
                series: .value("Line", "predicted")
            )
            .foregroundStyle(Theme.accent)
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 4]))
        }
        ForEach(chart.forecast.filter(\.isPredicted), id: \.self) { point in
            PointMark(x: .value("Time", point.date), y: .value("Predicted mg/dL", point.mgdl))
                .symbol {
                    Circle()
                        .fill(Theme.background)
                        .overlay(Circle().stroke(Theme.accent, lineWidth: 1.5))
                        .frame(width: 8, height: 8)
                }
        }
    }
}

/// LOW markers along the bottom edge and HIGH markers along the top edge, as on the Now chart
/// (WidgetCore `GlucoseTraceChart.flagOverlay`): only the x position comes from the chart; the y
/// position is the edge (S4).
private struct PredictFlagOverlay: View {
    let proxy: ChartProxy
    let series: ChartSeries
    private let fontSize: CGFloat = 9

    var body: some View {
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame {
                let plot = geometry[anchor]
                ForEach(series.lowFlags, id: \.self) { date in
                    if let x = proxy.position(forX: date) {
                        tick(.veryLow).position(x: plot.minX + x, y: plot.maxY - 3)
                    }
                }
                ForEach(series.highFlags, id: \.self) { date in
                    if let x = proxy.position(forX: date) {
                        tick(.veryHigh).position(x: plot.minX + x, y: plot.minY + 3)
                    }
                }
                ForEach(series.lowFlagRuns, id: \.self) { run in
                    if let first = run.first, let x = proxy.position(forX: first) {
                        label("LOW", .veryLow).position(x: clampedX(plot.minX + x, label: "LOW", in: plot), y: plot.maxY - 6 - fontSize)
                    }
                }
                ForEach(series.highFlagRuns, id: \.self) { run in
                    if let first = run.first, let x = proxy.position(forX: first) {
                        label("HIGH", .veryHigh).position(x: clampedX(plot.minX + x, label: "HIGH", in: plot), y: plot.minY + 6 + fontSize)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func tick(_ band: GlucoseBand) -> some View {
        Rectangle().fill(Theme.band(band)).frame(width: 2, height: 6)
    }

    private func label(_ text: String, _ band: GlucoseBand) -> some View {
        Text(verbatim: text)
            .font(Typography.fixedLabel(size: fontSize, medium: true))
            .foregroundStyle(Theme.band(band))
            .padding(.horizontal, 2)
            .background(Theme.background.opacity(0.85))
            .fixedSize()
    }

    /// Keeps the label inside the plot (IBM Plex Mono advance ≈ 0.6 em per character).
    private func clampedX(_ x: CGFloat, label: String, in plot: CGRect) -> CGFloat {
        let half = CGFloat(label.count) * fontSize * 0.6 / 2 + 2
        return min(max(x, plot.minX + half), plot.maxX - half)
    }
}
