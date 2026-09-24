// What the app talks to: holds the engine, feeds it inputs with the injected clock, persists its
// snapshot, and hands the resulting actions to the executor strictly in order.

import Foundation
import GlucoseCore

@MainActor
public final class AlertService {
    public private(set) var engine: AlertEngine
    public let executor: AlertDeliveryExecutor

    private let clock: AlertClock
    private let center: AlertNotificationCenter
    private let audio: AlertAudioPlaying
    private let alarms: SystemAlarmScheduling?
    private let onSnapshot: @MainActor (AlertEngineSnapshot) -> Void
    /// The last batch of actions being executed. Each batch waits for the previous one, so a
    /// cancel can never overtake the post it is meant to remove.
    private var lastBatch: Task<Void, Never>?
    private var permissions = NotificationPermissionState.unknown
    private var lastOutputVolume: Float?
    /// The delivery level pending notifications/alarms were last built for. When it changes they
    /// are rebuilt.
    private var builtFor: (critical: Bool, alarms: Bool) = (false, false)

    /// - Parameters:
    ///   - snapshot: what `onSnapshot` last delivered, or `nil` on first launch.
    ///   - systemAlarms: AlarmKit (iOS 26+) for urgent low (D26); `nil` to use the D17 path only.
    ///   - onSnapshot: called after every input with the engine state to persist.
    public init(
        settings: AlertSettings,
        restoring snapshot: AlertEngineSnapshot?,
        configuration: AlertEngineConfiguration = AlertEngineConfiguration(),
        clock: AlertClock,
        notificationCenter: AlertNotificationCenter,
        audio: AlertAudioPlaying,
        systemAlarms: SystemAlarmScheduling? = nil,
        diagnostics: DiagnosticLog = NullDiagnosticLog(),
        onSnapshot: @escaping @MainActor (AlertEngineSnapshot) -> Void = { _ in }
    ) {
        self.engine = AlertEngine(settings: settings, configuration: configuration, restoring: snapshot, now: clock.now, uptime: clock.uptime)
        self.executor = AlertDeliveryExecutor(center: notificationCenter, audio: audio, alarms: systemAlarms, diagnostics: diagnostics, clock: clock)
        self.clock = clock
        self.center = notificationCenter
        self.audio = audio
        self.alarms = systemAlarms
        self.onSnapshot = onSnapshot
    }

    /// Call once at launch: registers the notification actions, reads permissions, then
    /// reconciles what a previous process left pending (urgent-low repeats and alarms, missed
    /// readings) and evaluates.
    public func start() async {
        await center.registerCategories()
        await send(.launched)
    }

    /// Feeds one input to the engine and performs the resulting actions. Every input first
    /// re-reads notification and alarm permissions, so each wake-up — in particular one that
    /// delivers an urgent low — uses the delivery level the user has now (D4, D26).
    public func send(_ input: AlertInput) async {
        await refreshPermissions()
        await apply(input)
    }

    /// For the app's `UNUserNotificationCenterDelegate` `didReceive` handler.
    public func handleNotificationResponse(_ response: NotificationResponseKind, userInfo: [AnyHashable: Any]) async {
        guard let action = AlertNotificationResponse.userAction(for: response, userInfo: userInfo) else { return }
        await send(.user(action))
    }

    /// Onboarding: ask for notification permission, including Critical Alerts (D4).
    public func requestAuthorization() async -> AlertDeliveryStatus {
        permissions = await center.requestAuthorization()
        lastOutputVolume = audio.outputVolume
        await rebuildIfDeliveryLevelChanged()
        return deliveryStatus
    }

    /// Onboarding (iOS 26+): ask to allow alarms, so urgent low can ring while suspended (D26).
    public func requestUrgentLowAlarmAuthorization() async -> AlertDeliveryStatus {
        _ = await alarms?.requestAuthorization()
        await rebuildIfDeliveryLevelChanged()
        return deliveryStatus
    }

    /// Settings screen and app foreground: re-read permissions and the media volume (S5).
    public func refreshDeliveryStatus() async -> AlertDeliveryStatus {
        await refreshPermissions()
        return deliveryStatus
    }

    /// Everything the Settings screen shows about whether alerts can be heard (S5).
    public var deliveryStatus: AlertDeliveryStatus {
        AlertDeliveryStatus(
            permissions: permissions,
            outputVolume: lastOutputVolume,
            urgentLowAlarm: alarms?.authorization ?? .unavailable,
            urgentLowAlarmFailure: executor.urgentLowAlarmFailure
        )
    }

    public var settings: AlertSettings { engine.settings }

    public func phase(of kind: AlertKind) -> AlertPhase {
        engine.phase(of: kind)
    }

    /// Alerts screen preview button. Returns `false` if an alert's sound is playing.
    public func previewSound(_ sound: AlertSoundID) -> Bool {
        executor.preview(sound)
    }

    public func stopPreview() {
        executor.stopPreview()
    }

    private func refreshPermissions() async {
        permissions = await center.permissionState()
        lastOutputVolume = audio.outputVolume
        await rebuildIfDeliveryLevelChanged()
    }

    private func rebuildIfDeliveryLevelChanged() async {
        executor.criticalAlertsEnabled = permissions.criticalAlertsEnabled
        let now = (critical: permissions.criticalAlertsEnabled, alarms: executor.systemAlarmsAvailable)
        guard now != builtFor else { return }
        builtFor = now
        // Pending notifications (and alarms) were built for the old delivery level; rebuild them.
        await apply(.settings(engine.settings))
    }

    private func apply(_ input: AlertInput) async {
        let actions = engine.handle(input, at: clock.now, uptime: clock.uptime)
        onSnapshot(engine.snapshot)
        await perform(actions)
    }

    private func perform(_ actions: [AlertAction]) async {
        guard !actions.isEmpty else { return }
        let previous = lastBatch
        let executor = self.executor
        let batch = Task { @MainActor in
            await previous?.value
            await executor.execute(actions)
        }
        lastBatch = batch
        await batch.value
    }
}
