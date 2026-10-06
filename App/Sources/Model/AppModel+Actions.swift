// What the screens' action closures do (RootView builds the closures from these). Each calls the
// facade; the view states then follow from the `ServiceChange` it sends back (AppModel.apply).
// Errors the facade reports are shown next to the control that caused them.

import AlertEngine
import Foundation
import GlucoseCore
import NightscoutKit
import WidgetCore

extension AppModel {
    // MARK: - Navigation and banners

    func open(_ url: URL) {
        if let tab = DeepLink.tab(for: url) { selectTab(tab) }
    }

    func perform(_ action: AppBanner.Action) {
        switch action {
        case .openAppSettings: SystemSettings.openAppSettings()
        case .openSensorSettings: openSettings(.sensor)
        case .openTrioSettings: openSettings(.trio)
        case .openSharingSettings: openSettings(.sharing)
        case .openAlertDeliverySettings: openSettings(.alertDelivery)
        case .dismissForceQuitNotice:
            now.health.forceQuitGap = nil
            services?.dismissForceQuitGap()
        // Review M1: in-app pairing is a Settings page (with the tab bar and the S5 banners one tap
        // away), never the full-screen onboarding, whose only exit is finishing a pairing.
        case .pairSensor: openSettings(.sensor)
        case .pairAgain: openSettings(.sensor)
        case .openCalibration: isCalibrationPresented = true
        case .requestNotifications: requestNotifications()
        case .requestUrgentLowAlarm: requestUrgentLowAlarm()
        }
    }

    func openSettings(_ route: SettingsRoute) {
        selectTab(.settings)
        settingsRoute = route
    }

    // MARK: - Now

    func selectChartWindow(_ window: ChartWindow) {
        now.chartWindow = window
    }

    // MARK: - Alerts (S7: AlertsMapping writes through AlertEngine's clamping settings)

    /// Applies one Alerts-screen edit. Edits made before the facade confirms the previous one build
    /// on it (`alertSettingsDraft`), so quick successive edits are never lost.
    func editAlert(_ edit: AlertEdit) {
        guard let services else {
            fixtureAlertSettings = AlertsMapping.apply(edit, to: fixtureAlertSettings)
            alerts = AlertsMapping.make(fixtureAlertSettings)
            return
        }
        let updated = AlertsMapping.apply(edit, to: alertSettingsDraft ?? services.alertSettings)
        alertSettingsDraft = updated
        alerts = AlertsMapping.make(updated)
        let previous = alertUpdate
        alertUpdate = track { [weak self] in
            await previous?.value
            await services.updateAlertSettings(updated)
            guard let self, self.alertSettingsDraft == updated else { return }
            self.alertSettingsDraft = nil
            self.alerts = AlertsMapping.make(services.alertSettings) // what the engine stored
        }
    }

    /// Plays the sound once; false (nothing played) while an alert's sound is playing.
    func previewSound(_ sound: AlertSoundID) -> Bool {
        services?.previewSound(sound) ?? true
    }

    func stopSoundPreview() {
        services?.stopSoundPreview()
    }

    // MARK: - Calibration (PROGRESS D16; never a reading, S1)

    func submitCalibration(_ request: CalibrationRequest) {
        guard let services else {
            calibration.lastSubmission = CalibrationSubmission(request: request, outcome: .status(.queued), updatedAt: Date())
            return
        }
        track { [weak self] in
            do throws(CalibrationRefusal) {
                try await services.submitCalibration(request)
            } catch {
                // Normally also in `recentCalibrations`; shown at once either way.
                self?.calibration.lastSubmission = CalibrationSubmission(request: request, outcome: .refused(error), updatedAt: self?.clock() ?? Date())
            }
        }
    }

    // MARK: - Sensor

    /// Pairs a new sensor (new-sensor flow).
    func pairNewSensor(code: String) { startPairing(code: code, again: false) }

