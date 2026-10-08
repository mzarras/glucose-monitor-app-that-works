import AlertEngine
import SwiftUI
import UIKit
import XCTest
@testable import Sensor

/// D56 (tab bar "Now · Predict · Trends · Settings", Alerts in Settings) and D55 (alarm volume marks
/// the Settings tab, not Now). The live `.alertDelivery` path is
/// AppModelWiringTests.test_alarmVolumeNoticeAndSettingsDotFollowEveryDeliveryChange; the pages
/// themselves are driven in SensorUITests (`test_settingsAlertsAndThePredictTab`).
@MainActor
final class NavigationTests: XCTestCase {
    private func launch(_ arguments: [String]) -> AppModel {
        let preferences = AppUIPreferences(defaults: UserDefaults(suiteName: "NavigationTests.\(UUID().uuidString)")!)
        preferences.onboardingCompleted = true
        return AppModel.launch(services: PreviewAppServices(sensorState: activeSensor), arguments: arguments, preferences: preferences,
                               calendar: utcCalendar, clock: { t0 }, protectedDataAvailable: { true })
    }

    // MARK: Tabs

    func test_tabBarIsNowPredictTrendsSettings() {
        XCTAssertEqual(AppTab.allCases, [.now, .predict, .trends, .settings])
        XCTAssertEqual(AppTab.allCases.map(\.title), ["Now", "Predict", "Trends", "Settings"])
        XCTAssertNil(AppTab(rawValue: "alerts"), "no Alerts tab")
    }

    /// `-tab <tab>` opens each tab; the old `-tab alerts` opens Settings › Alerts; anything else
    /// leaves Now. Same in the DEBUG fixture model.
    func test_tabLaunchArgument() {
        for tab in AppTab.allCases {
            let model = launch(["-tab", tab.rawValue])
            XCTAssertEqual(model.selectedTab, tab)
            XCTAssertNil(model.settingsRoute, "\(tab)")
        }
        let alerts = launch(["-tab", "alerts"])
        XCTAssertEqual(alerts.selectedTab, .settings)
        XCTAssertEqual(alerts.settingsRoute, .alerts)
        XCTAssertEqual(launch(["-tab", "nonsense"]).selectedTab, .now)
        XCTAssertEqual(launch(["-tab"]).selectedTab, .now)
        XCTAssertEqual(launch([]).selectedTab, .now, "a cold launch opens Now")

        #if DEBUG
        let fixture = AppModel.fixtures(arguments: ["-tab", "alerts"])
        XCTAssertEqual(fixture.selectedTab, .settings)
        XCTAssertEqual(fixture.settingsRoute, .alerts)
        XCTAssertEqual(AppModel.fixtures(arguments: ["-tab", "predict"]).selectedTab, .predict)
        #endif
    }

    /// Now's header sound button (NowActions.openAlerts → `openAlerts()`) lands on Settings › Alerts,
    /// from any tab.
    func test_nowAlertsShortcutOpensSettingsAlerts() {
        let model = launch([])
        for tab in AppTab.allCases {
            model.selectTab(tab)
            model.settingsRoute = nil
            model.openAlerts()
            XCTAssertEqual(model.selectedTab, .settings, "from \(tab)")
            XCTAssertEqual(model.settingsRoute, .alerts, "from \(tab)")
        }
    }

    // MARK: D55 attention

    func test_tabAttentionIsAPureFunctionOfTheState() {
        let fine = Fixtures.settings(at: t0)
        let volumeLow = Fixtures.settingsVolumeLow(at: t0)
        let banner = AppBanner(kind: .missedReadings, severity: .critical, title: "t", detail: "d", action: nil, actionTitle: nil)
        XCTAssertEqual(TabAttention.tabs(nowBanners: [], settings: fine), [])
        XCTAssertEqual(TabAttention.tabs(nowBanners: [], settings: volumeLow), [.settings])
        XCTAssertEqual(TabAttention.tabs(nowBanners: [banner], settings: fine), [.now])
        XCTAssertEqual(TabAttention.tabs(nowBanners: [banner], settings: volumeLow), [.now, .settings])
        var unknown = fine
        unknown.delivery.alarmVolume = .unknown
        XCTAssertEqual(TabAttention.tabs(nowBanners: [], settings: unknown), [], "not measured yet is not a problem to show")
    }

