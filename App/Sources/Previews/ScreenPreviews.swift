// SwiftUI previews for every screen state, light and dark (HANDOFF §9.3 WS5). DEBUG only: they
// use Fixtures. Generated once by hand-run script; edit freely.

#if DEBUG
import GlucoseCore
import SwiftUI
import WidgetCore

/// Screen background, scrolling, and a fixed colour scheme for a preview.
private struct PreviewScreen<Content: View>: View {
    let scheme: ColorScheme
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView { content }
            .editorialScreen()
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(scheme)
    }
}

private let previewNow = Date()

// MARK: - Now

#Preview("Now · normal · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.normal, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · normal · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.normal, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · low · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.low, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · low · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.low, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · high · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.high, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · high · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.high, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · lowFlag · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.lowFlag, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · lowFlag · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.lowFlag, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · highFlag · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.highFlag, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · highFlag · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.highFlag, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · stale · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.stale, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · stale · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.stale, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · noData · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.noData, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · noData · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.noData, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · warmUp · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.warmUp, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · warmUp · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.warmUp, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · expired · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.expired, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · expired · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.expired, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · bluetoothOff · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.bluetoothOff, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · bluetoothOff · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.bluetoothOff, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · trioFailing · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.trioFailing, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · trioFailing · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.trioFailing, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · sensorError · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.sensorError, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · sensorError · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.sensorError, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · notPaired · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.notPaired, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · notPaired · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.notPaired, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · manyProblems · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.manyProblems, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · manyProblems · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.manyProblems, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }

// MARK: - Trends

#Preview("Trends · oneDay · light") { PreviewScreen(scheme: .light) { TrendsContent(state: Fixtures.trends(.oneDay, at: previewNow), selectPeriod: { _ in }) } }
#Preview("Trends · oneDay · dark") { PreviewScreen(scheme: .dark) { TrendsContent(state: Fixtures.trends(.oneDay, at: previewNow), selectPeriod: { _ in }) } }
#Preview("Trends · threeDays · light") { PreviewScreen(scheme: .light) { TrendsContent(state: Fixtures.trends(.threeDays, at: previewNow), selectPeriod: { _ in }) } }
#Preview("Trends · threeDays · dark") { PreviewScreen(scheme: .dark) { TrendsContent(state: Fixtures.trends(.threeDays, at: previewNow), selectPeriod: { _ in }) } }
#Preview("Trends · sevenDays · light") { PreviewScreen(scheme: .light) { TrendsContent(state: Fixtures.trends(.sevenDays, at: previewNow), selectPeriod: { _ in }) } }
#Preview("Trends · sevenDays · dark") { PreviewScreen(scheme: .dark) { TrendsContent(state: Fixtures.trends(.sevenDays, at: previewNow), selectPeriod: { _ in }) } }
#Preview("Trends · fourteenDays · light") { PreviewScreen(scheme: .light) { TrendsContent(state: Fixtures.trends(.fourteenDays, at: previewNow), selectPeriod: { _ in }) } }
#Preview("Trends · fourteenDays · dark") { PreviewScreen(scheme: .dark) { TrendsContent(state: Fixtures.trends(.fourteenDays, at: previewNow), selectPeriod: { _ in }) } }
#Preview("Trends · thirtyDays · light") { PreviewScreen(scheme: .light) { TrendsContent(state: Fixtures.trends(.thirtyDays, at: previewNow), selectPeriod: { _ in }) } }
#Preview("Trends · thirtyDays · dark") { PreviewScreen(scheme: .dark) { TrendsContent(state: Fixtures.trends(.thirtyDays, at: previewNow), selectPeriod: { _ in }) } }
#Preview("Trends · ninetyDays · light") { PreviewScreen(scheme: .light) { TrendsContent(state: Fixtures.trends(.ninetyDays, at: previewNow), selectPeriod: { _ in }) } }
#Preview("Trends · ninetyDays · dark") { PreviewScreen(scheme: .dark) { TrendsContent(state: Fixtures.trends(.ninetyDays, at: previewNow), selectPeriod: { _ in }) } }
#Preview("Trends · no data · light") { PreviewScreen(scheme: .light) { TrendsContent(state: .empty(period: .fourteenDays), selectPeriod: { _ in }) } }
#Preview("Trends · no data · dark") { PreviewScreen(scheme: .dark) { TrendsContent(state: .empty(period: .fourteenDays), selectPeriod: { _ in }) } }

