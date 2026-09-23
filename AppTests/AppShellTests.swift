import UIKit
import WidgetCore
import XCTest
@testable import Sensor

final class AppShellTests: XCTestCase {
    /// PROGRESS D19: a DEBUG build always shows the build banner; Release never compiles it.
    func test_buildBannerIsShownInEveryDebugBuild() {
        #if DEBUG
        let banner = BuildBanner.forThisBuild(replayScenario: nil)
        XCTAssertNotNil(banner)
        XCTAssertEqual(banner?.title, "DEBUG BUILD")
        XCTAssertEqual(BuildBanner.forThisBuild(replayScenario: "steady")?.title, "DEBUG BUILD · REPLAY: STEADY")
        // Computed from the view state, so no state can clear it.
        XCTAssertNotNil(NowViewState.empty.buildBanner)
        #else
        XCTAssertNil(BuildBanner.forThisBuild(replayScenario: nil))
        #endif
    }

    func test_bundledFontsAreRegistered() {
        for name in Typography.FontName.all {
            XCTAssertNotNil(UIFont(name: name, size: 12), "\(name) missing: check UIAppFonts and Resources/Fonts")
        }
    }

    func test_fontLicensesShipInTheBundle() {
        for name in ["Newsreader-OFL", "IBMPlex-OFL"] {
            let url = Bundle.main.url(forResource: name, withExtension: "txt")
            XCTAssertNotNil(url, name)
            let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            XCTAssertTrue(text.contains("SIL Open Font License"), name)
        }
    }

    func test_widgetDeepLinkOpensNow() {
        XCTAssertEqual(DeepLink.tab(for: URL(string: "com.mzarras.sensor://now")!), .now)
        XCTAssertNil(DeepLink.tab(for: URL(string: "com.mzarras.sensor://other")!))
        let schemes = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])?
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] } ?? []
        XCTAssertFalse(schemes.isEmpty, "the app registers the widget's URL scheme")
    }

    func test_appNameComesFromOneSetting() {
        XCTAssertFalse(AppIdentity.displayName.isEmpty)
        XCTAssertFalse(AppIdentity.displayName.localizedCaseInsensitiveContains("dexcom"), "no trademark in the app name")
    }

    func test_pairingCode() {
        XCTAssertEqual(PairingCode.sanitize("12a3456"), "1234")
        XCTAssertEqual(PairingCode.sanitize("１２３４"), "", "full-width digits are not the sensor's code")
        XCTAssertTrue(PairingCode.isComplete("0042"))
        XCTAssertFalse(PairingCode.isComplete("123"))
        XCTAssertFalse(PairingCode.isComplete("12345"))
    }

    func test_onboardingDefaults() {
        let initial = OnboardingState.initial
        XCTAssertTrue(initial.shareUploadEnabled, "D7: Share upload offered on")
        XCTAssertEqual(initial.shareRegion, .us, "D7: US preselected")
        XCTAssertEqual(OnboardingStep.allCases.first, .welcome)
        XCTAssertEqual(OnboardingStep.allCases.last, .warmUp)
        XCTAssertEqual(DataRetention.default, .twoYears)
        XCTAssertEqual(AppearancePreference.default, .system)
        XCTAssertNil(AppearancePreference.system.colorScheme)
        let progress = ImportProgress(origin: .nightscout, readingsImported: 12_408, covered: DateInterval(start: minutes(-13 * 1_440), end: t0), isFinished: false, errorMessage: nil)
        XCTAssertEqual(OnboardingText.importProgress(progress, context: testContext), "12,408 readings imported · Sep 10 – Sep 23")
    }

    func test_settingsText() {
        XCTAssertTrue(SettingsText.criticalAlerts(.entitlementNotGranted).note.hasPrefix("Optional."))
        XCTAssertEqual(SettingsText.notifications(.denied).status, "Off")
        XCTAssertEqual(SettingsText.alarmVolume(.tooLow(level: 0.15)), "15% — too low")
    }
}
