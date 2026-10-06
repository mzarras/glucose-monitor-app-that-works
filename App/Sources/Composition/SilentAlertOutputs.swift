// DEBUG only: `-silenceAlertAudio` (UI tests, simulator runs on a developer's Mac). Alerts are
// decided and delivered exactly as usual — same notifications, interruption levels, categories,
// repeats, alarm scheduling decisions — but nothing is audible: the in-app player plays nothing,
// notifications are posted without a sound, and urgent-low system alarms are recorded instead of
// handed to AlarmKit (an AlarmKit alarm always rings). None of this exists in Release builds.

#if DEBUG
import AlertEngine
import Foundation
import UserNotifications

/// The launch argument that selects these silent outputs (`AppEnvironment.makeAlertPorts`).
enum SilentAlertAudio {
    static let launchArgument = "-silenceAlertAudio"
}

/// Plays nothing; reports success so the delivery logic runs unchanged. The media volume is the
/// real one, so the Settings volume warning still works.
@MainActor
final class SilentAlertAudioPlayer: AlertAudioPlaying {
    private let volumeSource: any AlertAudioPlaying
    private(set) var silencedPlays: [String] = []

    init(volumeSource: any AlertAudioPlaying) {
        self.volumeSource = volumeSource
    }

    func play(fileName: String, loopSeconds: TimeInterval) -> Bool {
        silencedPlays.append(fileName)
        return true
    }

    func stop() {}

    var isPlaying: Bool { false }

    var outputVolume: Float? { volumeSource.outputVolume }
}

/// Posts every notification as the real adapter does, without its sound.
@MainActor
final class SilentNotificationCenter: AlertNotificationCenter {
    private let adapter: UserNotificationCenterAdapter
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        self.adapter = UserNotificationCenterAdapter(center: center)
    }

    func registerCategories() async { await adapter.registerCategories() }
    func requestAuthorization() async -> NotificationPermissionState { await adapter.requestAuthorization() }
    func permissionState() async -> NotificationPermissionState { await adapter.permissionState() }
    func removePending(identifiers: [String]) { adapter.removePending(identifiers: identifiers) }
    func removeDelivered(identifiers: [String]) { adapter.removeDelivered(identifiers: identifiers) }

    func add(_ spec: NotificationRequestSpec) async throws {
        let trigger = spec.fireDate.map {
            UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0.timeIntervalSinceNow), repeats: false)
        }
        try await center.add(UNNotificationRequest(identifier: spec.identifier, content: Self.content(for: spec), trigger: trigger))
    }

    /// The same content `UserNotificationCenterAdapter.add` builds, with `sound` left nil.
    static func content(for spec: NotificationRequestSpec) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = spec.title
        content.body = spec.body
        content.threadIdentifier = spec.threadIdentifier
        content.categoryIdentifier = spec.categoryIdentifier
        content.userInfo = spec.userInfo
        switch spec.interruption {
        case .passive: content.interruptionLevel = .passive
        case .active: content.interruptionLevel = .active // D43: an announcement whose sound is off
        case .timeSensitive: content.interruptionLevel = .timeSensitive
        case .critical: content.interruptionLevel = .critical
        }
        content.sound = nil
        return content
    }
}

/// Reports the real AlarmKit authorization, but records alarms instead of scheduling them.
@MainActor
final class SilentSystemAlarms: SystemAlarmScheduling {
    private let real: any SystemAlarmScheduling
    private var recorded: Set<UUID> = []

    init(real: any SystemAlarmScheduling) {
        self.real = real
    }

    var authorization: SystemAlarmAuthorization { real.authorization }
    func requestAuthorization() async -> SystemAlarmAuthorization { await real.requestAuthorization() }
    func schedule(_ request: SystemAlarmRequest) async throws { recorded.insert(request.id) }
    func cancel(ids: [UUID]) { recorded.subtract(ids) }
    func cancelAll() throws {
        recorded.removeAll()
        // Also removes alarms an earlier, non-silenced run of this build left scheduled.
        try real.cancelAll()
    }
    func activeAlarmIDs() -> Set<UUID>? { recorded }
}
#endif