// MARK: - Alerts

#Preview("Alerts · list · light") { NavigationStack { PreviewScreen(scheme: .light) { AlertsContent(state: Fixtures.alerts, actions: .noop) } } }
#Preview("Alerts · urgent low detail · light") { NavigationStack { AlertDetailView(row: Fixtures.alerts.row(.urgentLow)!, sounds: Fixtures.sounds, actions: .noop).environment(\.colorScheme, .light).preferredColorScheme(.light) } }
#Preview("Alerts · high detail · light") { NavigationStack { AlertDetailView(row: Fixtures.alerts.row(.high)!, sounds: Fixtures.sounds, actions: .noop).environment(\.colorScheme, .light).preferredColorScheme(.light) } }
#Preview("Alerts · list · dark") { NavigationStack { PreviewScreen(scheme: .dark) { AlertsContent(state: Fixtures.alerts, actions: .noop) } } }
#Preview("Alerts · urgent low detail · dark") { NavigationStack { AlertDetailView(row: Fixtures.alerts.row(.urgentLow)!, sounds: Fixtures.sounds, actions: .noop).environment(\.colorScheme, .dark).preferredColorScheme(.dark) } }
#Preview("Alerts · high detail · dark") { NavigationStack { AlertDetailView(row: Fixtures.alerts.row(.high)!, sounds: Fixtures.sounds, actions: .noop).environment(\.colorScheme, .dark).preferredColorScheme(.dark) } }

// MARK: - Settings

#Preview("Settings · light") { NavigationStack { PreviewScreen(scheme: .light) { SettingsContent(state: Fixtures.settings(at: previewNow), now: previewNow, actions: .noop) } } }
#Preview("Settings · problems · light") { NavigationStack { PreviewScreen(scheme: .light) { SettingsContent(state: Fixtures.settingsWithProblems(at: previewNow), now: previewNow, actions: .noop) } } }
#Preview("Settings · sensor, not paired · light") { NavigationStack { SensorSettingsView(sensor: SensorSettings(state: .notPaired, serial: nil), calibration: .unavailable, actions: .noop).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) } }
#Preview("Settings · sensor, active · light") { NavigationStack { SensorSettingsView(sensor: Fixtures.settings(at: previewNow).sensor, calibration: Fixtures.calibration(.accepted, at: previewNow), actions: .noop).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) } }
#Preview("Settings · sharing · light") { NavigationStack { SharingSettingsView(nightscout: Fixtures.settingsWithProblems(at: previewNow).nightscout, share: Fixtures.settings(at: previewNow).dexcomShare, actions: .noop).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) } }
#Preview("Settings · Trio failing · light") { NavigationStack { TrioSettingsView(trio: Fixtures.settingsWithProblems(at: previewNow).trio, setEnabled: { _ in }).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) } }
#Preview("Settings · alert delivery, problems · light") { NavigationStack { AlertDeliveryView(delivery: Fixtures.settingsWithProblems(at: previewNow).delivery, actions: .noop).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) } }
#Preview("Settings · alert delivery · light") { NavigationStack { AlertDeliveryView(delivery: Fixtures.settings(at: previewNow).delivery, actions: .noop).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) } }
#Preview("Settings · about · light") { NavigationStack { AboutView(version: "0.1.0 (1)").editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) } }
#Preview("Settings · dark") { NavigationStack { PreviewScreen(scheme: .dark) { SettingsContent(state: Fixtures.settings(at: previewNow), now: previewNow, actions: .noop) } } }
#Preview("Settings · problems · dark") { NavigationStack { PreviewScreen(scheme: .dark) { SettingsContent(state: Fixtures.settingsWithProblems(at: previewNow), now: previewNow, actions: .noop) } } }
#Preview("Settings · sensor, not paired · dark") { NavigationStack { SensorSettingsView(sensor: SensorSettings(state: .notPaired, serial: nil), calibration: .unavailable, actions: .noop).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) } }
#Preview("Settings · sensor, active · dark") { NavigationStack { SensorSettingsView(sensor: Fixtures.settings(at: previewNow).sensor, calibration: Fixtures.calibration(.accepted, at: previewNow), actions: .noop).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) } }
#Preview("Settings · sharing · dark") { NavigationStack { SharingSettingsView(nightscout: Fixtures.settingsWithProblems(at: previewNow).nightscout, share: Fixtures.settings(at: previewNow).dexcomShare, actions: .noop).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) } }
#Preview("Settings · Trio failing · dark") { NavigationStack { TrioSettingsView(trio: Fixtures.settingsWithProblems(at: previewNow).trio, setEnabled: { _ in }).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) } }
#Preview("Settings · alert delivery, problems · dark") { NavigationStack { AlertDeliveryView(delivery: Fixtures.settingsWithProblems(at: previewNow).delivery, actions: .noop).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) } }
#Preview("Settings · alert delivery · dark") { NavigationStack { AlertDeliveryView(delivery: Fixtures.settings(at: previewNow).delivery, actions: .noop).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) } }
#Preview("Settings · about · dark") { NavigationStack { AboutView(version: "0.1.0 (1)").editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) } }