    /// Pairs the worn sensor again (D37: `pairAgain(code:)`, via PairingGuidance's offer).
    func pairSensorAgain(code: String) { startPairing(code: code, again: true) }

    private func startPairing(code: String, again: Bool) {
        guard let services else { return }
        pairingInProgress = true
        pairingSawConnectionStep = false
        settings.sensor.pairingInProgress = true
        settings.feedback.pairing = nil
        if onboarding != nil {
            onboarding?.pairing = .inProgress
            // An exact baseline only: before the source's stored record is read, `hasStoredSensor`
            // is a default (Phase 3, `storedSensorKnown`).
            if !again, hadStoredSensorAtPairingStart == nil, services.storedSensorKnown {
                hadStoredSensorAtPairingStart = services.hasStoredSensor
            }
        }
        track { [weak self] in
            do throws(PairingError) {
                if again {
                    try await services.pairAgain(code: code)
                } else {
                    try await services.pair(code: code)
                }
            } catch {
                let text = OnboardingMapping.pairingErrorText(error)
                guard let self else { return }
                self.pairingInProgress = false
                self.settings.sensor.pairingInProgress = false
                self.settings.feedback.pairing = text
                if self.onboarding != nil { self.onboarding?.pairing = .couldNotStart(text) }
            }
        }
    }

    func forgetSensor() {
        guard let services else { return }
        track { await services.forgetSensor() }
    }

    // MARK: - Connection mode (D45) and packet recording (D47)

    /// Settings › Sensor, after the page's confirmation. The view states follow the `.sensor`
    /// change the facade sends; a refusal (nothing changed) is shown under the choices. Choosing the
    /// mode the facade is already in (a new install's `.pair`) only records the choice.
    func setConnectionMode(_ mode: SensorConnectionMode) {
        guard let services else {
            settings.connection = ConnectionModeState(mode: mode)
            return
        }
        settings.feedback.connection = nil
        // While the setting can't be trusted (review m2/m3) the choice is recorded even for the mode
        // shown: the services rewrite it and start the sensor connection.
        guard services.connectionMode != mode || services.connectionSettingProblem != nil else {
            noteConnectionModeChosen()
            return
        }
        settings.connectionSwitchingTo = mode
        track { [weak self] in
            do throws(ConnectionModeError) {
                try await services.setConnectionMode(mode)
                self?.noteConnectionModeChosen()
            } catch {
                self?.settings.feedback.connection = ConnectionModeText.errorText(error)
            }
            self?.settings.connectionSwitchingTo = nil
        }
    }

    func setPacketRecording(_ enabled: Bool) {
        guard let services else {
            settings.packetRecording = PacketRecordingState(isOn: enabled)
            return
        }
        track { await services.setRecordsRawGlucosePackets(enabled) }
    }

    /// Onboarding's connection step: the choice is only remembered here; Continue applies it.
    /// Listening offers no Dexcom Share upload by default (D7's default is for pairing mode).
    func chooseOnboardingConnection(_ mode: SensorConnectionMode) {
        guard onboarding != nil else { return }
        onboarding?.connection = ConnectionModeState(mode: mode)
        onboarding?.connectionMessage = nil
        onboarding?.shareUploadEnabled = mode == .pair
    }

    /// Continue on the connection step: switches the facade to the chosen mode if it differs, then
    /// moves on; a refusal stays on the step with its reason (nothing changed).
    func continueFromConnectionStep() {
        guard let chosen = onboarding?.connection?.mode else { return }
        let next = onboarding?.step(after: .connection) ?? .importHistory
        guard let services, services.connectionMode != chosen else {
            noteConnectionModeChosen()
            goToOnboardingStep(next)
            return
        }
        onboarding?.connectionMessage = nil
        onboarding?.connectionSwitching = true
        track { [weak self] in
            do throws(ConnectionModeError) {
                try await services.setConnectionMode(chosen)
                self?.noteConnectionModeChosen()
                self?.onboarding?.connectionSwitching = false
                self?.goToOnboardingStep(next)
            } catch {
                self?.onboarding?.connectionSwitching = false
                self?.onboarding?.connectionMessage = ConnectionModeText.errorText(error)
            }
        }
    }

