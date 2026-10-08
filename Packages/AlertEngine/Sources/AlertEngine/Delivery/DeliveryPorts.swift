// The system services delivery needs, behind protocols so all logic above them runs and is
// tested on the macOS host. The iOS implementations live in Platform/ under `#if os(iOS)`.
// Both are main-actor bound: UNUserNotificationCenter callbacks and AVAudioPlayer are used from
// the main thread in the reference apps (xDrip4iOS, Loop), and the app's pipeline is main-actor.

import Foundation

@MainActor
public protocol AlertNotificationCenter: AnyObject {
    /// Registers the Snooze / Acknowledge categories. Call once at launch.
    func registerCategories() async
    /// Asks for alert, sound, badge and Critical Alert permission (D4: `.criticalAlert` is always
    /// requested; it is simply not granted without the entitlement).
    func requestAuthorization() async -> NotificationPermissionState
    func permissionState() async -> NotificationPermissionState
    func add(_ request: NotificationRequestSpec) async throws
    /// Identifiers of this app's pending requests and of its notifications still shown in
    /// Notification Center (D43 review B1: is a reminder that came due really out?).
    func presentIdentifiers() async -> Set<String>
    func removePending(identifiers: [String])
    func removeDelivered(identifiers: [String])
}

/// Vibrates the phone once (D53: an awake app's vibrate-only alert). Must not touch the audio session.
@MainActor
public protocol AlertHaptics: AnyObject {
    func vibrate()
}

/// No vibration: the macOS host, and DEBUG `-silenceAlertAudio` runs.
@MainActor
public final class NoAlertHaptics: AlertHaptics {
    public init() {}
    public func vibrate() {}
}

public enum AlertHapticsDefault {
    /// The system vibration on iOS (`SystemAlertHaptics`), nothing elsewhere.
    @MainActor
    public static func make() -> any AlertHaptics {
        #if os(iOS)
        return SystemAlertHaptics()
        #else
        return NoAlertHaptics()
        #endif
    }
}

@MainActor
public protocol AlertAudioPlaying: AnyObject {
    /// Starts playing a bundled file through AVAudioSession `.playback` (audible with the ringer
    /// off). Replaces anything this player is playing. Returns `false` if playback did not start.
    func play(fileName: String, loopSeconds: TimeInterval) -> Bool
    func stop()
    var isPlaying: Bool { get }
    /// The current media output volume 0…1, or `nil` if unknown.
    var outputVolume: Float? { get }

    /// D55: reports the media volume live until `stopVolumeMonitoring()`: the current value at
    /// once, then every change, each on the main actor. While monitoring, the player keeps its
    /// audio session active (`outputVolume` can be stale only while it is inactive) without ducking
    /// or interrupting other apps' audio. One monitor at a time: calling this again replaces
    /// `onEvent` and re-activates the monitoring session (recovering from an interruption whose end
    /// was never reported). While an alert sound plays, its session is left exactly as it is and
    /// monitoring takes it over when the sound ends. Never starts, stops or changes an alert sound.
    func startVolumeMonitoring(onEvent: @escaping @MainActor (VolumeMonitoringEvent) -> Void)
    /// D55: stops reporting; no event is delivered after this returns. Never stops or changes a
    /// playing alert sound: the session is released once neither a sound nor monitoring needs it.
    func stopVolumeMonitoring()
}

/// What an `AlertAudioPlaying` reports while it monitors the media volume (D55).
public enum VolumeMonitoringEvent: Sendable, Equatable {
    /// The media output volume 0…1, read from the active session.
    case changed(Float)
    /// The session could not be activated for monitoring, so the volume may be stale until the next
    /// report. Carries the system's error text. Not fatal: the last value stands.
    case sessionFailed(String)
}