// MARK: - Onboarding

#Preview("Onboarding · welcome · light") { OnboardingContent(state: Fixtures.onboarding(.welcome, at: previewNow), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Onboarding · welcome · dark") { OnboardingContent(state: Fixtures.onboarding(.welcome, at: previewNow), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Onboarding · importHistory · light") { OnboardingContent(state: Fixtures.onboarding(.importHistory, at: previewNow), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Onboarding · importHistory · dark") { OnboardingContent(state: Fixtures.onboarding(.importHistory, at: previewNow), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Onboarding · removeDexcomApp · light") { OnboardingContent(state: Fixtures.onboarding(.removeDexcomApp, at: previewNow), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Onboarding · removeDexcomApp · dark") { OnboardingContent(state: Fixtures.onboarding(.removeDexcomApp, at: previewNow), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Onboarding · permissions · light") { OnboardingContent(state: Fixtures.onboarding(.permissions, at: previewNow), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Onboarding · permissions · dark") { OnboardingContent(state: Fixtures.onboarding(.permissions, at: previewNow), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Onboarding · pairing · light") { OnboardingContent(state: Fixtures.onboarding(.pairing, at: previewNow), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Onboarding · pairing · dark") { OnboardingContent(state: Fixtures.onboarding(.pairing, at: previewNow), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Onboarding · warmUp · light") { OnboardingContent(state: Fixtures.onboarding(.warmUp, at: previewNow), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Onboarding · warmUp · dark") { OnboardingContent(state: Fixtures.onboarding(.warmUp, at: previewNow), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Onboarding · import failed · light") { OnboardingContent(state: { var o = Fixtures.onboarding(.importHistory, at: previewNow); o.importProgress?.errorMessage = "Nightscout returned HTTP 401."; return o }(), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Onboarding · pairing in progress · light") { OnboardingContent(state: { var o = Fixtures.onboarding(.pairing, at: previewNow); o.pairing = .inProgress; return o }(), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Onboarding · import failed · dark") { OnboardingContent(state: { var o = Fixtures.onboarding(.importHistory, at: previewNow); o.importProgress?.errorMessage = "Nightscout returned HTTP 401."; return o }(), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Onboarding · pairing in progress · dark") { OnboardingContent(state: { var o = Fixtures.onboarding(.pairing, at: previewNow); o.pairing = .inProgress; return o }(), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) }

