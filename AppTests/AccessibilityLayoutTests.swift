import GlucoseCore
import SwiftUI
import UIKit
import WidgetCore
import XCTest
@testable import Sensor

/// Renders views in a window at a given text size and compares the rendered size of the text that
/// must stay whole (marked with `.layoutProbe`) with that text's ideal size. A single-line text
/// rendered narrower than its ideal width was scaled down or truncated.
@MainActor
private final class SizeRecorder {
    var sizes: [String: CGSize] = [:]
}

@MainActor
private enum LayoutHarness {
    static func probe<V: View>(_ view: V, width: CGFloat, typeSize: DynamicTypeSize) -> [String: CGSize] {
        let recorder = SizeRecorder()
        let root = view
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.layoutProbe, LayoutProbe { name, size in recorder.sizes[name] = size })
            .environment(\.dynamicTypeSize, typeSize)
            .environment(\.locale, Locale(identifier: "en_US"))
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 3000))
        window.rootViewController = host
        window.isHidden = false
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // Geometry-change actions run after layout, on the main run loop.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.isHidden = true
        return recorder.sizes
    }

    /// One-line ideal size.
    static func idealSize<V: View>(_ view: V, typeSize: DynamicTypeSize) -> CGSize {
        let host = UIHostingController(rootView: view.fixedSize().environment(\.dynamicTypeSize, typeSize))
        return host.sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
    }

    /// Height needed to show all of a (wrapping) text at `width`.
    static func heightNeeded<V: View>(_ view: V, width: CGFloat, typeSize: DynamicTypeSize) -> CGFloat {
        let host = UIHostingController(rootView: view.fixedSize(horizontal: false, vertical: true).environment(\.dynamicTypeSize, typeSize))
        return host.sizeThatFits(in: CGSize(width: width, height: 10_000)).height
    }
}

final class AccessibilityLayoutTests: XCTestCase {
    private let typeSizes: [DynamicTypeSize] = [.large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5]
    /// Hero width on a 375-pt phone (iPhone SE, mini) and on a 390-pt phone, minus 20-pt margins.
    private let heroWidths: [CGFloat] = [335, 350]

    // MARK: Review B1

    @MainActor
    func test_S4_lowHighHeroVisibleAtAccessibilitySizes() {
        for value in [GlucoseValue.belowRange, .aboveRange] {
            assertHeroFullyVisible(value)
        }
    }

    @MainActor
    func test_S5_heroNumberVisibleAtAccessibilitySizes() {
        for value in [GlucoseValue.mgdl(55), .mgdl(105), .mgdl(400)] {
            assertHeroFullyVisible(value)
        }
    }

    @MainActor
    private func assertHeroFullyVisible(_ value: GlucoseValue, file: StaticString = #filePath, line: UInt = #line) {
        let isFlag = value.numericMgdl == nil
        let reading = LatestReading(
            date: minutes(-3), value: value, trend: isFlag ? .notComputable : .singleDown,
            delta: isFlag ? nil : GlucoseDelta(mgdl: -12, minutes: 5)
        )
        let numberText = Text(verbatim: GlucoseText.value(value))
            .font(NowHeroView.numberFont(value))
            .tracking(NowHeroView.numberTracking(value))
        let captionText = Text(verbatim: GlucoseText.flagCaption(value) ?? GlucoseText.unit)
            .font(Typography.label(size: 12))

        for width in heroWidths {
            for typeSize in typeSizes {
                let label = "\(GlucoseText.value(value)) at \(typeSize), width \(width)"
                let sizes = LayoutHarness.probe(NowHeroView(hero: .reading(reading), now: t0, pairSensor: {}), width: width, typeSize: typeSize)
                guard let number = sizes["hero.number"], let caption = sizes["hero.caption"] else {
                    XCTFail("\(label): hero not rendered (\(sizes))", file: file, line: line)
                    continue
                }
                let ideal = LayoutHarness.idealSize(numberText, typeSize: typeSize)
                XCTAssertGreaterThanOrEqual(number.width + 0.5, ideal.width, "\(label): number scaled or truncated", file: file, line: line)
                XCTAssertLessThanOrEqual(number.width, width + 0.5, "\(label): number wider than the screen", file: file, line: line)

                let captionSize = min(typeSize, NowHeroView.sideColumnMaxTypeSize)
                let needed = LayoutHarness.heightNeeded(captionText, width: caption.width, typeSize: captionSize)
                XCTAssertGreaterThanOrEqual(caption.height + 0.5, needed, "\(label): caption clipped", file: file, line: line)
                XCTAssertLessThanOrEqual(caption.width, width + 0.5, "\(label): caption off screen", file: file, line: line)
            }
        }
    }

    /// Review n2: negative control. The pre-fix hero layout (fixed-size side column next to a
    /// number allowed to shrink to 40 %) must fail the same measurement at AX5, proving the check
    /// above can detect a truncated hero.
    @MainActor
    func test_harnessDetectsTheOldTruncatingHeroLayout() {
        for value in [GlucoseValue.belowRange, .aboveRange] {
            let numberText = Text(verbatim: GlucoseText.value(value))
                .font(NowHeroView.numberFont(value))
                .tracking(NowHeroView.numberTracking(value))
            let sizes = LayoutHarness.probe(LegacyHeroLayout(value: value), width: 350, typeSize: .accessibility5)
            let ideal = LayoutHarness.idealSize(numberText, typeSize: .accessibility5)
            guard let number = sizes["hero.number"] else { return XCTFail("legacy hero not rendered") }
            XCTAssertLessThan(number.width + 0.5, ideal.width, "the old layout should have squeezed \(GlucoseText.value(value))")
        }
    }