    // MARK: - Trio

    func setTrioEnabled(_ enabled: Bool) {
        guard let services else { settings.trio.isEnabled = enabled; return }
        track { await services.setTrioBridgeEnabled(enabled) }
    }

    // MARK: - Sharing (HANDOFF §8A)

    func saveNightscout(url: String, token: String?) {
        guard let services else { return }
        settings.feedback.nightscout = nil
        track { [weak self] in
            do throws(ServiceConfigurationError) {
                try await services.saveNightscout(url: url, token: token)
                self?.settings.feedback.nightscout = "Saved."
            } catch {
                self?.settings.feedback.nightscout = Self.configurationErrorText(error)
            }
        }
    }

    func setNightscoutUpload(_ enabled: Bool) {
        guard let services else { return }
        track { await services.setNightscoutUploadEnabled(enabled) }
    }

    func setShareEnabled(_ enabled: Bool) {
        guard let services else { return }
        track { await services.setDexcomShareEnabled(enabled) }
    }

    func saveShareCredentials(accountName: String, password: String?, receiverSerialNumber: String) {
        guard let services else { return }
        settings.feedback.dexcomShare = nil
        track { [weak self] in
            do throws(ServiceConfigurationError) {
                try await services.saveDexcomShare(accountName: accountName, password: password, receiverSerialNumber: receiverSerialNumber)
                self?.settings.feedback.dexcomShare = "Saved."
            } catch {
                self?.settings.feedback.dexcomShare = Self.configurationErrorText(error)
            }
        }
    }

    func setShareRegion(_ region: ShareRegion) {
        guard let services else { return }
        track { await services.setDexcomShareRegion(region) }
    }

    func retryUploads() {
        guard let services else { return }
        track { await services.retryUploads() }
    }

    static func configurationErrorText(_ error: ServiceConfigurationError) -> String {
        switch error {
        case .invalidNightscoutURL: return "That isn't a valid https:// address for a Nightscout site."
        case .nightscoutNotConfigured: return "Save a Nightscout site first."
        case .incompleteDexcomShareCredentials: return "Enter the account name, password and receiver serial number."
        case .keychain(let message): return "The Keychain refused to save it: \(message)"
        }
    }

    // MARK: - Alert delivery (D4, D17, D26)

    func requestNotifications() {
        guard let services else { return }
        track { await services.requestNotificationAuthorization() }
    }

    func requestUrgentLowAlarm() {
        guard let services else { return }
        track { await services.requestUrgentLowAlarmAuthorization() }
    }

    /// Settings shows fresh permission, volume and database figures.
    func refreshSettingsSummaries() {
        guard let services else { return }
        track {
            await services.refreshAlertDelivery()
            await services.refreshStorageSummary()
        }
    }

    // MARK: - Data (HANDOFF §4.5, §11 step 6)

    func exportAllReadings() {
        export { try await $0.exportAllReadingsCSV() }
    }

    func exportDiagnostics() {
        export { try await $0.exportDiagnostics() }
    }