// MARK: - Calibration

private enum CalibrationPreviews {
    static let takenAt = previewNow.addingTimeInterval(-60)
    static let request = Fixtures.calibration(.pending, at: previewNow).lastSubmission!.request
}

#Preview("Calibration · entry · light") { CalibrationFlowView(state: Fixtures.calibration(.available, at: previewNow), initialFlow: CalibrationFlow(step: .entry, entryText: "112"), submit: { _ in }, close: {}).environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Calibration · entry · dark") { CalibrationFlowView(state: Fixtures.calibration(.available, at: previewNow), initialFlow: CalibrationFlow(step: .entry, entryText: "112"), submit: { _ in }, close: {}).environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Calibration · entry, out of range · light") { CalibrationFlowView(state: Fixtures.calibration(.available, at: previewNow), initialFlow: CalibrationFlow(step: .entry, entryText: "612"), submit: { _ in }, close: {}).environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Calibration · entry, out of range · dark") { CalibrationFlowView(state: Fixtures.calibration(.available, at: previewNow), initialFlow: CalibrationFlow(step: .entry, entryText: "612"), submit: { _ in }, close: {}).environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Calibration · mismatch · light") { CalibrationFlowView(state: Fixtures.calibration(.available, at: previewNow), initialFlow: CalibrationFlow(step: .confirm(value: 112, takenAt: CalibrationPreviews.takenAt), confirmText: "121"), submit: { _ in }, close: {}).environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Calibration · mismatch · dark") { CalibrationFlowView(state: Fixtures.calibration(.available, at: previewNow), initialFlow: CalibrationFlow(step: .confirm(value: 112, takenAt: CalibrationPreviews.takenAt), confirmText: "121"), submit: { _ in }, close: {}).environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Calibration · big difference · light") { CalibrationFlowView(state: Fixtures.calibration(.available, at: previewNow), initialFlow: CalibrationFlow(step: .largeDifference(value: 155, takenAt: CalibrationPreviews.takenAt, difference: .large(sensorMgdl: 105, difference: 50, limit: 21))), submit: { _ in }, close: {}).environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Calibration · big difference · dark") { CalibrationFlowView(state: Fixtures.calibration(.available, at: previewNow), initialFlow: CalibrationFlow(step: .largeDifference(value: 155, takenAt: CalibrationPreviews.takenAt, difference: .large(sensorMgdl: 105, difference: 50, limit: 21))), submit: { _ in }, close: {}).environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Calibration · sensor reads LOW · light") { CalibrationFlowView(state: Fixtures.calibration(.available, at: previewNow), initialFlow: CalibrationFlow(step: .largeDifference(value: 52, takenAt: CalibrationPreviews.takenAt, difference: .sensorFlag(.belowRange))), submit: { _ in }, close: {}).environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Calibration · sensor reads LOW · dark") { CalibrationFlowView(state: Fixtures.calibration(.available, at: previewNow), initialFlow: CalibrationFlow(step: .largeDifference(value: 52, takenAt: CalibrationPreviews.takenAt, difference: .sensorFlag(.belowRange))), submit: { _ in }, close: {}).environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Calibration · pending · light") { CalibrationFlowView(state: Fixtures.calibration(.pending, at: previewNow), initialFlow: CalibrationFlow(step: .submitted(CalibrationPreviews.request)), submit: { _ in }, close: {}).environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Calibration · pending · dark") { CalibrationFlowView(state: Fixtures.calibration(.pending, at: previewNow), initialFlow: CalibrationFlow(step: .submitted(CalibrationPreviews.request)), submit: { _ in }, close: {}).environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Calibration · accepted · light") { CalibrationFlowView(state: Fixtures.calibration(.accepted, at: previewNow), initialFlow: CalibrationFlow(step: .submitted(CalibrationPreviews.request)), submit: { _ in }, close: {}).environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Calibration · accepted · dark") { CalibrationFlowView(state: Fixtures.calibration(.accepted, at: previewNow), initialFlow: CalibrationFlow(step: .submitted(CalibrationPreviews.request)), submit: { _ in }, close: {}).environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Calibration · rejected · light") { CalibrationFlowView(state: Fixtures.calibration(.rejected, at: previewNow), initialFlow: CalibrationFlow(step: .submitted(CalibrationPreviews.request)), submit: { _ in }, close: {}).environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Calibration · rejected · dark") { CalibrationFlowView(state: Fixtures.calibration(.rejected, at: previewNow), initialFlow: CalibrationFlow(step: .submitted(CalibrationPreviews.request)), submit: { _ in }, close: {}).environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Calibration · unknown · light") { CalibrationFlowView(state: Fixtures.calibration(.unknown, at: previewNow), initialFlow: CalibrationFlow(step: .submitted(CalibrationPreviews.request)), submit: { _ in }, close: {}).environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Calibration · unknown · dark") { CalibrationFlowView(state: Fixtures.calibration(.unknown, at: previewNow), initialFlow: CalibrationFlow(step: .submitted(CalibrationPreviews.request)), submit: { _ in }, close: {}).environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Calibration · disabled in warm-up · light") { CalibrationFlowView(state: Fixtures.calibration(.warmingUp, at: previewNow), initialFlow: CalibrationFlow(), submit: { _ in }, close: {}).environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Calibration · disabled in warm-up · dark") { CalibrationFlowView(state: Fixtures.calibration(.warmingUp, at: previewNow), initialFlow: CalibrationFlow(), submit: { _ in }, close: {}).environment(\.colorScheme, .dark).preferredColorScheme(.dark) }

