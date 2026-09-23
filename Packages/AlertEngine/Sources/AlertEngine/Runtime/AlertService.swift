// What the app talks to: holds the engine, feeds it inputs with the injected clock, persists its
// snapshot, and hands the resulting actions to the executor strictly in order.

import Foundation
import GlucoseCore

@MainActor
public final class AlertService {
    public private(set) var engine: AlertEngine
    public let executor: AlertDeliveryExecutor
    public private(set) var deliveryStatus: AlertDeliveryStatus

    private let clock: AlertClock
    private let center: AlertNotificationCenter
    private let audio: AlertAudioPlaying
    private let onSnapshot: @MainActor (AlertEngineSnapshot) -> Void
    /// The last batch of actions being executed. Each batch waits for the previous one, so a
    /// cancel can never overtake the post it is meant to remove.
    private var lastBatch: Task<Void, Never>?

    /// - Parameters:
    ///   - snapshot: what `onSnapshot` last delivered, or `nil` on first launch.
    ///   - onSnapshot: called after every input with the engine state to persist.
    public init(
        settings: AlertSettings,
        restoring snapshot: AlertEngineSnapshot?,
        configuration: AlertEngineConfiguration = AlertEngineConfiguration(),
        clock: AlertClock,
        notificationCenter: AlertNotificationCenter,
        audio: AlertAudioPlaying,
        diagnostics: DiagnosticLog = NullDiagnosticLog(),
        onSnapshot: @escaping @MainActor (AlertEngineSnapshot) -> Void = { _ in }
    ) {
        self.engine = AlertEngine(settings: settings, configuration: configuration, restoring: snapshot, now: clock.now)
        self.executor = AlertDeliveryExecutor(center: notificationCenter, audio: audio, diagnostics: diagnostics, clock: clock)
        self.deliveryStatus = AlertDeliveryStatus(permissions: .unknown, outputVolume: nil)
        self.clock = clock
        self.center = notificationCenter
        self.audio = audio
        self.onSnapshot = onSnapshot
    }

    /// Call once at launch: registers the notification actions, reads permissions, and evaluates
    /// (which schedules the missed-readings notifications).
    public func start() async {
        await center.registerCategories()
        _ = await refreshDeliveryStatus()
        await send(.tick)
    }

    /// Feeds one input to the engine and performs the resulting actions.
    public func send(_ input: AlertInput) async {
        let actions = engine.handle(input, at: clock.now)
        onSnapshot(engine.snapshot)
        await perform(actions)
    }

    /// For the app's `UNUserNotificationCenterDelegate` `didReceive` handler.
    public func handleNotificationResponse(_ response: NotificationResponseKind, userInfo: [AnyHashable: Any]) async {
        guard let action = AlertNotificationResponse.userAction(for: response, userInfo: userInfo) else { return }
        await send(.user(action))
    }

    /// Onboarding: ask for notification permission, including Critical Alerts (D4).
    public func requestAuthorization() async -> AlertDeliveryStatus {
        await update(permissions: await center.requestAuthorization())
    }

    /// Settings screen and app foreground: re-read permissions and the media volume (S5).
    public func refreshDeliveryStatus() async -> AlertDeliveryStatus {
        await update(permissions: await center.permissionState())
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

    private func update(permissions: NotificationPermissionState) async -> AlertDeliveryStatus {
        let criticalChanged = executor.criticalAlertsEnabled != permissions.criticalAlertsEnabled
        executor.criticalAlertsEnabled = permissions.criticalAlertsEnabled
        deliveryStatus = AlertDeliveryStatus(permissions: permissions, outputVolume: audio.outputVolume)
        if criticalChanged {
            // Pending notifications were built for the old delivery level; rebuild them.
            await send(.settings(engine.settings))
        }
        return deliveryStatus
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
