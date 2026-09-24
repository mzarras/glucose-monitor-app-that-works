// Holds the view states the screens render and receives their actions.
//
// Phase 1 (this file): DEBUG builds start from fixtures and apply simple edits locally so the UI
// can be exercised; Release builds start empty ("no sensor paired") and show onboarding. Phase 2
// replaces the bodies of the action handlers with calls into G7Kit, GlucoseStore, AlertEngine,
// TrioBridge and NightscoutKit, and updates the states from their streams. Nothing here creates a
// reading.

import Foundation
import GlucoseCore
import Observation
import WidgetCore

@MainActor
@Observable
final class AppModel {
    var selectedTab: AppTab = .now
    var now: NowViewState
    var trends: TrendsViewState
    var alerts: AlertsViewState
    var settings: SettingsViewState
    var calibration: CalibrationViewState
    /// Non-nil while onboarding is shown.
    var onboarding: OnboardingState?
    var isCalibrationPresented = false
    /// Settings sub-page to open (from a banner or the Now menu).
    var settingsRoute: SettingsRoute?

    init(now: NowViewState, trends: TrendsViewState, alerts: AlertsViewState, settings: SettingsViewState, calibration: CalibrationViewState, onboarding: OnboardingState?) {
        self.now = now
        self.trends = trends
        self.alerts = alerts
        self.settings = settings
        self.calibration = calibration
        self.onboarding = onboarding
    }

    var accent: AccentChoice { settings.accent }

    /// The state the app launches with before Phase 2 wiring.
    static func launch(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppModel {
        #if DEBUG
        // `-nowScenario stale` etc. picks a fixture (for simctl screenshots).
        var scenario = Fixtures.NowScenario.normal
        if let index = arguments.firstIndex(of: "-nowScenario"), index + 1 < arguments.count,
           let chosen = Fixtures.NowScenario(rawValue: arguments[index + 1]) {
            scenario = chosen
        }
        let current = Date()
        let model = AppModel(
            now: Fixtures.now(scenario, at: current),
            trends: Fixtures.trends(.default, at: current),
            alerts: Fixtures.alerts,
            settings: Fixtures.settings(at: current),
            calibration: Fixtures.calibration(.available, at: current),
            onboarding: arguments.contains("-onboarding") ? .initial : nil
        )
        // `-tab alerts` etc. opens a tab (for simctl screenshots).
        if let index = arguments.firstIndex(of: "-tab"), index + 1 < arguments.count,
           let tab = AppTab(rawValue: arguments[index + 1]) {
            model.selectedTab = tab
        }
        return model
        #else
        return AppModel(
            now: .empty,
            trends: .empty(period: .default),
            alerts: AlertsViewState(rows: [], sounds: [], quietHours: QuietHours(isEnabled: false, start: TimeOfDay(hour: 22, minute: 0), end: TimeOfDay(hour: 7, minute: 0))),
            settings: SettingsViewState(
                sensor: SensorSettings(state: .notPaired, serial: nil),
                trio: TrioSettings(isEnabled: false, status: .off),
                nightscout: NightscoutSettings(url: "", hasToken: false, uploadEnabled: false, status: .off),
                dexcomShare: DexcomShareSettings(isEnabled: false, username: "", hasPassword: false, region: .default, status: .off),
                delivery: AlertDeliveryStatus(notifications: .notDetermined, urgentLowAlarm: .defaultForThisOS, criticalAlerts: .entitlementNotGranted, alarmVolume: .unknown),
                lastImport: nil,
                accent: .default,
                appearance: .default,
                unit: .mgdL,
                retention: .default,
                databaseSizeBytes: nil,
                appVersion: AppIdentity.version
            ),
            calibration: .unavailable,
            onboarding: .initial
        )
        #endif
    }

    // MARK: - Navigation

    func open(_ url: URL) {
        if let tab = DeepLink.tab(for: url) { selectedTab = tab }
    }

    func perform(_ action: AppBanner.Action) {
        switch action {
        case .openAppSettings: SystemSettings.openAppSettings()
        case .openSensorSettings: openSettings(.sensor)
        case .openTrioSettings: openSettings(.trio)
        case .openSharingSettings: openSettings(.sharing)
        case .openAlertDeliverySettings: openSettings(.alertDelivery)
        case .dismissForceQuitNotice: now.health.forceQuitGap = nil
        case .pairSensor: onboarding = { var state = OnboardingState.initial; state.step = .pairing; return state }()
        case .pairAgain: openSettings(.sensor)
        case .openCalibration: isCalibrationPresented = true
        }
    }

    func openSettings(_ route: SettingsRoute) {
        selectedTab = .settings
        settingsRoute = route
    }

    // MARK: - Now

    /// Review N1: re-evaluate the clock-mismatch latch. Called by the root view's clock (every
    /// 15 s while in the foreground, like the Now screen's); Phase 2 also calls it after every new
    /// state and must carry `clockMismatchLatchedFor` over when it rebuilds `NowViewState`.
    func updateClockMismatchLatch(now date: Date) {
        let updated = now.updatingClockMismatchLatch(now: date)
        if updated.clockMismatchLatchedFor != now.clockMismatchLatchedFor {
            now = updated
            calibration.clockMismatchLatchedFor = updated.clockMismatchLatchedFor
        }
    }

    func selectChartWindow(_ window: ChartWindow) {
        now.chartWindow = window
    }

    // MARK: - Trends

    func selectTrendsPeriod(_ period: TrendsPeriod) {
        #if DEBUG
        trends = Fixtures.trends(period, at: Date())
        #else
        trends = .empty(period: period) // Phase 2: GlucoseStats for the period.
        #endif
    }

    // MARK: - Alerts (Phase 2: AlertEngine configuration)

    func updateAlert(_ kind: AlertKind, _ change: (inout AlertRow) -> Void) {
        guard let index = alerts.rows.firstIndex(where: { $0.kind == kind }) else { return }
        var row = alerts.rows[index]
        change(&row)
        // S7: urgent low stays on, sounds on silent, and snoozes at most 30 minutes, whatever the UI sent.
        if !kind.canBeDisabled { row.isEnabled = true }
        if kind.soundOnSilentIsFixed { row.soundOnSilent = true }
        if let snooze = row.snoozeMinutes { row.snoozeMinutes = min(max(snooze, 1), kind.maxSnoozeMinutes) }
        // Thresholds stay inside their limits (urgent low 50–60, …) whatever the UI sent (review m5).
        row.threshold = row.threshold?.clamped(for: kind)
        if let delay = row.delayMinutes { row.delayMinutes = min(max(delay, 0), 60) }
        alerts.rows[index] = row
    }

    func previewSound(_ soundID: String) {
        // Phase 2: AlertEngine plays the sound once.
    }

    // MARK: - Calibration (Phase 2: CalibratingCGMSource.submitCalibration)

    func submitCalibration(_ request: CalibrationRequest) {
        calibration.lastSubmission = CalibrationSubmission(request: request, outcome: .status(.queued), updatedAt: Date())
    }
}

enum SettingsRoute: Hashable, Sendable {
    case sensor
    case trio
    case sharing
    case alertDelivery
    case about
}
