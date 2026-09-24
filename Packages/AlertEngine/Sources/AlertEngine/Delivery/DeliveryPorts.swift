// The two system services delivery needs, behind protocols so all logic above them runs and is
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
    func removePending(identifiers: [String])
    func removeDelivered(identifiers: [String])
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
}