// MARK: - Banners and app shell

#Preview("Build banner · light") { VStack(spacing: 0) { BuildBannerView(banner: BuildBanner.forThisBuild(replayScenario: nil)!); BuildBannerView(banner: BuildBanner.forThisBuild(replayScenario: "slow fall to urgent low")!); Spacer() }.editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("App · light") { RootView(model: AppModel.fixtures()).environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Build banner · dark") { VStack(spacing: 0) { BuildBannerView(banner: BuildBanner.forThisBuild(replayScenario: nil)!); BuildBannerView(banner: BuildBanner.forThisBuild(replayScenario: "slow fall to urgent low")!); Spacer() }.editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("App · dark") { RootView(model: AppModel.fixtures()).environment(\.colorScheme, .dark).preferredColorScheme(.dark) }

// MARK: - D26 alarms, D27 quiet hours, D23 scrubbing

#Preview("Onboarding · alarms · light") { OnboardingContent(state: Fixtures.onboarding(.alarms, at: previewNow), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Onboarding · alarms denied · light") { OnboardingContent(state: { var o = Fixtures.onboarding(.alarms, at: previewNow); o.urgentLowAlarm = .denied; return o }(), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Settings · alert delivery, alarms unavailable · light") { NavigationStack { AlertDeliveryView(delivery: AlertDeliveryStatus(notifications: .authorized, urgentLowAlarm: .unavailable, criticalAlerts: .entitlementNotGranted, alarmVolume: .ok(level: 0.6)), actions: .noop).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) } }
#Preview("Alerts · quiet hours on · light") { NavigationStack { PreviewScreen(scheme: .light) { AlertsContent(state: { var a = Fixtures.alerts; a.quietHours.isEnabled = true; return a }(), actions: .noop) } } }
#Preview("Chart · scrubbing a reading · light") { ScrubPreview(minutesBack: 40).environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Chart · scrubbing a gap · light") { ScrubPreview(minutesBack: 60 * 10 + 5, window: .twelveHours).environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Chart · scrubbing LOW · light") { ScrubPreview(minutesBack: 6, scenario: .lowFlag).environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Onboarding · alarms · dark") { OnboardingContent(state: Fixtures.onboarding(.alarms, at: previewNow), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Onboarding · alarms denied · dark") { OnboardingContent(state: { var o = Fixtures.onboarding(.alarms, at: previewNow); o.urgentLowAlarm = .denied; return o }(), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Settings · alert delivery, alarms unavailable · dark") { NavigationStack { AlertDeliveryView(delivery: AlertDeliveryStatus(notifications: .authorized, urgentLowAlarm: .unavailable, criticalAlerts: .entitlementNotGranted, alarmVolume: .ok(level: 0.6)), actions: .noop).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) } }
#Preview("Alerts · quiet hours on · dark") { NavigationStack { PreviewScreen(scheme: .dark) { AlertsContent(state: { var a = Fixtures.alerts; a.quietHours.isEnabled = true; return a }(), actions: .noop) } } }
#Preview("Chart · scrubbing a reading · dark") { ScrubPreview(minutesBack: 40).environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Chart · scrubbing a gap · dark") { ScrubPreview(minutesBack: 60 * 10 + 5, window: .twelveHours).environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Chart · scrubbing LOW · dark") { ScrubPreview(minutesBack: 6, scenario: .lowFlag).environment(\.colorScheme, .dark).preferredColorScheme(.dark) }

