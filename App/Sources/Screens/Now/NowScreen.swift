// Now screen (HANDOFF §7.3.1; designs/now-screen.reference.html). Layout top to bottom: header,
// S5 banners, hero (or a message when stale/invalid), state line, chart with window picker,
// "Today so far", status rows.
//
// `NowScreen` re-classifies against a live clock every 15 s, so staleness appears on time even if
// no new state arrives (S5). `NowContent` renders one moment and is what previews and the
// screenshot test use.

import GlucoseCore
import SwiftUI
import WidgetCore

struct NowActions {
    var selectChartWindow: @MainActor (ChartWindow) -> Void
    /// Header sound button: the Alerts tab (sounds and snoozes live there).
    var openAlerts: @MainActor () -> Void
    var openSensorSettings: @MainActor () -> Void
    var openCalibration: @MainActor () -> Void
    var exportDiagnostics: @MainActor () -> Void
    var pairSensor: @MainActor () -> Void
    var performBannerAction: @MainActor (AppBanner.Action) -> Void

    static var noop: NowActions {
        NowActions(selectChartWindow: { _ in }, openAlerts: {}, openSensorSettings: {}, openCalibration: {},
                   exportDiagnostics: {}, pairSensor: {}, performBannerAction: { _ in })
    }
}

struct NowScreen: View {
    let state: NowViewState
    let calibration: CalibrationViewState
    let actions: NowActions

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            ScrollView {
                NowContent(state: state, calibration: calibration, now: timeline.date, actions: actions)
            }
        }
        .editorialScreen()
    }
}

struct NowContent: View {
    let state: NowViewState
    let calibration: CalibrationViewState
    let now: Date
    let actions: NowActions
    var context: DisplayContext = .current
    @State private var isMenuPresented = false

    var body: some View {
        let display = state.display(now: now)
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            header
            let banners = state.banners(now: now, context: context)
            if !banners.isEmpty {
                VStack(spacing: 8) {
                    ForEach(banners) { banner in
                        BannerView(banner: banner, perform: actions.performBannerAction)
                    }
                }
            }
            NowHeroView(hero: NowHero.make(display, now: now, context: context), now: now, pairSensor: actions.pairSensor)
            stateLine(display)
            chartSection
            TodaySoFarView(today: state.today)
            statusRows
        }
        .padding(.horizontal, Layout.sideMargin)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Text(verbatim: "glucose")
                    .font(Typography.wordmark(size: 22))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: "\(TimeText.headerDate(now, context)) · \(TimeText.time(now, context))")
                    .font(Typography.label(size: 11))
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                Button(action: actions.openAlerts) {
                    Image(systemName: "speaker.wave.1")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(Theme.ink)
                        .frame(width: Layout.minTarget, height: Layout.minTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Alert sounds"))
                menu
            }
            Hairline()
        }
    }

    /// Header menu: a button and a confirmation dialog. When calibration is unavailable the dialog
    /// message and the calibration sheet say why.
    private var menu: some View {
        Button {
            isMenuPresented = true
        } label: {
            MenuGlyph()
                .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .foregroundStyle(Theme.ink)
                .frame(width: 20, height: 20)
                .frame(width: Layout.minTarget, height: Layout.minTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Menu"))
        .confirmationDialog("Menu", isPresented: $isMenuPresented, titleVisibility: .hidden) {
            Button("Calibrate sensor…", action: actions.openCalibration)
            Button("Sensor settings", action: actions.openSensorSettings)
            Button("Export diagnostics", action: actions.exportDiagnostics)
        } message: {
            if case .unavailable(let reason) = CalibrationRules.availability(calibration, now: now) {
                Text(verbatim: "Calibration: \(reason)")
            }
        }
    }

    // MARK: State line

    private func stateLine(_ display: GlucoseDisplayState) -> some View {
        let line = StateLine.make(display, sensorState: state.sensorState, now: now, context: context)
        return HStack(spacing: 8) {
            Circle()
                .fill(dotStyle(line.dot))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(verbatim: line.text)
                .monoLabel(size: 11)
                .foregroundStyle(Theme.ink)
        }
    }

    private func dotStyle(_ dot: StateLine.Dot) -> AnyShapeStyle {
        switch dot {
        case .band(let band): return AnyShapeStyle(Theme.band(band))
        case .alert: return AnyShapeStyle(Theme.alert)
        case .muted: return AnyShapeStyle(Theme.muted)
        }
    }

    // MARK: Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            GlucoseTraceChart(
                points: state.chartPoints,
                domain: now.addingTimeInterval(-state.chartWindow.duration)...now,
                fingersticks: state.fingersticks,
                options: GlucoseTraceChart.Options(showsAxes: true, hourStride: state.chartWindow.hourStride),
                accessibilityTitle: state.chartWindow.spokenName
            )
            .frame(height: 200)
            TextSegmentPicker(
                options: ChartWindow.allCases,
                selected: state.chartWindow,
                label: \.label,
                spokenLabel: { "\($0.rawValue) hours" },
                select: actions.selectChartWindow
            )
        }
    }

    // MARK: Status rows

    private var statusRows: some View {
        VStack(spacing: 6) {
            Hairline()
                .padding(.bottom, 4)
            StatusRow(label: "SENSOR", value: SensorStatusText.row(state.sensorState, now: now, context: context))
            StatusRow(label: "TRIO", value: TrioStatusText.row(state.health.trio, context: context), valueIsAlert: isTrioFailing)
        }
    }

    private var isTrioFailing: Bool {
        if case .failing = state.health.trio { return true }
        return false
    }
}

