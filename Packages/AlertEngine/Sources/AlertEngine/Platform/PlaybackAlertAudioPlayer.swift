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
//
// D55, live media volume: `outputVolume` is only kept current while the session is active, so a
// warning read from an inactive session never cleared until a relaunch. While the app is in the
// foreground the alert service has this player monitor the volume (`startVolumeMonitoring`): the
// session is held active in `.playback` + `.mixWithOthers` only — it plays nothing and never ducks
// or interrupts other apps' audio — and `outputVolume` is observed with KVO (Apple documents the
// property as key-value observable: https://developer.apple.com/documentation/avfaudio/avaudiosession/outputvolume).
// nightguard @ 75404bd (nightguard/helpers/VolumeChangeDetector.swift:22-31) and LoopFollow v7.1.0
// @ 4a74b78 (LoopFollow/Controllers/VolumeButtonHandler.swift:240) observe the volume the same way;
// both are AGPL, read for the approach only, nothing copied. When the session moves between inactive,
// monitoring and alarm is decided by AudioSessionPlan (pure, host-tested): alarm playback is
// unchanged, and other audio un-ducks after an alarm before monitoring resumes.
//
// This player is the only code in the app that touches the shared AVAudioSession.

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
    /// The session's setup and what holds it: a sound, monitoring (AudioSessionPlan.swift).
    private var plan = AudioSessionPlan()
    /// D55: where volume reports go; nil while not monitoring.
    private var onVolumeEvent: (@MainActor (VolumeMonitoringEvent) -> Void)?
    /// D55: the KVO observation of `outputVolume` while monitoring.
    private var volumeObservation: NSKeyValueObservation?

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
            try perform(plan.startSound())
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = loopSeconds > 0 ? -1 : 0
            player.volume = 1.0
            player.prepareToPlay()
            guard player.play() else {
                releaseSessionAfterSound()
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
            // The session could not be set up, or the file not opened (before D55 the latter left
            // the ducking session active).
            releaseSessionAfterSound()
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
        releaseSessionAfterSound()
    }

    public var isPlaying: Bool {
        player?.isPlaying ?? false
    }

    /// The media volume the `.playback` sound plays at; 0 means the ringer-off sound is inaudible.
    /// Current while the session is active: right after `play` has activated it (when the executor
    /// reads it) and, D55, all the time the volume is monitored. Read while the session is inactive
    /// it may lag a volume change made since it was last active.
    public var outputVolume: Float? {
        AVAudioSession.sharedInstance().outputVolume
    }

    // MARK: - D55 volume monitoring

    public func startVolumeMonitoring(onEvent: @escaping @MainActor (VolumeMonitoringEvent) -> Void) {
        onVolumeEvent = onEvent
        // With a sound loaded the session stays the sound's; it is handed over in `stop`.
        performReportingFailure(plan.startMonitoring())
        observeVolume()
    }

    public func stopVolumeMonitoring() {
        onVolumeEvent = nil
        volumeObservation?.invalidate()
        volumeObservation = nil
        // Only ever a deactivation, and only with no sound loaded; it cannot throw.
        try? perform(plan.stopMonitoring())
    }

    /// (Re)creates the KVO observation. `.initial` reports the current value at once; the session
    /// was activated just before (or an alert sound holds it), so the value is current.
    private func observeVolume() {
        volumeObservation?.invalidate()
        volumeObservation = Self.observeOutputVolume { [weak self] in
            Task { @MainActor [weak self] in
                self?.volumeMayHaveChanged()
            }
        }
    }

    /// The value is read here, on the main actor, rather than taken from the KVO change: a quick
    /// run of button presses can then never be applied out of order. Forwarded only while the
    /// session is known to be active: read from an inactive one (an interruption, a failed
    /// activation) it may be stale, and the last reported value stands.
    private func volumeMayHaveChanged() {
        guard plan.setup == .monitoring || plan.setup == .alarm else { return }
        report(.changed(AVAudioSession.sharedInstance().outputVolume))
    }

    /// Nonisolated so the KVO closure is not main-actor isolated: AVAudioSession calls it on a
    /// thread of its own. KVO calls it on every change; `.initial` adds one call right away.
    private nonisolated static func observeOutputVolume(onChange: @escaping @Sendable () -> Void) -> NSKeyValueObservation {
        AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.initial]) { _, _ in
            onChange()
        }
    }

    /// Drops the event when monitoring is off (a KVO report still on its way to the main actor).
    private func report(_ event: VolumeMonitoringEvent) {
        onVolumeEvent?(event)
    }

    // MARK: - The session (AudioSessionPlan)

    /// The sound is gone: the session is deactivated, so other audio un-ducks, and taken back for
    /// monitoring if that is on (D55); otherwise it stays inactive, as before D55.
    private func releaseSessionAfterSound() {
        performReportingFailure(plan.endSound())
    }

    /// D55: a monitoring session that cannot be activated is reported (the service logs it) and is
    /// not fatal; the last reported volume stands.
    private func performReportingFailure(_ steps: [AudioSessionStep]) {
        do {
            try perform(steps)
        } catch {
            report(.sessionFailed(String(describing: error)))
        }
    }

    /// Carries the plan's steps out on the shared session. A deactivation error is ignored, as
    /// before D55; a failed category change or activation throws and leaves the plan's state unknown.
    private func perform(_ steps: [AudioSessionStep]) throws {
        let session = AVAudioSession.sharedInstance()
        do {
            for step in steps {
                switch step {
                case .deactivate:
                    try? session.setActive(false, options: .notifyOthersOnDeactivation)
                case .setPlaybackCategory(let ducksOthers):
                    // `.playback` ignores the silent switch. It must be mixable: iOS refuses to activate a
                    // non-mixable session from the background ('!int', 560557684), Loop
                    // CriticalAlertAudioPlayer.swift:94-104. `.duckOthers` lowers music under the alarm;
                    // the monitoring session (D55) leaves it out, so it never lowers anyone's audio.
                    let options: AVAudioSession.CategoryOptions = ducksOthers ? [.duckOthers, .mixWithOthers] : [.mixWithOthers]
                    try session.setCategory(.playback, mode: .default, options: options)
                case .activate:
                    try session.setActive(true)
                }
            }
        } catch {
            plan.stepFailed()
            throw error
        }
    }

    // MARK: - Timers and interruptions

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
            // iOS has deactivated the session and paused the player. Hold the loop's remaining time
            // instead of letting the stop timer run out during the call.
            plan.interruptionBegan()
            guard player != nil, let loopEndsAt else { return }
            remainingAtInterruption = max(loopEndsAt.timeIntervalSinceNow, 0)
            stopTask?.cancel()
            vibrationTask?.cancel()
        case .ended:
            guard let player, let remaining = remainingAtInterruption else {
                // No loop to resume. D55: monitoring, if on, gets its session back.
                performReportingFailure(plan.interruptionEnded(resumeSound: false))
                return
            }
            remainingAtInterruption = nil
            let playFor = max(remaining, minimumResumeSeconds)
            do {
                try perform(plan.interruptionEnded(resumeSound: true))
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
