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
    private let diagnostics: DiagnosticLog
    private let onSnapshot: @MainActor (AlertEngineSnapshot) -> Void
    /// The last batch of actions being executed. Each batch waits for the previous one, so a
    /// cancel can never overtake the post it is meant to remove.
    private var lastBatch: Task<Void, Never>?
    private var permissions = NotificationPermissionState.unknown
    private var lastOutputVolume: Float?
    /// The delivery level pending notifications/alarms were last built for, and whether
    /// notifications were allowed (`nil` until first read). When either changes they are rebuilt:
    /// adds made while notifications were not allowed failed (D43 review B1).
    private var builtFor: (critical: Bool, alarms: Bool, authorized: Bool?) = (false, false, nil)

    /// D55: whether this service has the audio player report the media volume live
    /// (`setVolumeMonitoring(_:)`; the app turns it on in the foreground).
    public private(set) var isMonitoringVolume = false
    /// D55: called on the main actor after a volume change reported while monitoring has changed
    /// `deliveryStatus` (already updated when this runs). Never called while monitoring is off.
    /// Permission refreshes do not call it: their callers read `deliveryStatus` themselves.
    public var onDeliveryStatusChange: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - snapshot: what `onSnapshot` last delivered, or `nil` on first launch.
    ///   - systemAlarms: AlarmKit (iOS 26+) for urgent low (D26); `nil` to use the D17 path only.
    ///   - haptics: the in-app vibration for vibrate-only alerts (D53); `nil` uses the system
    ///     vibration on iOS. DEBUG `-silenceAlertAudio` runs pass `NoAlertHaptics()`.
    ///   - onSnapshot: called after every input with the engine state to persist.
    public init(
        settings: AlertSettings,
        restoring snapshot: AlertEngineSnapshot?,
        configuration: AlertEngineConfiguration = AlertEngineConfiguration(),
        clock: AlertClock,
        notificationCenter: AlertNotificationCenter,
        audio: AlertAudioPlaying,
        systemAlarms: SystemAlarmScheduling? = nil,
        haptics: AlertHaptics? = nil,
        diagnostics: DiagnosticLog = NullDiagnosticLog(),
        onSnapshot: @escaping @MainActor (AlertEngineSnapshot) -> Void = { _ in }
    ) {
        self.engine = AlertEngine(settings: settings, configuration: configuration, restoring: snapshot, now: clock.now, uptime: clock.uptime)
        self.executor = AlertDeliveryExecutor(center: notificationCenter, audio: audio, alarms: systemAlarms, haptics: haptics,
                                              diagnostics: diagnostics, clock: clock)
        self.clock = clock
        self.center = notificationCenter
        self.audio = audio
        self.alarms = systemAlarms
        self.diagnostics = diagnostics
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

    /// D55: on while the app is in the foreground, off in the background. On: the audio player keeps
    /// its session active without ducking anyone and reports the media volume live; each change
    /// updates `deliveryStatus` and calls `onDeliveryStatusChange`. Turning it on again re-activates
    /// the player's session (it may have been lost to an interruption). Off: no further reports.
    /// Never starts, stops or changes an alert sound. The player has one monitor at a time, so when
    /// the app replaces its service (replay runs) it turns the old one's off first.
    public func setVolumeMonitoring(_ isOn: Bool) {
        if isOn {
            if !isMonitoringVolume { log("volume monitoring on (D55)") }
            isMonitoringVolume = true
            audio.startVolumeMonitoring { [weak self] event in
                self?.volumeMonitoringReported(event)
            }
        } else {
            guard isMonitoringVolume else { return }
            isMonitoringVolume = false
            audio.stopVolumeMonitoring()
            log("volume monitoring off (D55)")
        }
    }

    /// Everything the Settings screen shows about whether alerts can be heard (S5).
    public var deliveryStatus: AlertDeliveryStatus {
        AlertDeliveryStatus(
            permissions: permissions,
            outputVolume: lastOutputVolume,
            urgentLowAlarm: alarms?.authorization ?? .unavailable,
            urgentLowAlarmFailure: executor.urgentLowAlarmFailure,
            repeatShortfalls: executor.repeatShortfalls
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

    /// D55. A report that arrives after monitoring was turned off is dropped.
    private func volumeMonitoringReported(_ event: VolumeMonitoringEvent) {
        guard isMonitoringVolume else { return }
        switch event {
        case .changed(let volume):
            guard volume != lastOutputVolume else { return }
            let wasWarning = AlertDeliveryStatus.volumeProblem(lastOutputVolume) != nil
            lastOutputVolume = volume
            let isWarning = AlertDeliveryStatus.volumeProblem(volume) != nil
            if wasWarning != isWarning {
                log("media volume \(String(format: "%.2f", volume)): alarm volume warning \(isWarning ? "on" : "off") (live, D55)")
            }
            onDeliveryStatusChange?()
        case .sessionFailed(let reason):
            let last = lastOutputVolume.map { String(format: "%.2f", $0) } ?? "unknown"
            log("volume monitoring: audio session not activated (\(reason)); media volume stays \(last) until the next report")
        }
    }

    private func log(_ message: String) {
        diagnostics.record(DiagnosticEvent(date: clock.now, category: .alert, message: message))
    }

    private func rebuildIfDeliveryLevelChanged() async {
        executor.criticalAlertsEnabled = permissions.criticalAlertsEnabled
        let level = (critical: permissions.criticalAlertsEnabled, alarms: executor.systemAlarmsAvailable)
        let authorized = permissions.isAuthorized
        let authorizationChanged = builtFor.authorized.map { $0 != authorized } ?? false
        let levelChanged = level.critical != builtFor.critical || level.alarms != builtFor.alarms
        builtFor = (level.critical, level.alarms, authorized)
        guard levelChanged || authorizationChanged else { return }
        // Pending notifications (and alarms) were built for the old delivery level, or could not be
        // added at all; rebuild them.
        await apply(.settings(engine.settings))
    }

    private func apply(_ input: AlertInput) async {
        let actions = engine.handle(input, at: clock.now, uptime: clock.uptime)
        onSnapshot(engine.snapshot)
        await perform(actions)
        // Report refused pending reminders back, so none counts as out (D43 review B1). One round:
        // the engine never re-adds a refused one by itself, so this cannot loop.
        let refused = executor.takeRefusedReminders()
        guard !refused.isEmpty else { return }
        if case .notificationsNotScheduled = input { return }
        await apply(.notificationsNotScheduled(refused))
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
