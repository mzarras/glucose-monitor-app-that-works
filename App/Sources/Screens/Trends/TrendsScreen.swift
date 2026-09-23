// Trends screen (HANDOFF §6, §7.3.2; designs/trends-screen.reference.html). Spec over mockup:
// periods 1/3/7/14/30/90 D (default 14 D), no forecast, "in range after runs" hidden until v1.1,
// GMI only for ≥ 14 D, 1 D / 3 D show real daily traces instead of percentile bands, and a
// data-sufficiency warning under 70 % on every period.

import GlucoseCore
import SwiftUI
import WidgetCore

struct TrendsScreen: View {
    let state: TrendsViewState
    let selectPeriod: @MainActor (TrendsPeriod) -> Void

    var body: some View {
        ScrollView {
            TrendsContent(state: state, selectPeriod: selectPeriod)
        }
        .editorialScreen()
    }
}

struct TrendsContent: View {
    let state: TrendsViewState
    let selectPeriod: @MainActor (TrendsPeriod) -> Void
    var context: DisplayContext = .current

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            titleBlock
            TextSegmentPicker(
                options: TrendsPeriod.allCases,
                selected: state.period,
                label: \.label,
                spokenLabel: { $0 == .oneDay ? "1 day" : "\($0.days) days" },
                select: selectPeriod
            )
            .padding(.top, -8)
            if let warning = TrendsText.sufficiencyWarning(state.dataSufficiency) {
                WarningNote(text: warning)
            }
            hero
            if let bins = state.rangeBins {
                RangeBarView(bins: bins)
            }
            profileSection
            MetricRowsView(state: state)
            if let footnote = TrendsText.importedFootnote(state.importedData, context: context) {
                Text(verbatim: footnote)
                    .font(Typography.body(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Layout.sideMargin)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: TrendsText.title(state.period))
                .font(Typography.title(size: 36))
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: TrendsText.dateRange(state.interval, context: context))
                .monoLabel(size: 11)
                .foregroundStyle(Theme.muted)
            Hairline().padding(.top, 6)
        }
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: state.timeInRange.map { String(Int($0.rounded())) } ?? "—")
                    .font(Typography.statHero(size: 104))
                    .tracking(-2)
                if state.timeInRange != nil {
                    Text(verbatim: "%").font(Typography.statHero(size: 48))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.vertical, -10)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "time in range")
                    .font(Typography.body(size: 14))
                Text(verbatim: "70–180 mg/dL")
                    .font(Typography.label(size: 11))
                    .foregroundStyle(Theme.muted)
                Text(verbatim: TrendsText.change(state.timeInRangeChange, period: state.period))
                    .font(Typography.label(size: 11, medium: true))
                    .foregroundStyle(state.timeInRangeChange == nil ? AnyShapeStyle(Theme.muted) : AnyShapeStyle(Theme.accent))
            }
            .padding(.bottom, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: TrendsText.heroSpeech(state)))
    }

    @ViewBuilder
    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Hairline(strong: true)
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: profileTitle)
                    .font(Typography.title(size: 20))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(verbatim: profileLegend)
                    .font(Typography.label(size: 10))
                    .foregroundStyle(Theme.muted)
            }
            switch state.profile {
            case .none:
                Text(verbatim: "No readings in this period.")
                    .font(Typography.body(size: 13))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            case .percentiles(let buckets):
                AGPChart(buckets: buckets)
                    .frame(height: 160)
            case .days(let days):
                DayOverlayChart(days: days)
                    .frame(height: 160)
            }
        }
    }

    private var profileTitle: String {
        switch state.period {
        case .oneDay: return "Today's readings"
        case .threeDays: return "Three days, by time of day"
        default: return "A typical day"
        }
    }

    private var profileLegend: String {
        switch state.period {
        case .oneDay: return "READINGS · 70–180"
        case .threeDays: return "TODAY · 2 DAYS BEFORE"
        default: return "MEDIAN · 25–75 · 5–95"
        }
    }
}

/// Muted box with an alert rule, for the data-sufficiency warning.
struct WarningNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(Theme.band(.high)).frame(width: 3).accessibilityHidden(true)
            Text(verbatim: text)
                .font(Typography.body(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .overlay(Rectangle().stroke(Theme.rule, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "Warning: \(text)"))
    }
}

// MARK: - Range bar

struct RangeBarView: View {
    let bins: RangeBins
    private let bands: [(GlucoseBand, String)] = [
        (.veryLow, "<54"), (.low, "54–69"), (.inRange, "70–180"), (.high, "181–250"), (.veryHigh, ">250"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let visible = bands.filter { bins.percent(for: $0.0) > 0 }
                let gaps = CGFloat(max(0, visible.count - 1)) * 2
                let usable = max(0, geometry.size.width - gaps)
                let total = max(visible.reduce(0) { $0 + bins.percent(for: $1.0) }, 0.0001)
                HStack(spacing: 2) {
                    ForEach(visible, id: \.0) { band, _ in
                        Rectangle()
                            .fill(Theme.band(band))
                            .frame(width: max(2, usable * bins.percent(for: band) / total))
                    }
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            HStack(alignment: .top, spacing: 4) {
                ForEach(bands, id: \.0) { band, label in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: label)
                            .font(Typography.label(size: 10))
                            .foregroundStyle(Theme.muted)
                        Text(verbatim: TrendsText.binPercent(bins.percent(for: band)))
                            .font(Typography.label(size: 12))
                            .foregroundStyle(Theme.ink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: TrendsText.binsSpeech(bins)))
    }
}

// MARK: - Metric rows

struct MetricRowsView: View {
    let state: TrendsViewState

    var body: some View {
        VStack(spacing: 0) {
            Hairline(strong: true)
            row("Time in tight range", note: "70–140", value: TrendsText.percent(state.tightRange))
            row("Mean glucose", note: nil, value: TrendsText.mgdl(state.meanMgdl), unit: state.meanMgdl == nil ? nil : "mg/dL")
            row("GMI", note: "est. A1C", value: TrendsText.gmi(state.gmiPercent, period: state.period), valueIsNote: state.period.days < TrendsText.gmiMinimumDays)
            row("Variability", note: "CV, target under 36%", value: TrendsText.percent(state.cvPercent))
            if let lows = state.lows {
                row("Lows", note: TrendsText.lowsNote(lows), value: String(lows.count), unit: TrendsText.lowsDuration(lows))
            } else {
                row("Lows", note: nil, value: "—")
            }
            row("Overnight in range", note: "12–6 AM", value: TrendsText.percent(state.overnightTimeInRange))
            if FeatureFlags.showsAfterExerciseRow {
                row("In range after runs", note: "4 h window", value: TrendsText.percent(state.afterExerciseTimeInRange))
            }
            row("Longest in-range stretch", note: nil, value: TrendsText.streak(state.longestInRangeStreak), isLast: true)
        }
    }

    private func row(_ title: String, note: String?, value: String, unit: String? = nil, valueIsNote: Bool = false, isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(Typography.body(size: 14))
                    if let note {
                        Text(verbatim: note)
                            .font(Typography.body(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if valueIsNote {
                        Text(verbatim: value)
                            .font(Typography.label(size: 11))
                            .foregroundStyle(Theme.muted)
                    } else {
                        Text(verbatim: value).font(Typography.title(size: 22))
                    }
                    if let unit {
                        Text(verbatim: unit)
                            .font(Typography.label(size: 11))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
            .padding(.vertical, 12)
            if !isLast { Hairline() }
        }
        .accessibilityElement(children: .combine)
    }
}