/// The Now chart with the finger held at `minutesBack` minutes before now.
struct ScrubPreview: View {
    var minutesBack: Double
    var window: ChartWindow = .threeHours
    var scenario: Fixtures.NowScenario = .normal

    var body: some View {
        let state = Fixtures.now(scenario, at: previewNow)
        GlucoseTraceChart(
            points: state.chartPoints,
            domain: previewNow.addingTimeInterval(-window.duration)...previewNow,
            latestLive: state.latestLiveReading.map { ChartPoint(date: $0.date, value: $0.value) },
            options: NowContent.chartOptions(window),
            accessibilityTitle: window.spokenName,
            initialScrubDate: previewNow.addingTimeInterval(-minutesBack * 60)
        )
        .frame(height: 200)
        .padding(20)
        .editorialScreen()
    }
}

// MARK: - Review fixes: accessibility sizes, clock mismatch, retype

#Preview("Now · lowFlag · AX5 · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.lowFlag, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) }.environment(\.dynamicTypeSize, .accessibility5) }
#Preview("Now · highFlag · AX5 · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.highFlag, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) }.environment(\.dynamicTypeSize, .accessibility5) }
#Preview("Now · normal · AX5 · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.normal, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) }.environment(\.dynamicTypeSize, .accessibility5) }
#Preview("Calibration · retype, value hidden · light") { CalibrationFlowView(state: Fixtures.calibration(.available, at: previewNow), initialFlow: CalibrationFlow(step: .confirm(value: 112, takenAt: CalibrationPreviews.takenAt), confirmText: "1"), submit: { _ in }, close: {}).environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Calibration · retype matches · light") { CalibrationFlowView(state: Fixtures.calibration(.available, at: previewNow), initialFlow: CalibrationFlow(step: .confirm(value: 112, takenAt: CalibrationPreviews.takenAt), confirmText: "112"), submit: { _ in }, close: {}).environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Now · lowFlag · AX5 · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.lowFlag, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) }.environment(\.dynamicTypeSize, .accessibility5) }
#Preview("Now · highFlag · AX5 · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.highFlag, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) }.environment(\.dynamicTypeSize, .accessibility5) }
#Preview("Now · normal · AX5 · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.normal, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) }.environment(\.dynamicTypeSize, .accessibility5) }
#Preview("Calibration · retype, value hidden · dark") { CalibrationFlowView(state: Fixtures.calibration(.available, at: previewNow), initialFlow: CalibrationFlow(step: .confirm(value: 112, takenAt: CalibrationPreviews.takenAt), confirmText: "1"), submit: { _ in }, close: {}).environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Calibration · retype matches · dark") { CalibrationFlowView(state: Fixtures.calibration(.available, at: previewNow), initialFlow: CalibrationFlow(step: .confirm(value: 112, takenAt: CalibrationPreviews.takenAt), confirmText: "112"), submit: { _ in }, close: {}).environment(\.colorScheme, .dark).preferredColorScheme(.dark) }

