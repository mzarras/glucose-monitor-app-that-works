// Tab container: DEBUG build banner on top (every tab), the selected screen, the text tab bar.
// Onboarding covers everything while `model.onboarding` is set; calibration, Settings › Import
// history and the share sheet are sheets. Action closures call `AppModel` (docs/app-wiring.md).

import SwiftUI
import WidgetCore

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    /// The UI clock's grid start, fixed for the view's life: a schedule rebuilt `from: .now` on every
    /// render would hand the timeline a new date on every state change, and a tick that changes state
    /// (the Predict tab's "now" moves every tick, D57) would then re-render forever.
    @State private var clockStart = Date()

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.now.buildBanner {
                BuildBannerView(banner: banner)
            }
            screen
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The UI clock: every 15 s the latch is re-evaluated (S5) and the tab dots follow the
            // banners, which the screens classify against `model.clock`, and the Settings state
            // (D55: alarm volume), which every `.alertDelivery` change rebuilds.
            TimelineView(.periodic(from: clockStart, by: 15)) { timeline in
                SensorTabBar(
                    selected: model.selectedTab,
                    attention: model.tabsNeedingAttention(),
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
                OnboardingFlowView(state: onboarding, actions: onboardingActions, replayScenario: model.now.replayScenario,
                                   pairingContext: model.onboardingPairingContext)
                    .environment(\.accentChoice, model.accent)
            }
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch model.selectedTab {
        case .now:
            NowScreen(state: model.now, calibration: model.calibration, actions: nowActions, clock: model.clock)
        case .predict:
            PredictScreen(state: model.predict, actions: predictActions)
        case .trends:
            TrendsScreen(state: model.trends, selectPeriod: { model.selectTrendsPeriod($0) })
        case .settings:
            SettingsScreen(state: model.settings, calibration: model.calibration, alerts: model.alerts, route: $model.settingsRoute,
                           actions: settingsActions, alertsActions: alertsActions, hasStoredSensor: model.hasStoredSensor)
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
            openAlerts: { model.openAlerts() },
            openSensorSettings: { model.openSettings(.sensor) },
            openCalibration: { model.isCalibrationPresented = true },
            exportDiagnostics: { model.exportDiagnostics() },
            pairSensor: { model.perform(.pairSensor) },
            pairAgain: { model.perform(.pairAgain) },
            performBannerAction: { model.perform($0) }
        )
    }

    private var predictActions: PredictActions {
        PredictActions(
            openSettings: { model.openPredictionsSettings() },
            appeared: { model.predictTabAppeared() },
            refresh: { model.tick() }
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
        withDeveloperActions(SettingsActions(
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
            setRetention: { model.setRetention($0) },
            setConnectionMode: { model.setConnectionMode($0) },
            setPacketRecording: { model.setPacketRecording($0) },
            setPredictionsEnabled: { model.setPredictionsEnabled($0) },
            savePredictionsHost: { model.savePredictionsHost($0) }
        ))
    }

    /// DEBUG builds: the Developer page's replay controls (D11, D20). Release: unchanged (m5).
    private func withDeveloperActions(_ base: SettingsActions) -> SettingsActions {
        #if DEBUG
        var actions = base
        actions.startReplay = { model.startReplay(scenario: $0, speed: $1) }
        actions.stopReplay = { model.stopReplay() }
        actions.setDeveloperLiveOutputs = { model.setDeveloperLiveOutputs($0) }
        return actions
        #else
        return base
        #endif
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
            cancelImport: { model.cancelImport() },
            dismiss: { model.dismissOnboarding() },
            chooseConnection: { model.chooseOnboardingConnection($0) },
            continueConnection: { model.continueFromConnectionStep() }
        )
    }
}
