// How the in-app player moves the shared AVAudioSession between its three setups (PROGRESS.md
// D17, D55). Pure and platform-neutral so the host tests cover every rule; the iOS player
// (Platform/PlaybackAlertAudioPlayer.swift) only carries the steps out and owns the AVAudioPlayer.
//
// The setups:
//   inactive    nothing plays, the volume is not monitored. Other apps' audio is untouched.
//   monitoring  D55, app in the foreground: active, `.playback` + `.mixWithOthers` only. Plays
//               nothing and never ducks or interrupts other audio; it keeps `outputVolume` current
//               (Apple: the value is only reliable while the session is active, see
//               PlaybackAlertAudioPlayer.outputVolume).
//   alarm       D17: active, `.playback` + `.duckOthers` + `.mixWithOthers`: an alert sound plays
//               and other audio is lowered under it (Loop CriticalAlertAudioPlayer.swift:94-104).
//
// One rule keeps the alarm path exactly what it was before D55: the ducking option is switched on
// or off only while the session is inactive. Ducking starts when a ducking session is activated and
// ends when it is deactivated (`setActive(false, options: .notifyOthersOnDeactivation)`, as Loop
// CriticalAlertAudioPlayer.swift:153 and this player before D55 do); Apple does not document what
// changing the options of an ACTIVE session does to ducking, so the plan never relies on it. An
// alarm therefore always starts from an inactive session and always ends with a deactivation, as
// before D55, and monitoring resumes only after that deactivation (so music comes back up).

import Foundation

/// What the shared audio session is set up for.
enum AudioSessionSetup: Sendable, Equatable {
    case inactive
    case monitoring
    case alarm
}

/// One call on `AVAudioSession.sharedInstance()`.
enum AudioSessionStep: Sendable, Equatable {
    /// `setActive(false, options: .notifyOthersOnDeactivation)`: ducked audio returns to full volume.
    /// Errors are ignored, as before D55.
    case deactivate
    /// `setCategory(.playback, mode: .default, options:)` with `[.duckOthers, .mixWithOthers]` when
    /// `ducksOthers`, else `[.mixWithOthers]` only.
    case setPlaybackCategory(ducksOthers: Bool)
    /// `setActive(true)`.
    case activate
}

/// The player's session state and the steps each event needs.
struct AudioSessionPlan: Sendable, Equatable {
    /// What the session is set up for; `nil` after a step failed (unknown, possibly still ducking:
    /// the next move starts with a deactivation).
    private(set) var setup: AudioSessionSetup? = .inactive
    /// D55: the volume is being monitored.
    private(set) var isMonitoring = false
    /// An alert sound is loaded: playing, or paused by an interruption.
    private(set) var holdsSound = false

    /// `play`: an alert sound is about to start.
    mutating func startSound() -> [AudioSessionStep] {
        holdsSound = true
        return move(to: .alarm)
    }

    /// `stop`, or `play` failed after `startSound()`: the sound is gone. Always a deactivation first,
    /// as before D55 (even after an interruption, when iOS has deactivated the session already), so
    /// other audio un-ducks; then monitoring takes the session back if it is on.
    mutating func endSound() -> [AudioSessionStep] {
        holdsSound = false
        setup = .inactive
        return [.deactivate] + move(to: isMonitoring ? .monitoring : .inactive)
    }

    /// D55. With a sound loaded the session stays as the sound needs it; `endSound()` hands it over.
    /// Already monitoring: the same setup is applied again (harmless on an active session; it
    /// re-activates a session an interruption left inactive without an end notice).
    mutating func startMonitoring() -> [AudioSessionStep] {
        isMonitoring = true
        return holdsSound ? [] : move(to: .monitoring)
    }

    /// D55. Never touches a session a sound holds: it is released when the sound ends.
    mutating func stopMonitoring() -> [AudioSessionStep] {
        guard isMonitoring else { return [] }
        isMonitoring = false
        return holdsSound ? [] : move(to: .inactive)
    }

    /// iOS deactivated the session (a phone call, Siri).
    mutating func interruptionBegan() {
        setup = .inactive
    }

    /// The interruption ended. `resumeSound`: an urgent-low loop plays on (its sound is still
    /// loaded). Otherwise monitoring, if on, gets its session back; nothing else changes.
    mutating func interruptionEnded(resumeSound: Bool) -> [AudioSessionStep] {
        if resumeSound, holdsSound { return move(to: .alarm) }
        return isMonitoring ? move(to: .monitoring) : []
    }

    /// A category change or activation threw: the session's state is unknown.
    mutating func stepFailed() {
        setup = nil
    }

    private mutating func move(to target: AudioSessionSetup) -> [AudioSessionStep] {
        let steps = Self.steps(from: setup, to: target)
        setup = target
        return steps
    }

    /// The calls that take the session from `current` (`nil`: unknown) to `target`. The ducking
    /// option is switched only on an inactive session (see the file comment).
    static func steps(from current: AudioSessionSetup?, to target: AudioSessionSetup) -> [AudioSessionStep] {
        switch target {
        case .inactive:
            return current == .inactive ? [] : [.deactivate]
        case .monitoring:
            if current == .inactive || current == .monitoring {
                return [.setPlaybackCategory(ducksOthers: false), .activate]
            }
            return [.deactivate, .setPlaybackCategory(ducksOthers: false), .activate]
        case .alarm:
            if current == .inactive {
                return [.setPlaybackCategory(ducksOthers: true), .activate]
            }
            return [.deactivate, .setPlaybackCategory(ducksOthers: true), .activate]
        }
    }
}
