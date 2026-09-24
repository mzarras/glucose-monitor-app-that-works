// Tab container: DEBUG build banner on top (every tab), the selected screen, the text tab bar.
// Onboarding covers everything while `model.onboarding` is set; calibration, Settings › Import
// history and the share sheet are sheets. Action closures call `AppModel` (docs/app-wiring.md).

import SwiftUI
import WidgetCore

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.now.buildBanner {
                BuildBannerView(banner: banner)
                    .accessibilityIdentifier("build.banner")
            }
            screen
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The UI clock: every 15 s the latch is re-evaluated (S5) and the tab dot follows the
            // banners, which the screens classify against `model.clock`.
            TimelineView(.periodic(from: .now, by: 15)) { timeline in
                SensorTabBar(
                    selected: model.selectedTab,
                    nowHasProblems: !model.now.banners(now: model.clock()).isEmpty,
                    select: { model.selectTab($0) }
                )
                .onChange(of: timeline.date, initial: true) { _, _ in
                    model.tick()
                }
            }
        }
        .editorialScreen()
        .environment(\.accentChoice, model.accent)
        .tint(Theme.accentColor(model.accent, scheme: colorScheme))
        .preferredColorScheme(model.settings.appearance.colorScheme)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.tick() }
        }
        .sheet(isPresented: $model.isCalibrationPresented) {
            CalibrationFlowView(state: model.calibration, replayScenario: model.now.replayScenario, submit: { model.submitCalibration($0) }, close: { model.isCalibrationPresented = false })
                .environment(\.accentChoice, model.accent)
        }
        .sheet(item: $model.sharedFile) { file in
            ActivityView(url: file.url)
        }
        .sheet(isPresented: importPresented) {
            if let state = model.importSheet {
                ImportHistorySheet(state: state, actions: onboardingActions, close: { model.importSheet = nil })
                    .environment(\.accentChoice, model.accent)
            }
        }
        .fullScreenCover(isPresented: onboardingPresented) {
            if let onboarding = model.onboarding {
                OnboardingFlowView(state: onboarding, actions: onboardingActions, replayScenario: model.now.replayScenario)
                    .environment(\.accentChoice, model.accent)
            }
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch model.selectedTab {
        case .now:
            NowScreen(state: model.now, calibration: model.calibration, actions: nowActions, clock: model.clock)
        case .trends:
            TrendsScreen(state: model.trends, selectPeriod: { model.selectTrendsPeriod($0) })
        case .alerts:
            AlertsScreen(state: model.alerts, actions: alertsActions)
        case .settings:
            SettingsScreen(state: model.settings, calibration: model.calibration, route: $model.settingsRoute, actions: settingsActions)
        }
    }

    private var onboardingPresented: Binding<Bool> {
        Binding(get: { model.onboarding != nil }, set: { if !$0 { model.onboarding = nil } })
    }

    private var importPresented: Binding<Bool> {
        Binding(get: { model.importSheet != nil }, set: { if !$0 { model.importSheet = nil } })
    }

    // MARK: Actions (closures wrap the model's methods: IRGen crash with bare method references)

    private var nowActions: NowActions {
        NowActions(
            selectChartWindow: { model.selectChartWindow($0) },
            openAlerts: { model.selectTab(.alerts) },
            openSensorSettings: { model.openSettings(.sensor) },
            openCalibration: { model.isCalibrationPresented = true },
            exportDiagnostics: { model.exportDiagnostics() },
            pairSensor: { model.presentOnboarding(at: .pairing) },
            pairAgain: { model.perform(.pairAgain) },
            performBannerAction: { model.perform($0) }
        )
    }

    private var alertsActions: AlertsActions {
        AlertsActions(
            edit: { model.editAlert($0) },
            previewSound: { model.previewSound($0) },
            stopSoundPreview: { model.stopSoundPreview() }
        )
    }

    private var settingsActions: SettingsActions {
        var actions = SettingsActions(
            pair: { model.pairNewSensor(code: $0) },
            pairAgain: { model.pairSensorAgain(code: $0) },
            forgetSensor: { model.forgetSensor() },
            stopSession: {}, // hidden: no source supports it (`canStopSession`, OPEN QUESTIONS)
            openCalibration: { model.isCalibrationPresented = true },
            setTrioEnabled: { model.setTrioEnabled($0) },
            saveNightscout: { model.saveNightscout(url: $0, token: $1) },
            setNightscoutUpload: { model.setNightscoutUpload($0) },
            retryUploads: { model.retryUploads() },
            setShareEnabled: { model.setShareEnabled($0) },
            saveShareCredentials: { model.saveShareCredentials(accountName: $0, password: $1, receiverSerialNumber: $2) },
            setShareRegion: { model.setShareRegion($0) },
            openSystemSettings: { SystemSettings.openAppSettings() },
            requestNotifications: { model.requestNotifications() },
            requestUrgentLowAlarm: { model.requestUrgentLowAlarm() },
            refreshStatus: { model.refreshSettingsSummaries() },
            startImport: { model.presentImport() },
            exportCSV: { model.exportAllReadings() },
            exportDiagnostics: { model.exportDiagnostics() },
            setAccent: { model.setAccent($0) },
            setAppearance: { model.setAppearance($0) },
            setRetention: { model.setRetention($0) }
        )
        #if DEBUG
        actions.startReplay = { model.startReplay(scenario: $0, speed: $1) }
        actions.stopReplay = { model.stopReplay() }
        actions.setDeveloperLiveOutputs = { model.setDeveloperLiveOutputs($0) }
        #endif
        return actions
    }

    private var onboardingActions: OnboardingActions {
        OnboardingActions(
            goTo: { model.goToOnboardingStep($0) },
            startNightscoutImport: { model.startNightscoutImport(url: $0, token: $1, depth: $2) },
            startClarityImport: { model.startClarityImport(file: $0, timeZone: $1) },
            requestBluetooth: { SystemSettings.openAppSettings() },
            requestNotifications: { model.requestNotifications() },
            requestAlarms: { model.requestUrgentLowAlarm() },
            setShareUpload: { model.finishDexcomStep(shareEnabled: $0, accountName: $1, password: $2, receiverSerialNumber: $3, region: $4) },
            submitPairingCode: { model.pairNewSensor(code: $0) },
            pairAgain: { model.pairSensorAgain(code: $0) },
            finish: { model.finishOnboarding() },
            cancelImport: { model.cancelImport() }
        )
    }
}
