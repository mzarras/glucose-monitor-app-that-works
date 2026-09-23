// Tab container: DEBUG build banner on top (every tab), the selected screen, the text tab bar.
// Onboarding covers everything while `model.onboarding` is set; calibration is a sheet.

import SwiftUI
import WidgetCore

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.now.buildBanner {
                BuildBannerView(banner: banner)
            }
            screen
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                SensorTabBar(
                    selected: model.selectedTab,
                    nowHasProblems: !model.now.banners(now: timeline.date).isEmpty,
                    select: { model.selectedTab = $0 }
                )
            }
        }
        .editorialScreen()
        .environment(\.accentChoice, model.accent)
        .tint(Theme.accentColor(model.accent, scheme: colorScheme))
        .preferredColorScheme(model.settings.appearance.colorScheme)
        .sheet(isPresented: $model.isCalibrationPresented) {
            CalibrationFlowView(state: model.calibration, submit: model.submitCalibration, close: { model.isCalibrationPresented = false })
                .environment(\.accentChoice, model.accent)
        }
        .fullScreenCover(isPresented: onboardingPresented) {
            if let onboarding = model.onboarding {
                OnboardingFlowView(state: onboarding, actions: onboardingActions)
                    .environment(\.accentChoice, model.accent)
            }
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch model.selectedTab {
        case .now:
            NowScreen(state: model.now, calibration: model.calibration, actions: nowActions)
        case .trends:
            TrendsScreen(state: model.trends, selectPeriod: model.selectTrendsPeriod)
        case .alerts:
            AlertsScreen(state: model.alerts, actions: alertsActions)
        case .settings:
            SettingsScreen(state: model.settings, calibration: model.calibration, route: $model.settingsRoute, actions: settingsActions)
        }
    }

    private var onboardingPresented: Binding<Bool> {
        Binding(get: { model.onboarding != nil }, set: { if !$0 { model.onboarding = nil } })
    }

    // MARK: Actions

    private var nowActions: NowActions {
        NowActions(
            selectChartWindow: model.selectChartWindow,
            openAlerts: { model.selectedTab = .alerts },
            openSensorSettings: { model.openSettings(.sensor) },
            openCalibration: { model.isCalibrationPresented = true },
            exportDiagnostics: {},
            pairSensor: { model.onboarding = OnboardingState.initial },
            performBannerAction: model.perform
        )
    }

    private var alertsActions: AlertsActions {
        AlertsActions(
            setEnabled: { kind, on in model.updateAlert(kind) { $0.isEnabled = on } },
            setThreshold: { kind, threshold in model.updateAlert(kind) { $0.threshold = threshold } },
            setSound: { kind, sound in model.updateAlert(kind) { $0.soundID = sound } },
            setSoundOnSilent: { kind, on in model.updateAlert(kind) { $0.soundOnSilent = on } },
            setSnooze: { kind, minutes in model.updateAlert(kind) { $0.snoozeMinutes = minutes } },
            setDelay: { kind, minutes in model.updateAlert(kind) { $0.delayMinutes = minutes } },
            previewSound: model.previewSound,
            setQuietHours: { model.alerts.quietHours = $0 }
        )
    }

    private var settingsActions: SettingsActions {
        SettingsActions(
            pair: { _ in model.onboarding = OnboardingState.initial },
            stopSession: {},
            openCalibration: { model.isCalibrationPresented = true },
            setTrioEnabled: { model.settings.trio.isEnabled = $0 },
            saveNightscout: { url, _ in model.settings.nightscout.url = url },
            setNightscoutUpload: { model.settings.nightscout.uploadEnabled = $0 },
            setShareEnabled: { model.settings.dexcomShare.isEnabled = $0 },
            saveShareCredentials: { username, _ in model.settings.dexcomShare.username = username },
            setShareRegion: { model.settings.dexcomShare.region = $0 },
            openSystemSettings: SystemSettings.openAppSettings,
            startImport: { model.onboarding = { var s = OnboardingState.initial; s.step = .importHistory; return s }() },
            exportCSV: {},
            exportDiagnostics: {},
            setAccent: { model.settings.accent = $0 },
            setAppearance: { model.settings.appearance = $0 },
            setRetention: { model.settings.retention = $0 }
        )
    }

    private var onboardingActions: OnboardingActions {
        OnboardingActions(
            goTo: { step in model.onboarding?.step = step },
            startNightscoutImport: { _, _, _ in },
            startClarityImport: { _, _ in },
            requestBluetooth: { model.onboarding?.bluetooth = .granted },
            requestNotifications: { model.onboarding?.notifications = .authorized },
            requestAlarms: { model.onboarding?.urgentLowAlarm = .authorized },
            setShareUpload: { enabled, _, _, region in
                model.onboarding?.shareUploadEnabled = enabled
                model.onboarding?.shareRegion = region
            },
            submitPairingCode: { _ in model.onboarding?.pairing = .inProgress },
            finish: { model.onboarding = nil }
        )
    }
}
