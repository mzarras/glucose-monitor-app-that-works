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

    /// p5-nav review m1: the "Alarm volume" row is red from the volume alone, never from the tab's
    /// dot, and the dot is built from named causes. Predictions add no cause (D57: a forecast
    /// problem is not a safety problem), so failing or switched-off predictions leave both alone.
    func test_alarmVolumeRowFollowsTheVolumeAloneAndTheDotItsNamedCauses() {
        var fine = Fixtures.settings(at: t0)
        fine.delivery.alarmVolume = .ok(level: 0.6)
        XCTAssertFalse(fine.alarmVolumeIsTooLow, "60 %: the row is not red")
        XCTAssertEqual(fine.attentionCauses, [])
        XCTAssertFalse(fine.needsAttention)

        for scenario in [PredictFixtures.Scenario.failingNothingHeld, .failingWithRun, .turnedOff, .notConfigured, .stale] {
            var withPredictions = fine
            withPredictions.predictions = PredictFixtures.settings(scenario, at: t0)
            withPredictions.feedback.predictions = "That is not a valid host name."
            XCTAssertEqual(withPredictions.attentionCauses, [], "\(scenario): no Settings attention for predictions")
            XCTAssertFalse(withPredictions.alarmVolumeIsTooLow, "\(scenario): the volume row stays as the volume says (60 %)")
        }

        let low = Fixtures.settingsVolumeLow(at: t0)
        XCTAssertTrue(low.alarmVolumeIsTooLow)
        XCTAssertEqual(low.attentionCauses, [.alarmVolumeTooLow])
        XCTAssertTrue(low.needsAttention)
        XCTAssertEqual(SettingsAttentionCause.allCases, [.alarmVolumeTooLow], "a new cause needs its own row and its own test here")
    }

    /// The RootView render-loop fix (`@State clockStart`, docs/app-wiring.md). Every tick here changes
    /// the Predict state (a clock that moves on every read moves the chart's "now"). With a 15 s
    /// timeline rebuilt `from: .now` on each render, that re-rendered and ticked forever (the app froze
    /// on Predict); with a fixed grid start the first render ticks once or twice and settles.
    func test_rootViewClockSettlesWhenATickChangesState() {
        let services = PreviewAppServices(sensorState: activeSensor)
        services.forecast = ForecastTestDocuments.status(latest: ForecastTestDocuments.decodedLatest(run: minutes(-3), now: t0))
        let clock = AdvancingClock(t0)
        let preferences = AppUIPreferences(defaults: UserDefaults(suiteName: "NavigationTests.\(UUID().uuidString)")!)
        preferences.onboardingCompleted = true
        let model = AppModel.launch(services: services, arguments: ["-tab", "predict"], preferences: preferences, calendar: utcCalendar,
                                    clock: { clock.read() }, protectedDataAvailable: { true })
        let host = UIHostingController(rootView: RootView(model: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        XCTAssertNotNil(model.predict.forecast, "the Predict tab rendered a forecast")
        let ticks = services.calls.filter { $0 == "updateClockMismatchLatch" }.count
        print("RootView clock: \(ticks) ticks in 2 s")
        XCTAssertGreaterThanOrEqual(ticks, 1, "the UI clock ticked")
        // Fixed grid start: 2 ticks measured. With `from: .now` this host measured 9–12 and rising.
        XCTAssertLessThanOrEqual(ticks, 4, "the UI clock settles instead of re-rendering and ticking forever (\(ticks) ticks in 2 s)")
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

    /// The Predict tab shows forecast numbers only for a current run (S1, D57; every state is in
    /// PredictMappingTests): not set up, off, waiting, out of date, no run and unavailable show none.
    func test_predictTabShowsNumbersOnlyForACurrentRun() {
        for scenario in PredictFixtures.Scenario.allCases {
            let state = PredictFixtures.state(scenario, at: t0, context: testContext)
            switch scenario {
            case .current, .currentWithoutReading, .clippedLow, .clippedHigh, .failingWithRun:
                XCTAssertNotNil(state.forecast, "\(scenario)")
            case .stale, .aheadOfClock, .noRunYet, .waiting, .failingNothingHeld, .notConfigured, .turnedOff:
                XCTAssertNil(state.forecast, "\(scenario)")
                XCTAssertTrue(state.chart?.forecast.isEmpty ?? true, "\(scenario): no forecast line")
            }
        }
    }
}

/// A clock that moves one second forward on every read.
@MainActor
private final class AdvancingClock {
    private var now: Date
    init(_ start: Date) { now = start }
    func read() -> Date {
        now = now.addingTimeInterval(1)
        return now
    }
}
