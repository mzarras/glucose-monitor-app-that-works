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

    @MainActor
    func test_tabTitlesNeverClipOrWrapAtAccessibilitySizes() {
        for typeSize in typeSizes {
            let width: CGFloat = 375
            let sizes = LayoutHarness.probe(SensorTabBar(selected: .settings, nowHasProblems: true, select: { _ in }), width: width, typeSize: typeSize)
            for tab in AppTab.allCases {
                guard let title = sizes["tab.title.\(tab.rawValue)"] else {
                    XCTFail("\(typeSize): \(tab) not rendered")
                    continue
                }
                let font = Typography.body(size: 13, weight: tab == .settings ? .semibold : .regular)
                let ideal = LayoutHarness.idealSize(Text(verbatim: tab.title).font(font), typeSize: min(typeSize, SensorTabBar.maxTypeSize))
                XCTAssertGreaterThanOrEqual(title.width + 0.5, ideal.width, "\(typeSize): \(tab) clipped")
                XCTAssertLessThanOrEqual(title.height, ideal.height + 0.5, "\(typeSize): \(tab) wrapped")
                XCTAssertLessThanOrEqual(title.width, width / 4, "\(typeSize): \(tab) wider than its column")
            }
        }
    }

    // MARK: Review M3

    @MainActor
    func test_buildBannerIsDrawnOnOnboardingAndCalibration() {
        #if DEBUG
        let onboarding = LayoutHarness.probe(OnboardingFlowView(state: .initial, actions: .noop), width: 390, typeSize: .large)
        XCTAssertGreaterThan(onboarding["build.banner"]?.height ?? 0, 0, "DEBUG banner missing on onboarding (pairing happens here)")
        let calibration = LayoutHarness.probe(CalibrationFlowView(state: .unavailable, submit: { _ in }, close: {}), width: 390, typeSize: .large)
        XCTAssertGreaterThan(calibration["build.banner"]?.height ?? 0, 0, "DEBUG banner missing on calibration")
        #else
        XCTAssertNil(OnboardingFlowView(state: .initial, actions: .noop).buildBanner)
        #endif
    }
}
