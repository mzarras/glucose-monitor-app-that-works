import SwiftUI
import WidgetCore
import XCTest
@testable import Sensor

/// Renders screens to PNG for design review against designs/*.reference.html.
///
/// Always renders (a crash or empty image fails the test). Writes files to docs/screenshots only
/// when the test process has SENSOR_WRITE_SCREENSHOTS=1, i.e.
///   TEST_RUNNER_SENSOR_WRITE_SCREENSHOTS=1 xcodebuild test … -only-testing:SensorTests/ScreenshotTests
/// Screens use the fixed fixture time (Fixtures.referenceNow = Wed 23 Sep 2026, 12:35 PM New York).
/// Widgets use the real clock because their age text is live (it counts from the actual now).
final class ScreenshotTests: XCTestCase {
    private static let outputDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("docs/screenshots", isDirectory: true)

    private static var shouldWrite: Bool {
        ProcessInfo.processInfo.environment["SENSOR_WRITE_SCREENSHOTS"] == "1"
    }

    private static let newYork = TimeZone(identifier: "America/New_York")!
    private let context = DisplayContext(locale: Locale(identifier: "en_US"), timeZone: ScreenshotTests.newYork)
    private let now = Fixtures.referenceNow

    private var savedTimeZone: TimeZone?

    override func setUp() {
        super.setUp()
        // Chart hour labels use the current zone; pin it so they match the header, and restore it
        // afterwards so no other test sees New York time.
        savedTimeZone = NSTimeZone.default
        NSTimeZone.default = Self.newYork
    }

    override func tearDown() {
        if let savedTimeZone { NSTimeZone.default = savedTimeZone }
        super.tearDown()
    }

    // MARK: Screens

    @MainActor
    func test_renderNowScreens() throws {
        for scheme in [ColorScheme.light, .dark] {
            try render(phone(tab: .now, hasProblems: false) { nowContent(.normal) }, name: "now-\(scheme.name)", scheme: scheme)
        }
        try render(phone(tab: .now, hasProblems: true) { nowContent(.stale) }, name: "now-stale-light", scheme: .light)
        try render(phone(tab: .now, hasProblems: false) { nowContent(.lowFlag) }, name: "now-low-flag-light", scheme: .light)
        try render(phone(tab: .now, hasProblems: true) { nowContent(.manyProblems) }, name: "now-banners-light", scheme: .light, height: nil)
        try render(phone(tab: .now, hasProblems: false) { nowContent(.warmUp) }, name: "now-warm-up-dark", scheme: .dark)
        try render(phone(tab: .now, hasProblems: true) { nowContent(.clockMismatch) }, name: "now-clock-mismatch-light", scheme: .light)
        // D43: the grace-period countdown, light and dark.
        for scheme in [ColorScheme.light, .dark] {
            try render(phone(tab: .now, hasProblems: true) { nowContent(.gracePeriod) }, name: "now-grace-period-\(scheme.name)", scheme: scheme, height: nil)
        }
        // Review B1: the hero at the largest accessibility text size.
        try render(phone(tab: .now, hasProblems: false) { nowContent(.lowFlag) }.environment(\.dynamicTypeSize, .accessibility5),
                   name: "now-low-flag-ax5-light", scheme: .light, height: nil)
        try render(phone(tab: .now, hasProblems: false) { nowContent(.normal) }.environment(\.dynamicTypeSize, .accessibility5),
                   name: "now-ax5-dark", scheme: .dark, height: nil)
    }

    @MainActor
    func test_renderTrendsScreens() throws {
        for scheme in [ColorScheme.light, .dark] {
            try render(phone(tab: .trends, hasProblems: false) { trendsContent(.fourteenDays) }, name: "trends-14d-\(scheme.name)", scheme: scheme, height: nil)
        }
        try render(phone(tab: .trends, hasProblems: false) { trendsContent(.threeDays) }, name: "trends-3d-light", scheme: .light, height: nil)
        try render(phone(tab: .trends, hasProblems: false) { trendsContent(.thirtyDays) }, name: "trends-30d-low-coverage-dark", scheme: .dark, height: nil)
        try render(phone(tab: .trends, hasProblems: false) { trendsContent(.fourteenDays) }.environment(\.dynamicTypeSize, .accessibility5),
                   name: "trends-14d-ax5-light", scheme: .light, height: nil)
        try render(phone(tab: .settings, hasProblems: false) { SettingsContent(state: Fixtures.settings(at: now), now: now, actions: .noop, context: context) }
                    .environment(\.dynamicTypeSize, .accessibility5),
                   name: "settings-ax5-light", scheme: .light, height: nil)
    }

    @MainActor
    func test_renderCalibrationSteps() throws {
        let takenAt = now.addingTimeInterval(-60)
        let confirm = CalibrationFlow(step: .confirm(value: 112, takenAt: takenAt), confirmText: "121")
        try render(calibration(.available, confirm), name: "calibration-mismatch-light", scheme: .light)
        let matched = CalibrationFlow(step: .confirm(value: 112, takenAt: takenAt), confirmText: "112")
        try render(calibration(.available, matched), name: "calibration-retype-matched-dark", scheme: .dark)
        let large = CalibrationFlow(step: .largeDifference(value: 155, takenAt: takenAt, difference: .large(sensorMgdl: 105, difference: 50, limit: 21)))
        try render(calibration(.available, large), name: "calibration-big-difference-dark", scheme: .dark)
    }