    // MARK: Review m9

    @MainActor
    func test_headerWordmarkNeverClipsAtAccessibilitySizes() {
        let state = Fixtures.now(.normal, at: t0)
        for typeSize in typeSizes {
            let sizes = LayoutHarness.probe(
                NowContent(state: state, calibration: .unavailable, now: t0, actions: .noop, context: testContext),
                width: 375, typeSize: typeSize
            )
            guard let wordmark = sizes["header.wordmark"] else {
                XCTFail("\(typeSize): header not rendered")
                continue
            }
            let ideal = LayoutHarness.idealSize(Text(verbatim: "glucose").font(Typography.wordmark(size: 22)), typeSize: typeSize)
            XCTAssertGreaterThanOrEqual(wordmark.width + 0.5, ideal.width, "\(typeSize): wordmark clipped")
            XCTAssertGreaterThanOrEqual(wordmark.height + 0.5, ideal.height, "\(typeSize): wordmark wrapped or clipped")
        }
    }

    /// D56: four titles ("Now · Predict · Trends · Settings") fit whole in their columns at every
    /// supported size, on a 375-pt phone, with the red dot on every tab that can show one (D55:
    /// Now and Settings) and each tab selected in turn (semibold is the widest).
    @MainActor
    func test_tabTitlesNeverClipOrWrapAtAccessibilitySizes() {
        XCTAssertEqual(AppTab.allCases.count, 4)
        let width: CGFloat = 375
        let column = width / CGFloat(AppTab.allCases.count)
        let dotAndSpacing: CGFloat = 5 + 6 // SensorTabBar: HStack spacing 5, 6-pt dot
        for typeSize in typeSizes {
            for selected in AppTab.allCases {
                let sizes = LayoutHarness.probe(SensorTabBar(selected: selected, attention: Set(AppTab.allCases), select: { _ in }),
                                                width: width, typeSize: typeSize)
                for tab in AppTab.allCases {
                    guard let title = sizes["tab.title.\(tab.rawValue)"] else {
                        XCTFail("\(typeSize): \(tab) not rendered")
                        continue
                    }
                    XCTAssertNotNil(sizes["tab.dot.\(tab.rawValue)"], "\(typeSize): \(tab) dot not rendered")
                    let font = Typography.body(size: 13, weight: tab == selected ? .semibold : .regular)
                    let ideal = LayoutHarness.idealSize(Text(verbatim: tab.title).font(font), typeSize: min(typeSize, SensorTabBar.maxTypeSize))
                    XCTAssertGreaterThanOrEqual(title.width + 0.5, ideal.width, "\(typeSize): \(tab) clipped (selected \(selected))")
                    XCTAssertLessThanOrEqual(title.height, ideal.height + 0.5, "\(typeSize): \(tab) wrapped (selected \(selected))")
                    XCTAssertLessThanOrEqual(title.width + dotAndSpacing, column, "\(typeSize): \(tab) and its dot wider than its column")
                }
            }
        }
    }

    // MARK: Review M3

    @MainActor
    func test_buildBannerIsDrawnOnOnboardingAndCalibration() {
        #if DEBUG
        // n3: computed inside the flows; a caller can name a replay but cannot remove the banner.
        XCTAssertEqual(OnboardingFlowView(state: .initial, actions: .noop).buildBanner?.title, "DEBUG BUILD")
        XCTAssertEqual(CalibrationFlowView(state: .unavailable, replayScenario: "steady", submit: { _ in }, close: {}).buildBanner?.title,
                       "DEBUG BUILD · REPLAY: STEADY")
        let onboarding = LayoutHarness.probe(OnboardingFlowView(state: .initial, actions: .noop), width: 390, typeSize: .large)
        XCTAssertGreaterThan(onboarding["build.banner"]?.height ?? 0, 0, "DEBUG banner missing on onboarding (pairing happens here)")
        let calibration = LayoutHarness.probe(CalibrationFlowView(state: .unavailable, submit: { _ in }, close: {}), width: 390, typeSize: .large)
        XCTAssertGreaterThan(calibration["build.banner"]?.height ?? 0, 0, "DEBUG banner missing on calibration")
        #else
        XCTAssertNil(OnboardingFlowView(state: .initial, actions: .noop).buildBanner)
        #endif
    }
}

/// The hero layout before review B1, kept only as the negative control above.
private struct LegacyHeroLayout: View {
    let value: GlucoseValue

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            Text(verbatim: GlucoseText.value(value))
                .font(NowHeroView.numberFont(value))
                .tracking(NowHeroView.numberTracking(value))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .layoutProbe("hero.number")
            VStack(alignment: .leading, spacing: 6) {
                TrendArrowView(arrow: .flat, size: 32, lineWidth: 2).frame(height: 24)
                Text(verbatim: GlucoseText.flagCaption(value) ?? GlucoseText.unit).font(Typography.label(size: 12))
            }
            .fixedSize()
        }
    }
}