/// The mockup's menu icon: two horizontal lines on a 24-point grid (M4 9h16, M4 15h16).
struct MenuGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        var path = Path()
        for y in [9.0, 15.0] {
            path.move(to: CGPoint(x: rect.minX + 4 * unit, y: rect.minY + y * unit))
            path.addLine(to: CGPoint(x: rect.minX + 20 * unit, y: rect.minY + y * unit))
        }
        return path
    }
}

// MARK: - Hero

struct NowHeroView: View {
    let hero: NowHero
    let now: Date
    let pairSensor: @MainActor () -> Void

    var body: some View {
        switch hero {
        case .reading(let reading):
            readingView(reading)
        case .message(let title, let detail, let action):
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: title)
                    .font(Typography.title(size: 36))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: detail)
                    .font(Typography.body(size: 14))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if action == .pairSensor {
                    Button("Pair a sensor", action: pairSensor)
                        .buttonStyle(PrimaryButtonStyle())
                        .frame(maxWidth: 220)
                }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.alert).frame(width: 3).accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 106, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private func readingView(_ reading: LatestReading) -> some View {
        let isFlag = reading.value.numericMgdl == nil
        return HStack(alignment: .bottom, spacing: 16) {
            Text(verbatim: GlucoseText.value(reading.value))
                .font(Typography.heroNumeral(size: isFlag ? 104 : 132))
                .tracking(isFlag ? 0 : -3)
                .heroForeground(WidgetStyle.heroStyle(reading.value))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .padding(.vertical, -14)
            VStack(alignment: .leading, spacing: 6) {
                TrendArrowView(arrow: reading.trend, size: 32, lineWidth: 2)
                    .foregroundStyle(Theme.accent)
                    .frame(height: 24)
                Text(verbatim: GlucoseText.flagCaption(reading.value) ?? GlucoseText.unit)
                    .font(Typography.label(size: 12))
                    .foregroundStyle(Theme.ink)
                if let delta = reading.delta {
                    Text(verbatim: DeltaText.text(delta))
                        .font(Typography.label(size: 12))
                        .foregroundStyle(Theme.muted)
                        .accessibilityLabel(Text(verbatim: DeltaText.spoken(delta)))
                }
            }
            .padding(.bottom, 6)
            .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: HeroSpeech.label(for: reading, now: now)))
        .accessibilityValue(Text(verbatim: reading.delta.map(DeltaText.spoken) ?? ""))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Today so far

struct TodaySoFarView: View {
    let today: TodaySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Hairline(strong: true)
            SectionLabel("TODAY SO FAR")
            HStack(alignment: .top, spacing: 12) {
                figure(today.timeInRangePercent.map(String.init) ?? "—", suffix: today.timeInRangePercent == nil ? nil : "%", caption: "in range")
                figure(today.averageMgdl.map(String.init) ?? "—", suffix: nil, caption: "average")
                figure(today.lowCount.map(String.init) ?? "—", suffix: nil, caption: "lows")
            }
        }
    }

    private func figure(_ value: String, suffix: String?, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: value).font(Typography.figure(size: 36))
                if let suffix {
                    Text(verbatim: suffix).font(Typography.figure(size: 20))
                }
            }
            Text(verbatim: caption)
                .font(Typography.body(size: 12))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
