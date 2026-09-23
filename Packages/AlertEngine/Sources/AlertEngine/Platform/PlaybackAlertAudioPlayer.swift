// iOS: the ringer-off sound path (PROGRESS.md D17). Plays a bundled alert sound through
// AVAudioSession category `.playback`, which ignores the ring/silent switch. Works while the app
// is awake — in practice for the few seconds iOS gives it on each G7 BLE event, which keep
// running while audio plays because Info.plist has UIBackgroundModes `audio`.
//
// Approach proven in xDrip4iOS ("override mute": xDrip/Utilities/SoundPlayer/SoundPlayer.swift:31-41)
// and Loop (Loop/Managers/Alerts/CriticalAlertAudioPlayer.swift:92-131, LoopKit/Loop next-dev).
// Not copied from Trio (AGPL); written here from those descriptions.
//
// Interruptions (a phone call, Siri): iOS pauses our player. When the interruption ends and the
// urgent-low loop still has time left, playback resumes for that remaining time (at least
// `minimumResumeSeconds`), even if iOS does not suggest resuming: an unacknowledged urgent low
// outranks the usual courtesy. A one-shot sound is not resumed. Whether iOS lets a backgrounded
// app resume after a call is part of the §11 on-device checks.
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
    /// When the current loop is due to end; `nil` for a one-shot sound.
    private var loopEndsAt: Date?
    /// Loop time left when an interruption began.
    private var remainingAtInterruption: TimeInterval?
    private var interruptionObserver: ObserverToken?

    /// Loop re-triggers the (≈0.4 s) system vibration this often while an alarm plays
    /// (CriticalAlertAudioPlayer.swift:41).
    private let vibrationInterval: Duration = .seconds(2)
    /// After a call, an interrupted urgent-low loop plays at least this long again.
    private let minimumResumeSeconds: TimeInterval = 10

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
        let token = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] notification in
            // Extract plain values here; `Notification` is not Sendable.
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleInterruption(typeRaw: typeRaw)
            }
        }
        interruptionObserver = ObserverToken(token)
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver.value)
        }
    }

    public func play(fileName: String, loopSeconds: TimeInterval) -> Bool {
        stop()
        // Vibration does not depend on any volume, so start it first and even if audio fails.
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        guard let url = bundle.url(forResource: fileName, withExtension: nil) else { return false }
        do {
            try activateSession()
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = loopSeconds > 0 ? -1 : 0
            player.volume = 1.0
            player.prepareToPlay()
            guard player.play() else {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                return false
            }
            self.player = player
            if loopSeconds > 0 {
                loopEndsAt = Date().addingTimeInterval(loopSeconds)
                startVibration()
                scheduleStop(after: loopSeconds)
            } else {
                loopEndsAt = nil
                scheduleStop(after: player.duration + 0.25)
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
        loopEndsAt = nil
        remainingAtInterruption = nil
        guard let player else { return }
        player.stop()
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    public var isPlaying: Bool {
        player?.isPlaying ?? false
    }

    /// The media volume the `.playback` sound plays at; 0 means the ringer-off sound is inaudible.
    /// The executor reads this right after `play` has activated the session, when it is current;
    /// read at other times it may lag a volume change made while the session was inactive.
    public var outputVolume: Float? {
        AVAudioSession.sharedInstance().outputVolume
    }

    /// `.playback` ignores the silent switch. It must be mixable: iOS refuses to activate a
    /// non-mixable session from the background ('!int', 560557684), Loop
    /// CriticalAlertAudioPlayer.swift:94-104. `.duckOthers` lowers music under the alarm.
    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.duckOthers, .mixWithOthers])
        try session.setActive(true)
    }

    private func scheduleStop(after seconds: TimeInterval) {
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func startVibration() {
        vibrationTask?.cancel()
        let interval = vibrationInterval
        vibrationTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
        }
    }

    private func handleInterruption(typeRaw: UInt?) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            // iOS has paused the player. Hold the loop's remaining time instead of letting the
            // stop timer run out during the call.
            guard player != nil, let loopEndsAt else { return }
            remainingAtInterruption = max(loopEndsAt.timeIntervalSinceNow, 0)
            stopTask?.cancel()
            vibrationTask?.cancel()
        case .ended:
            guard let player, let remaining = remainingAtInterruption else { return }
            remainingAtInterruption = nil
            let playFor = max(remaining, minimumResumeSeconds)
            do {
                try activateSession()
                guard player.play() else { stop(); return }
                loopEndsAt = Date().addingTimeInterval(playFor)
                startVibration()
                scheduleStop(after: playFor)
            } catch {
                stop()
            }
        @unknown default:
            return
        }
    }
}

/// The observer token, readable from the nonisolated `deinit`.
/// `@unchecked Sendable`: immutable after init, and the only use is
/// `NotificationCenter.removeObserver`, which is thread-safe.
private final class ObserverToken: @unchecked Sendable {
    let value: NSObjectProtocol
    init(_ value: NSObjectProtocol) { self.value = value }
}
#endif
