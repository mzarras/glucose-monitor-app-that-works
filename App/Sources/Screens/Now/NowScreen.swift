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
    /// Pair a new sensor (new-sensor flow).
    var pairSensor: @MainActor () -> Void
    /// Pair the worn sensor again (Settings › Sensor → `pairAgain(code:)`).
    var pairAgain: @MainActor () -> Void
    var performBannerAction: @MainActor (AppBanner.Action) -> Void

    static var noop: NowActions {
        NowActions(selectChartWindow: { _ in }, openAlerts: {}, openSensorSettings: {}, openCalibration: {},
                   exportDiagnostics: {}, pairSensor: {}, pairAgain: {}, performBannerAction: { _ in })
    }
}

struct NowScreen: View {
    let state: NowViewState
    let calibration: CalibrationViewState
    let actions: NowActions
    /// The clock to classify against (AppModel.clock); read on every 15-second tick and every
    /// state change.
    var clock: @MainActor () -> Date = { Date() }

    var body: some View {
        // Every 15 s, and exactly at the grace period's end (D43), so "Sensor expired" takes over
        // the moment the countdown reaches zero.
        TimelineView(NowRefreshSchedule(interval: 15, extraDates: graceEnd.map { [$0] } ?? [])) { timeline in
            ScrollView {
                NowContent(state: state, calibration: calibration,
                           now: NowRefreshSchedule.renderDate(scheduled: timeline.date, clock: clock()),
                           actions: actions, liveClock: clock)
            }
        }
        .editorialScreen()
    }

    private var graceEnd: Date? {
        if case .gracePeriod(let endsAt) = state.sensorState { return endsAt }
        return nil
    }
}

