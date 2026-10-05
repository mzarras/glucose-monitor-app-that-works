// Alerts in the live services (docs/alerts.md §9): settings, delivery status and permissions,
// sound preview, in-app and notification actions, the AlarmKit Stop intent bridge, and the Trio
// bridge status input. Imports AlertEngine but not TrioBridge: `TrioBridgeStatus` here is
// AlertEngine's alert input.

import AlertEngine
import Foundation
import GlucoseCore

extension AlertDeliveryReport {
    /// The delivery status `service` reports now. (AlertEngine's `AlertDeliveryStatus` cannot be
    /// named in the app target, which has its own view-state type of that name.)
    @MainActor
    init(of service: AlertService) {
        let status = service.deliveryStatus
        self.init(permissions: status.permissions, outputVolume: status.outputVolume, urgentLowAlarm: status.urgentLowAlarm, problems: status.problems)
    }
}

extension LiveAppServices {
    func updateAlertSettings(_ settings: AlertSettings) async {
        if let alerts = activeAlerts {
            await alerts.send(.settings(settings))
            alertSettings = alerts.settings
        } else {
            alertSettings = settings
        }
        // Persisted as the engine holds them (clamped, S7). During a replay run the production
        // service is rebuilt from these when the run ends.
        preferences.alertSettings = alertSettings
        send(.alertSettings)
    }

    func refreshAlertDelivery() async {
        guard let alerts = activeAlerts else { return }
        _ = await alerts.refreshDeliveryStatus()
        alertDelivery = AlertDeliveryReport(of: alerts)
        send(.alertDelivery)
    }

    func requestNotificationAuthorization() async {
        guard let alerts = activeAlerts else { return }
        _ = await alerts.requestAuthorization()
        alertDelivery = AlertDeliveryReport(of: alerts)
        send(.alertDelivery)
    }

    func requestUrgentLowAlarmAuthorization() async {
        guard let alerts = activeAlerts else { return }
        _ = await alerts.requestUrgentLowAlarmAuthorization()
        alertDelivery = AlertDeliveryReport(of: alerts)
        send(.alertDelivery)
    }

    func previewSound(_ sound: AlertSoundID) -> Bool {
        activeAlerts?.previewSound(sound) ?? false
    }

    func stopSoundPreview() {
        activeAlerts?.stopPreview()
    }

    func handleAlertAction(_ action: AlertUserAction) async {
        await activeAlerts?.send(.user(action))
    }

    // MARK: - Notification responses and the alarm's Stop button

    /// From the app's `UNUserNotificationCenterDelegate` (`didReceive`). Responses that arrive before
    /// the alert service exists (the app was launched by the tap) are delivered once it does.
    func handleNotificationResponse(actionIdentifier: String, userInfo: [String: String]) async {
        let kind = UserNotificationCenterAdapter.responseKind(actionIdentifier: actionIdentifier)
        guard let alerts = activeAlerts else {
            pendingNotificationResponses.append((kind, userInfo))
            return
        }
        await alerts.handleNotificationResponse(kind, userInfo: userInfo)
    }

    func deliverPendingNotificationResponses() async {
        guard let alerts = activeAlerts else { return }
        let pending = pendingNotificationResponses
        pendingNotificationResponses = []
        for response in pending {
            await alerts.handleNotificationResponse(response.kind, userInfo: response.userInfo)
        }
    }

    /// D26: the urgent-low alarm's Stop runs `StopUrgentLowAlarmIntent`, which reaches the running
    /// service through this bridge. Connected once; it always routes to the active service.
    func connectIntentBridge() async {
        await AlarmIntentRouting.connect(UrgentLowAlarmIntentBridge.shared) { [weak self] in self?.activeAlerts }
    }

    // MARK: - Trio bridge status → the §5 "Trio bridge" alert (S5)

    func trioSummaryChanged(_ summary: TrioBridgeSummary) {
        send(.trio)
        Task { await sendTrioAlertInput() }
    }

    /// Feeds the alert engine when the bridge's alert input changes (and after a new service starts).
    func sendTrioAlertInput(force: Bool = false) async {
        let input = trioCoordinator.summary.alertInput
        guard force || input != lastTrioAlertInput else { return }
        lastTrioAlertInput = input
        await activeAlerts?.send(.trioBridge(input))
    }
}

/// How the AlarmKit intent bridge reaches the alert service (shared with the app-level test of the
/// Stop button): every tap goes to whichever service is active at that moment.
enum AlarmIntentRouting {
    @MainActor
    static func connect(_ bridge: UrgentLowAlarmIntentBridge, to activeService: @escaping @MainActor () -> AlertService?) async {
        await bridge.connect { action in
            await activeService()?.send(.user(action))
        }
    }
}