    private func export(_ make: @escaping @MainActor (any AppServices) async throws -> URL) {
        guard let services else { return }
        settings.feedback.export = nil
        track { [weak self] in
            do {
                let url = try await make(services)
                self?.sharedFile = SharedFile(url: url)
            } catch {
                self?.settings.feedback.export = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func setRetention(_ retention: DataRetention) {
        guard let services else { settings.retention = retention; return }
        track { await services.setRetention(retention) }
    }

    // MARK: - Appearance

    func setAccent(_ accent: AccentChoice) {
        guard let services else { settings.accent = accent; return }
        services.setAccent(accent)
    }

    /// Light/dark is the app's own setting (widgets follow the system).
    func setAppearance(_ appearance: AppearancePreference) {
        settings.appearance = appearance
        if preferencesLoaded { preferences?.appearance = appearance }
    }

    // MARK: - History import (HANDOFF §4.5; charts and stats only, S6)

    /// Nightscout import. With a URL (and token) typed in, saves the site first; with the fields left
    /// empty, imports from the saved site.
    func startNightscoutImport(url: String, token: String, depth: ImportDepth) {
        guard let services else { return }
        let scope: NightscoutImportScope = depth == .everything ? .everything : .lastDays(90)
        updateImportForms { $0.nightscoutMessage = nil }
        track { [weak self] in
            let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedURL.isEmpty {
                do throws(ServiceConfigurationError) {
                    try await services.saveNightscout(url: trimmedURL, token: token.isEmpty ? nil : token)
                } catch {
                    self?.updateImportForms { $0.nightscoutMessage = Self.configurationErrorText(error) }
                    return
                }
            }
            services.startNightscoutImport(scope: scope)
        }
    }

    /// Clarity CSV from the Files app (`.fileImporter`), recorded in `timeZone`.
    func startClarityImport(file: URL, timeZone: TimeZone) {
        guard let services else { return }
        updateImportForms { $0.nightscoutMessage = nil }
        track { [weak self] in
            let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                let scoped = file.startAccessingSecurityScopedResource()
                defer { if scoped { file.stopAccessingSecurityScopedResource() } }
                return try? Data(contentsOf: file)
            }.value
            guard let data else {
                self?.updateImportForms { $0.nightscoutMessage = "The file couldn't be read." }
                return
            }
            services.startClarityImport(fileData: data, timeZone: timeZone)
        }
    }

    func cancelImport() {
        services?.cancelHistoryImport()
    }

    // MARK: - Onboarding

    func goToOnboardingStep(_ step: OnboardingStep) {
        onboarding?.step = step
    }

    /// The Dexcom step: Share upload on (D7, US preselected) saves the credentials, sets the region
    /// and turns upload on, then moves on; off turns upload off. A save failure stays on the step.
    func finishDexcomStep(shareEnabled: Bool, accountName: String, password: String, receiverSerialNumber: String, region: ShareRegion) {
        guard let services else { goToOnboardingStep(.permissions); return }
        onboarding?.shareUploadEnabled = shareEnabled
        onboarding?.shareRegion = region
        onboarding?.shareMessage = nil
        track { [weak self] in
            if shareEnabled {
                do throws(ServiceConfigurationError) {
                    try await services.saveDexcomShare(accountName: accountName, password: password.isEmpty ? nil : password,
                                                       receiverSerialNumber: receiverSerialNumber)
                } catch {
                    self?.onboarding?.shareMessage = Self.configurationErrorText(error)
                    return
                }
                await services.setDexcomShareRegion(region)
            }
            await services.setDexcomShareEnabled(shareEnabled)
            self?.goToOnboardingStep(.permissions)
        }
    }

    func finishOnboarding() {
        onboarding = nil
        hadStoredSensorAtPairingStart = nil
        if preferencesLoaded { preferences?.onboardingCompleted = true }
    }

    /// "Set up later" (review M1): onboarding can always be left. It is not marked completed, so it
    /// is offered again at the next launch while no sensor is set up; Settings › Sensor pairs any time.
    func dismissOnboarding() {
        onboarding = nil
        hadStoredSensorAtPairingStart = nil
    }

    // MARK: - DEBUG replay (D11, D19, D20)

    #if DEBUG
    func startReplay(scenario: String, speed: Double) {
        guard let services else { return }
        track { await services.startReplay(scenario: scenario, speed: speed) }
    }

    func stopReplay() {
        guard let services else { return }
        track { await services.stopReplay() }
    }

    func setDeveloperLiveOutputs(_ enabled: Bool) {
        guard let services else { return }
        track { await services.setDeveloperLiveOutputsEnabled(enabled) }
    }
    #endif
}