struct NowContent: View {
    let state: NowViewState
    let calibration: CalibrationViewState
    let now: Date
    let actions: NowActions
    var context: DisplayContext = .current
    /// The running app's clock, for the live (1 s) grace countdown; nil renders it at `now`.
    var liveClock: (@MainActor () -> Date)? = nil
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
                            .accessibilityIdentifier("banner.\(banner.kind)")
                    }
                }
            }
            NowHeroView(hero: NowHero.make(display, now: now, context: context, sensorStateKnown: state.sensorStateKnown), now: now,
                        pairSensor: actions.pairSensor, pairAgain: actions.pairAgain, calibrate: actions.openCalibration)
            stateLine(display)
            if let end = GraceCountdown.end(sensorState: state.sensorState, now: now) {
                GraceCountdownView(end: end, now: now, liveClock: liveClock)
            }
            chartSection
            TodaySoFarView(today: state.today)
                .accessibilityIdentifier("now.today")
            statusRows
        }
        .padding(.horizontal, Layout.sideMargin)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    // MARK: Header

    /// Wordmark, date and time, sound and menu buttons on one row when they fit; otherwise
    /// (large text sizes) the date moves to its own line. Nothing is truncated (review m9).
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    wordmark
                    headerDate
                    Spacer(minLength: 0)
                    headerButtons
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .center, spacing: 10) {
                        wordmark
                        Spacer(minLength: 0)
                        headerButtons
                    }
                    headerDate
                }
            }
            Hairline()
        }
    }

    private var wordmark: some View {
        Text(verbatim: "glucose")
            .font(Typography.wordmark(size: 22))
            .lineLimit(1)
            .fixedSize()
            .layoutProbe("header.wordmark")
            .accessibilityAddTraits(.isHeader)
    }

    private var headerDate: some View {
        Text(verbatim: "\(TimeText.headerDate(now, context)) · \(TimeText.time(now, context))")
            .font(Typography.label(size: 11))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var headerButtons: some View {
        HStack(spacing: 0) {
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
        .fixedSize()
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
        let line = StateLine.make(display, sensorState: state.sensorState, now: now, context: context, sensorStateKnown: state.sensorStateKnown)
        return HStack(spacing: 8) {
            Circle()
                .fill(dotStyle(line.dot))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(verbatim: line.text)
                .monoLabel(size: 11)
                .foregroundStyle(Theme.ink)
                .accessibilityIdentifier("now.stateLine")
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
                latestLive: state.latestLiveReading.map { ChartPoint(date: $0.date, value: $0.value) },
                fingersticks: state.fingersticks,
                options: Self.chartOptions(state.chartWindow),
                accessibilityTitle: state.chartWindow.spokenName,
                timeText: { [context] in TimeText.time($0, context) }
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

    /// The Now chart: axes, target band, latest-reading dot, and finger scrubbing (D23).
    static func chartOptions(_ window: ChartWindow) -> GlucoseTraceChart.Options {
        var options = GlucoseTraceChart.Options.nowScreen
        options.hourStride = window.hourStride
        return options
    }

    // MARK: Status rows

    private var statusRows: some View {
        VStack(spacing: 6) {
            Hairline()
                .padding(.bottom, 4)
            StatusRow(label: "SENSOR", value: state.sensorStateKnown || state.sensorState != .notPaired
                      ? SensorStatusText.row(state.sensorState, session: state.sensorSession, now: now, context: context)
                      : "checking…")
                .accessibilityIdentifier("now.sensorRow")
            StatusRow(label: "TRIO", value: TrioStatusText.row(state.health.trio, context: context), valueIsAlert: isTrioFailing)
                .accessibilityIdentifier("now.trioRow")
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
    var pairAgain: @MainActor () -> Void = {}
    var calibrate: @MainActor () -> Void = {}
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        switch hero {
        case .reading(let reading):
            readingView(reading)
        case .message(let title, let detail, let action):
            VStack(alignment: .leading, spacing: 10) {
                // The message reads as one element; the button stays its own (VoiceOver, UI tests).
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: title)
                        .font(Typography.title(size: 36))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: detail)
                        .font(Typography.body(size: 14))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("now.hero.message")
                if let action {
                    Button(action.title) {
                        switch action {
                        case .pairSensor: pairSensor()
                        case .pairAgain: pairAgain()
                        case .calibrate: calibrate()
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 220)
                    .accessibilityIdentifier("now.hero.action")
                }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.alert).frame(width: 3).accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 106, alignment: .leading)
        }
    }

    /// The side column (arrow, unit or LOW/HIGH caption, delta) grows with Dynamic Type only up to
    /// this size; the number itself is fixed-size. Beyond it the side column stays readable without
    /// squeezing the number (review B1).
    static let sideColumnMaxTypeSize = DynamicTypeSize.xxxLarge

    static func numberFont(_ value: GlucoseValue) -> Font {
        Typography.heroNumeral(size: value.numericMgdl == nil ? 104 : 132)
    }

    static func numberTracking(_ value: GlucoseValue) -> CGFloat {
        value.numericMgdl == nil ? 0 : -3
    }

    /// Number and side column side by side when they fit at full size (the mockup); otherwise,
    /// and always at accessibility text sizes, stacked: the number on its own row, the side
    /// column under it. The number is never scaled down to make room (review B1).
    private func readingView(_ reading: LatestReading) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stacked(reading)
            } else {
                ViewThatFits(in: .horizontal) {
                    sideBySide(reading)
                    stacked(reading)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: HeroSpeech.label(for: reading, now: now)))
        .accessibilityValue(Text(verbatim: reading.delta.map(DeltaText.spoken) ?? ""))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("now.hero.reading")
    }

    private func sideBySide(_ reading: LatestReading) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            number(reading)
                .layoutPriority(1)
            VStack(alignment: .leading, spacing: 6) {
                arrow(reading)
                caption(reading)
                delta(reading)
            }
            .padding(.bottom, 6)
            .fixedSize()
            .dynamicTypeSize(...Self.sideColumnMaxTypeSize)
        }
    }

    private func stacked(_ reading: LatestReading) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            number(reading)
            HStack(alignment: .center, spacing: 12) {
                arrow(reading)
                VStack(alignment: .leading, spacing: 4) {
                    caption(reading)
                    delta(reading)
                }
            }
            .dynamicTypeSize(...Self.sideColumnMaxTypeSize)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func number(_ reading: LatestReading) -> some View {
        Text(verbatim: GlucoseText.value(reading.value))
            .font(Self.numberFont(reading.value))
            .tracking(Self.numberTracking(reading.value))
            .heroForeground(WidgetStyle.heroStyle(reading.value))
            .lineLimit(1)
            // Last resort for very narrow screens (Display Zoom on a 320-pt phone); never needed
            // at 335 pt and wider, which the layout tests check.
            .minimumScaleFactor(0.6)
            .layoutProbe("hero.number")
            .padding(.vertical, -14)
    }

    private func arrow(_ reading: LatestReading) -> some View {
        TrendArrowView(arrow: reading.trend, size: 32, lineWidth: 2)
            .foregroundStyle(Theme.accent)
            .frame(height: 24)
    }

    private func caption(_ reading: LatestReading) -> some View {
        Text(verbatim: GlucoseText.flagCaption(reading.value) ?? GlucoseText.unit)
            .font(Typography.label(size: 12))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .layoutProbe("hero.caption")
    }

    @ViewBuilder
    private func delta(_ reading: LatestReading) -> some View {
        if let delta = reading.delta {
            Text(verbatim: DeltaText.text(delta))
                .font(Typography.label(size: 12))
                .foregroundStyle(Theme.muted)
                .accessibilityLabel(Text(verbatim: DeltaText.spoken(delta)))
        }
    }
}

// MARK: - Today so far

struct TodaySoFarView: View {
    let today: TodaySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Hairline(strong: true)
            SectionLabel("TODAY SO FAR")
            // Three columns when they fit; one per row at large text sizes, so a caption never
            // breaks mid-word.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    figures(columns: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    figures(columns: false)
                }
            }
        }
    }

    @ViewBuilder
    private func figures(columns: Bool) -> some View {
        figure(today.timeInRangePercent.map(String.init) ?? "—", suffix: today.timeInRangePercent == nil ? nil : "%", caption: "in range", column: columns)
        figure(today.averageMgdl.map(String.init) ?? "—", suffix: nil, caption: "average", column: columns)
        figure(today.lowCount.map(String.init) ?? "—", suffix: nil, caption: "lows", column: columns)
    }

    private func figure(_ value: String, suffix: String?, caption: String, column: Bool) -> some View {
        let number = HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: value).font(Typography.figure(size: 36))
            if let suffix {
                Text(verbatim: suffix).font(Typography.figure(size: 20))
            }
        }
        let label = Text(verbatim: caption)
            .font(Typography.body(size: 12))
            .foregroundStyle(Theme.muted)
            .lineLimit(1)
            .fixedSize()
        return Group {
            if column {
                VStack(alignment: .leading, spacing: 2) {
                    number
                    label
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    number
                    label
                }
            }
        }
        .fixedSize(horizontal: !column, vertical: false)
        .accessibilityElement(children: .combine)
    }
}