// MARK: - D36: structured sensor failures, calibration states

#Preview("Now · transientFailure · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.transientFailure, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · pairingRejected · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.pairingRejected, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · sensorEnded · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.sensorEnded, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · calibrationNeeded · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.calibrationNeeded, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Onboarding · pairing pairingRejected · light") { OnboardingContent(state: { var o = Fixtures.onboarding(.pairing, at: previewNow); o.pairing = .failed(Fixtures.pairingFailure(.pairingRejected)); return o }(), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Onboarding · pairing bluetoothPairingIncomplete · light") { OnboardingContent(state: { var o = Fixtures.onboarding(.pairing, at: previewNow); o.pairing = .failed(Fixtures.pairingFailure(.bluetoothPairingIncomplete)); return o }(), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Onboarding · pairing pairingCodeNeeded · light") { OnboardingContent(state: { var o = Fixtures.onboarding(.pairing, at: previewNow); o.pairing = .failed(Fixtures.pairingFailure(.pairingCodeNeeded)); return o }(), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Settings · sensor, pair again · light") { NavigationStack { SensorSettingsView(sensor: SensorSettings(state: .failed(Fixtures.pairingFailure(.bondRemoved)), serial: "SAMPLE0001"), calibration: .unavailable, actions: .noop, hasStoredSensor: true).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) } }
#Preview("Now · transientFailure · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.transientFailure, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · pairingRejected · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.pairingRejected, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · sensorEnded · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.sensorEnded, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · calibrationNeeded · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.calibrationNeeded, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Onboarding · pairing pairingRejected · dark") { OnboardingContent(state: { var o = Fixtures.onboarding(.pairing, at: previewNow); o.pairing = .failed(Fixtures.pairingFailure(.pairingRejected)); return o }(), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Onboarding · pairing bluetoothPairingIncomplete · dark") { OnboardingContent(state: { var o = Fixtures.onboarding(.pairing, at: previewNow); o.pairing = .failed(Fixtures.pairingFailure(.bluetoothPairingIncomplete)); return o }(), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Onboarding · pairing pairingCodeNeeded · dark") { OnboardingContent(state: { var o = Fixtures.onboarding(.pairing, at: previewNow); o.pairing = .failed(Fixtures.pairingFailure(.pairingCodeNeeded)); return o }(), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Settings · sensor, pair again · dark") { NavigationStack { SensorSettingsView(sensor: SensorSettings(state: .failed(Fixtures.pairingFailure(.bondRemoved)), serial: "SAMPLE0001"), calibration: .unavailable, actions: .noop, hasStoredSensor: true).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) } }
#Preview("Alerts · calibration needed detail · light") { NavigationStack { AlertDetailView(row: Fixtures.alerts.row(.calibrationNeeded)!, sounds: Fixtures.sounds, actions: .noop).environment(\.colorScheme, .light).preferredColorScheme(.light) } }
#Preview("Alerts · calibration needed detail · dark") { NavigationStack { AlertDetailView(row: Fixtures.alerts.row(.calibrationNeeded)!, sounds: Fixtures.sounds, actions: .noop).environment(\.colorScheme, .dark).preferredColorScheme(.dark) } }

// MARK: - D36/D37 review: pair again, sensor problem, calibration through a clock mismatch