    /// The real tab bar inside RootView follows a Settings change without anything else happening
    /// (no relaunch, no clock tick): the dot is drawn once the volume becomes too low. The model's
    /// `.alertDelivery` handling, which makes that change, is AppModelWiringTests'.
    func test_settingsTabDotFollowsTheSettingsStateInRootView() {
        #if DEBUG
        let model = AppModel.fixtures()
        XCTAssertFalse(model.settings.needsAttention)
        var reported: Set<String> = []
        let root = RootView(model: model)
            .environment(\.layoutProbe, LayoutProbe { name, _ in reported.insert(name) })
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(reported.contains("tab.title.settings"), "the tab bar rendered")
        XCTAssertFalse(reported.contains("tab.dot.settings"), "no dot while the volume is fine")

        model.settings.delivery.alarmVolume = .tooLow(level: 0.1)
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(reported.contains("tab.dot.settings"), "the dot appears when the state changes")
        #endif
    }

    func test_alarmVolumeNotice() {
        XCTAssertEqual(SettingsText.alarmVolumeNotice(.tooLow(level: 0.15)), "Alarm volume 15%. Alarms may be hard to hear; turn the volume up.")
        XCTAssertEqual(SettingsText.alarmVolumeNotice(.tooLow(level: 0)), "Alarm volume 0%. Alarms may be hard to hear; turn the volume up.")
        XCTAssertNil(SettingsText.alarmVolumeNotice(.ok(level: 0.25)))
        XCTAssertNil(SettingsText.alarmVolumeNotice(.unknown))
        // The limit is AlertEngine's (ServiceHealthMapping.alarmVolume): below 25 % only.
        XCTAssertNotNil(SettingsText.alarmVolumeNotice(ServiceHealthMapping.alarmVolume(0.249)))
        XCTAssertNil(SettingsText.alarmVolumeNotice(ServiceHealthMapping.alarmVolume(AlertLimits.lowAlarmVolume)))
        XCTAssertNil(SettingsText.alarmVolumeNotice(ServiceHealthMapping.alarmVolume(nil)))
        // The Settings row keeps its red value with the same source.
        XCTAssertTrue(Fixtures.settingsVolumeLow(at: t0).needsAttention)
        XCTAssertEqual(SettingsText.alarmVolume(Fixtures.settingsVolumeLow(at: t0).delivery.alarmVolume), "15% — too low")
    }

    func test_tabAccessibilityLabelSaysWhenATabNeedsAttention() {
        XCTAssertEqual(SensorTabBar.accessibilityLabel(.settings, needsAttention: true), "Settings, needs attention")
        XCTAssertEqual(SensorTabBar.accessibilityLabel(.now, needsAttention: true), "Now, needs attention")
        XCTAssertEqual(SensorTabBar.accessibilityLabel(.predict, needsAttention: false), "Predict")
    }

    // MARK: Settings › Alerts row

    /// Hand-built rows: urgent low counts as on even if its stored flag is off (S7).
    func test_alertsRowSummary() {
        let rows = [
            AlertRow(kind: .urgentLow, isEnabled: false, threshold: nil, soundID: AlertSoundCatalog.defaultSound(for: .urgentLow), soundOnSilent: true),
            AlertRow(kind: .low, isEnabled: true, threshold: nil, soundID: AlertSoundCatalog.defaultSound(for: .low), soundOnSilent: true),
            AlertRow(kind: .high, isEnabled: false, threshold: nil, soundID: AlertSoundCatalog.defaultSound(for: .high), soundOnSilent: false),
        ]
        var state = AlertsViewState(rows: rows, sounds: [], quietHours: QuietHours(isEnabled: false, startMinuteOfDay: 22 * 60, endMinuteOfDay: 7 * 60))
        XCTAssertEqual(AlertsText.settingsSummary(state), "2 of 3 on · quiet hours off")
        state.rows[2].isEnabled = true
        state.quietHours.isEnabled = true
        XCTAssertEqual(AlertsText.settingsSummary(state), "all 3 on · quiet hours 10 PM – 7 AM")
        // The engine's defaults, as the running app maps them.
        let defaults = AlertsMapping.make(.defaults)
        let on = defaults.rows.filter(\.effectiveIsEnabled).count
        XCTAssertEqual(AlertsText.settingsSummary(defaults), "\(on) of \(defaults.rows.count) on · quiet hours off")
    }

    /// The Predict placeholder never shows a number (S1: a forecast is never a reading; D57).
    func test_predictPlaceholderShowsNoNumber() {
        XCTAssertFalse(PredictContent.placeholder.contains { $0.isNumber })
    }
}