    @MainActor
    func test_renderScrubbing() throws {
        for scheme in [ColorScheme.light, .dark] {
            let chart = VStack(alignment: .leading, spacing: 24) {
                scrubChart(.normal, window: .threeHours, minutesBack: 40)
                scrubChart(.normal, window: .twelveHours, minutesBack: 10 * 60 + 5)
                scrubChart(.lowFlag, window: .threeHours, minutesBack: 6)
            }
            .padding(20)
            .editorialScreen()
            try render(chart, name: "now-chart-scrub-\(scheme.name)", scheme: scheme, height: nil)
            let days = Fixtures.dayTraces(count: 3, now: now)
            let overlay = DayOverlayChart(days: days, initialScrubHour: 9.25)
                .frame(width: 350, height: 160)
                .padding(20)
                .editorialScreen()
            try render(overlay, name: "trends-3d-scrub-\(scheme.name)", scheme: scheme, height: nil)
        }
    }

    @MainActor
    private func scrubChart(_ scenario: Fixtures.NowScenario, window: ChartWindow, minutesBack: Double) -> some View {
        let state = Fixtures.now(scenario, at: now)
        let zone = Self.newYork
        return GlucoseTraceChart(
            points: state.chartPoints,
            domain: now.addingTimeInterval(-window.duration)...now,
            latestLive: state.latestLiveReading.map { ChartPoint(date: $0.date, value: $0.value) },
            options: NowContent.chartOptions(window),
            accessibilityTitle: window.spokenName,
            timeText: { date in
                var style = Date.FormatStyle(date: .omitted, time: .shortened)
                style.timeZone = zone
                style.locale = Locale(identifier: "en_US")
                return date.formatted(style)
            },
            initialScrubDate: now.addingTimeInterval(-minutesBack * 60)
        )
        .frame(width: 350, height: 200)
    }

    // MARK: Widgets

    @MainActor
    func test_renderWidgets() throws {
        let live = Date()
        for scheme in [ColorScheme.light, .dark] {
            try render(widgetTile(MediumWidgetView(content: WidgetSamples.content(.normal, now: live))), name: "widget-medium-\(scheme.name)", scheme: scheme, width: 396, height: 202)
            let gallery = VStack(alignment: .leading, spacing: 10) {
                ForEach(WidgetSamples.State.allCases) { state in
                    self.widgetTile(MediumWidgetView(content: WidgetSamples.content(state, now: live)))
                }
            }
            try render(gallery, name: "widget-medium-states-\(scheme.name)", scheme: scheme, width: 396, height: nil)
            let small = HStack(spacing: 10) {
                ForEach([WidgetSamples.State.normal, .lowFlag, .stale, .noData], id: \.self) { state in
                    SmallWidgetView(content: WidgetSamples.content(state, now: live))
                        .padding(16)
                        .frame(width: 170, height: 170)
                        .background(Theme.background)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
            .padding(16)
            .background(Color(white: scheme == .dark ? 0.2 : 0.75))
            try render(small, name: "widget-small-\(scheme.name)", scheme: scheme, width: 752, height: 202)
        }
    }

    // MARK: Composition

    @MainActor
    private func nowContent(_ scenario: Fixtures.NowScenario) -> some View {
        NowContent(state: Fixtures.now(scenario, at: now), calibration: Fixtures.calibration(.available, at: now), now: now, actions: .noop, context: context)
    }

    @MainActor
    private func trendsContent(_ period: TrendsPeriod) -> some View {
        TrendsContent(state: Fixtures.trends(period, at: now), selectPeriod: { _ in }, context: context)
    }

    @MainActor
    private func calibration(_ scenario: Fixtures.CalibrationScenario, _ flow: CalibrationFlow) -> some View {
        CalibrationContent(state: Fixtures.calibration(scenario, at: now), flow: .constant(flow), now: now, submit: { _ in }, close: {}, scrolls: false)
            .frame(width: 390, height: 844, alignment: .top)
            .editorialScreen()
    }

    /// A phone-sized page: content from the top, text tab bar at the bottom.
    @MainActor
    private func phone<Content: View>(tab: AppTab, hasProblems: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content().padding(.top, 20)
            Spacer(minLength: 0)
            SensorTabBar(selected: tab, nowHasProblems: hasProblems, select: { _ in })
                .padding(.bottom, 20)
        }
        .frame(width: 390)
        .editorialScreen()
    }

    @MainActor
    private func widgetTile<Content: View>(_ content: Content) -> some View {
        content
            .padding(16)
            .frame(width: 364, height: 170)
            .background(Theme.background)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(16)
    }

    @MainActor
    private func render<V: View>(_ view: V, name: String, scheme: ColorScheme, width: CGFloat = 390, height: CGFloat? = 844) throws {
        let content = view
            .frame(width: width, height: height, alignment: .top)
            .background(Color(white: scheme == .dark ? 0.2 : 0.75))
            .environment(\.colorScheme, scheme)
            .environment(\.accentChoice, .forest)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        // 2× unless the page is very tall (accessibility sizes), where the bitmap would exceed
        // what the PNG encoder accepts; keep it under ~10k pixels.
        renderer.scale = 1
        let pointHeight = try XCTUnwrap(renderer.uiImage, "\(name) did not render").size.height
        renderer.scale = min(2, max(1, 10_000 / pointHeight))
        let image = try XCTUnwrap(renderer.uiImage, "\(name) did not render")
        XCTAssertGreaterThan(image.size.height, 100, name)
        guard Self.shouldWrite else { return }
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        // Redraw into a standard-range sRGB bitmap: some renders (UIKit-backed controls) come back
        // in an extended-range format the PNG encoder refuses.
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.preferredRange = .standard
        let flattened = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
        let data = try XCTUnwrap(flattened.pngData(), "\(name): no PNG for a \(image.size) image at scale \(image.scale)")
        try data.write(to: Self.outputDirectory.appendingPathComponent("\(name).png"))
    }
}

private extension ColorScheme {
    var name: String { self == .dark ? "dark" : "light" }
}
