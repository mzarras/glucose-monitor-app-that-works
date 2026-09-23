// iOS: the ringer-off sound path (PROGRESS.md D17). Plays a bundled alert sound through
// AVAudioSession category `.playback`, which ignores the ring/silent switch. Works while the app
// is awake — in practice for the few seconds iOS gives it on each G7 BLE event, which keep
// running while audio plays because Info.plist has UIBackgroundModes `audio`.
//
// Approach proven in xDrip4iOS ("override mute": xDrip/Utilities/SoundPlayer/SoundPlayer.swift:31-41)
// and Loop (Loop/Managers/Alerts/CriticalAlertAudioPlayer.swift:92-131, LoopKit/Loop next-dev).
// Not copied from Trio (AGPL); written here from those descriptions.
//
// Deliberately NOT done: forcing the system volume up with the hidden MPVolumeView slider, as
// Loop and Trio do. By their own comments it no-ops while the app is in the background (the case
// that matters at 3 a.m.) and it relies on MPVolumeView's private view hierarchy. Instead the
// media volume is reported (`outputVolume`) so Settings can warn (S5).

#if os(iOS)
import AudioToolbox
import AVFoundation
import Foundation

@MainActor
public final class PlaybackAlertAudioPlayer: AlertAudioPlaying {
    private let bundle: Bundle
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?
    private var vibrationTask: Task<Void, Never>?

    /// Loop re-triggers the (≈0.4 s) system vibration this often while an alarm plays
    /// (CriticalAlertAudioPlayer.swift:41).
    private let vibrationInterval: Duration = .seconds(2)

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    public func play(fileName: String, loopSeconds: TimeInterval) -> Bool {
        stop()
        // Vibration does not depend on any volume, so start it first and even if audio fails.
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        guard let url = bundle.url(forResource: fileName, withExtension: nil) else { return false }
        do {
            let session = AVAudioSession.sharedInstance()
            // `.playback` ignores the silent switch. It must be mixable: iOS refuses to activate a
            // non-mixable session from the background ('!int', 560557684), Loop
            // CriticalAlertAudioPlayer.swift:94-104. `.duckOthers` lowers music under the alarm.
            try session.setCategory(.playback, mode: .default, options: [.duckOthers, .mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = loopSeconds > 0 ? -1 : 0
            player.volume = 1.0
            player.prepareToPlay()
            guard player.play() else {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                return false
            }
            self.player = player
            let playFor = loopSeconds > 0 ? loopSeconds : player.duration + 0.25
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(playFor))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
            if loopSeconds > 0 {
                let interval = vibrationInterval
                vibrationTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: interval)
                        guard !Task.isCancelled else { return }
                        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }

    public func stop() {
        stopTask?.cancel()
        stopTask = nil
        vibrationTask?.cancel()
        vibrationTask = nil
        guard let player else { return }
        player.stop()
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    public var isPlaying: Bool {
        player?.isPlaying ?? false
    }

    /// The media volume the `.playback` sound plays at. 0 means the ringer-off sound is inaudible.
    public var outputVolume: Float? {
        AVAudioSession.sharedInstance().outputVolume
    }
}
#endif
