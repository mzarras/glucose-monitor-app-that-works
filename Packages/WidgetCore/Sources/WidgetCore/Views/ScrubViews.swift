// Pieces of chart scrubbing shared by the Now chart and the Trends daily traces: the gesture,
// the callout, the haptic mapping, and the VoiceOver audio-graph descriptor. Selection rules are
// in ChartScrub (pure, tested).

import Accessibility
import GlucoseCore
import SwiftUI

public enum ScrubGesture {
    /// Hold this long before dragging scrubs. A swipe that moves sooner scrolls the page instead,
    /// so the chart never fights the ScrollView; once scrubbing, the page stays still.
    public static let holdDuration: Double = 0.2
}

extension View {
    /// Press-and-hold then drag reports finger locations (in this view's space); lifting clears.
    public func scrubGesture(onChange: @escaping @MainActor (CGPoint) -> Void, onEnd: @escaping @MainActor () -> Void) -> some View {
        gesture(
            LongPressGesture(minimumDuration: ScrubGesture.holdDuration)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                .onChanged { value in
                    if case .second(true, let drag?) = value { onChange(drag.location) }
                }
                .onEnded { _ in onEnd() }
        )
    }

    /// Light selection tick when a different real reading is selected; a slightly stronger one when
    /// it is in a different range band. Nothing for gaps. The system honours the user's haptics
    /// setting.
    public func scrubHaptics(_ selection: ScrubSelection) -> some View {
        sensoryFeedback(trigger: selection) { old, new in
            switch ChartScrub.feedback(from: old, to: new) {
            case .selection: return .selection
            case .bandChange: return .impact(weight: .light, intensity: 0.7)
            case nil: return nil
            }
        }
    }
}

/// The box above the scrub rule: Newsreader numeral, Plex Mono unit and time.
public struct ScrubCalloutView: View {
    public let callout: ScrubCallout
    /// Extra lines (3 D overlay: the other days at the same time).
    public let extraLines: [String]

    public init(callout: ScrubCallout, extraLines: [String] = []) {
        self.callout = callout
        self.extraLines = extraLines
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: callout.headline)
                    .font(callout.time == nil ? Typography.body(size: 14, weight: .semibold) : Typography.figure(size: 24))
                    .foregroundStyle(Theme.ink)
                if callout.time != nil {
                    Text(verbatim: callout.detail)
                        .font(Typography.fixedLabel(size: 10))
                        .foregroundStyle(Theme.muted)
                }
            }
            Text(verbatim: callout.time ?? callout.detail)
                .font(Typography.fixedLabel(size: 10))
                .foregroundStyle(Theme.muted)
            ForEach(extraLines, id: \.self) { line in
                Text(verbatim: line)
                    .font(Typography.fixedLabel(size: 10))
                    .foregroundStyle(Theme.muted)
            }
        }
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.background)
        .overlay(Rectangle().stroke(Theme.rule, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// The callout placed over a plot, at the top, beside the scrub rule at `x`: to its right when it
/// fits, otherwise to its left (measured width, so long captions like "below sensor range" never
/// run off the edge). Beside, not over, so it never hides the rule or the highlighted point.
public struct PlacedScrubCallout: View {
    let callout: ScrubCallout
    let extraLines: [String]
    /// Rule position, in the same coordinate space as `plot`.
    let x: CGFloat
    let plot: CGRect

    public init(callout: ScrubCallout, extraLines: [String] = [], x: CGFloat, plot: CGRect) {
        self.callout = callout
        self.extraLines = extraLines
        self.x = x
        self.plot = plot
    }

    /// Left edge of the callout, relative to the plot.
    nonisolated static func left(ruleX: CGFloat, width: CGFloat, plotWidth: CGFloat, gap: CGFloat = 8) -> CGFloat {
        let right = ruleX + gap
        if right + width <= plotWidth { return right }
        return max(0, ruleX - gap - width)
    }

    public var body: some View {
        Color.clear
            .frame(width: plot.width, height: plot.height)
            .overlay(alignment: .topLeading) {
                ScrubCalloutView(callout: callout, extraLines: extraLines)
                    .alignmentGuide(.leading) { size in
                        -Self.left(ruleX: x - plot.minX, width: size.width, plotWidth: plot.width)
                    }
                    .alignmentGuide(.top) { _ in -4 }
            }
            .position(x: plot.midX, y: plot.midY)
    }
}

/// Audio graph / VoiceOver chart description (Swift Charts' accessibilityChartDescriptor).
/// Numeric readings only, as discrete points (never joined across gaps, S1); LOW/HIGH flags have
/// no number to sonify and are listed in the summary instead (S4).
public struct GlucoseChartDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let summary: String
    let points: [PlottedPoint]
    let domain: ClosedRange<Date>

    public init(title: String, summary: String, points: [PlottedPoint], domain: ClosedRange<Date>) {
        self.title = title
        self.summary = summary
        self.points = points
        self.domain = domain
    }

    public func makeChartDescriptor() -> AXChartDescriptor {
        let xAxis = AXNumericDataAxisDescriptor(
            title: "Time",
            range: domain.lowerBound.timeIntervalSince1970...domain.upperBound.timeIntervalSince1970,
            gridlinePositions: []
        ) { value in
            Date(timeIntervalSince1970: value).formatted(date: .omitted, time: .shortened)
        }
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Glucose, milligrams per deciliter",
            range: Double(ChartScale.yLowerBound)...400,
            gridlinePositions: [70, 180]
        ) { value in
            "\(Int(value)) milligrams per deciliter"
        }
        let series = AXDataSeriesDescriptor(
            name: title,
            isContinuous: false,
            dataPoints: points.map { AXDataPoint(x: $0.date.timeIntervalSince1970, y: Double($0.mgdl)) }
        )
        return AXChartDescriptor(title: title, summary: summary, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [series])
    }
}