#Preview("Now · sensorProblem · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.sensorProblem, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · calibrationThenClockMismatch · light") { PreviewScreen(scheme: .light) { NowContent(state: Fixtures.now(.calibrationThenClockMismatch, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Settings · sensor, pairingRejected · light") { NavigationStack { SensorSettingsView(sensor: SensorSettings(state: .failed(Fixtures.pairingFailure(.pairingRejected)), serial: "SAMPLE0001", failureSince: nil), calibration: .unavailable, actions: .noop, hasStoredSensor: true).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) } }
#Preview("Settings · sensor, pairingCodeNeeded · light") { NavigationStack { SensorSettingsView(sensor: SensorSettings(state: .failed(Fixtures.pairingFailure(.pairingCodeNeeded)), serial: "SAMPLE0001", failureSince: nil), calibration: .unavailable, actions: .noop, hasStoredSensor: true).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) } }
#Preview("Settings · sensor, credentialsUnavailable · light") { NavigationStack { SensorSettingsView(sensor: SensorSettings(state: .failed(Fixtures.pairingFailure(.credentialsUnavailable)), serial: "SAMPLE0001", failureSince: previewNow.addingTimeInterval(-40 * 60)), calibration: .unavailable, actions: .noop).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) } }
#Preview("Onboarding · pairing unsupportedSensor · light") { OnboardingContent(state: { var o = Fixtures.onboarding(.pairing, at: previewNow); o.pairing = .failed(Fixtures.pairingFailure(.unsupportedSensor)); return o }(), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Onboarding · pairing bondRemoved · light") { OnboardingContent(state: { var o = Fixtures.onboarding(.pairing, at: previewNow); o.pairing = .failed(Fixtures.pairingFailure(.bondRemoved)); return o }(), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Now · sensorProblem · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.sensorProblem, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Now · calibrationThenClockMismatch · dark") { PreviewScreen(scheme: .dark) { NowContent(state: Fixtures.now(.calibrationThenClockMismatch, at: previewNow), calibration: Fixtures.calibration(.available, at: previewNow), now: previewNow, actions: .noop) } }
#Preview("Settings · sensor, pairingRejected · dark") { NavigationStack { SensorSettingsView(sensor: SensorSettings(state: .failed(Fixtures.pairingFailure(.pairingRejected)), serial: "SAMPLE0001", failureSince: nil), calibration: .unavailable, actions: .noop, hasStoredSensor: true).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) } }
#Preview("Settings · sensor, pairingCodeNeeded · dark") { NavigationStack { SensorSettingsView(sensor: SensorSettings(state: .failed(Fixtures.pairingFailure(.pairingCodeNeeded)), serial: "SAMPLE0001", failureSince: nil), calibration: .unavailable, actions: .noop, hasStoredSensor: true).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) } }
#Preview("Settings · sensor, credentialsUnavailable · dark") { NavigationStack { SensorSettingsView(sensor: SensorSettings(state: .failed(Fixtures.pairingFailure(.credentialsUnavailable)), serial: "SAMPLE0001", failureSince: previewNow.addingTimeInterval(-40 * 60)), calibration: .unavailable, actions: .noop).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) } }
#Preview("Onboarding · pairing unsupportedSensor · dark") { OnboardingContent(state: { var o = Fixtures.onboarding(.pairing, at: previewNow); o.pairing = .failed(Fixtures.pairingFailure(.unsupportedSensor)); return o }(), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Onboarding · pairing bondRemoved · dark") { OnboardingContent(state: { var o = Fixtures.onboarding(.pairing, at: previewNow); o.pairing = .failed(Fixtures.pairingFailure(.bondRemoved)); return o }(), actions: .noop, now: previewNow).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#Preview("Onboarding · pairing rejected after authentication · light") { OnboardingContent(state: { var o = Fixtures.onboarding(.pairing, at: previewNow); o.pairing = .failed(Fixtures.pairingFailure(.pairingRejected)); return o }(), actions: .noop, now: previewNow, pairingContext: PairingContext(hasStoredSensor: true, isNewPairing: true, authenticatedInThisPairing: true)).editorialScreen().environment(\.colorScheme, .light).preferredColorScheme(.light) }
#Preview("Onboarding · pairing rejected after authentication · dark") { OnboardingContent(state: { var o = Fixtures.onboarding(.pairing, at: previewNow); o.pairing = .failed(Fixtures.pairingFailure(.pairingRejected)); return o }(), actions: .noop, now: previewNow, pairingContext: PairingContext(hasStoredSensor: true, isNewPairing: true, authenticatedInThisPairing: true)).editorialScreen().environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
#endif
