// What the in-app player does with an alert sound it has loaded when an interruption (a phone call,
// Siri) ends, and when it may let go of one whose interruption end never came (reviews B1, m2 of
// D55; round 2 B2, m1). Pure and platform-neutral so the host tests cover every case
// (HeldAlertSoundTests); Platform/PlaybackAlertAudioPlayer.swift applies the rules. The session
// steps themselves are AudioSessionPlan's.
//
// One principle runs through all of them (S7): a sound that is playing is never stopped or touched
// here, and a loop (only urgent alerts loop, DeliveryPolicy.swift) is never given up while it waits
// for an interruption's end, however long that takes: it plays on then, for the time it had left.
// Only a one-shot that will never play again is released: loaded but silent, it would report
// `isPlaying == false` (so `AlertDeliveryExecutor.playInApp` already lets another alert take its
// place) while still holding the audio session that volume monitoring needs. A paused loop whose end
// notice never comes still ends: through the next repeat's `play` (which stops it first) or the
// alert's acknowledgement, snooze or clearing (`AlertDeliveryExecutor`: `.cancel`, `.dismiss`,
// `.stopSound`), so it holds the session for at most one repeat interval.

import Foundation

enum HeldAlertSound {
    /// After an interruption, an urgent-low loop plays at least this long again, even if its time ran
    /// out during the interruption: an unacknowledged urgent low outranks the usual courtesy.
    static let minimumResumeSeconds: TimeInterval = 10

    /// What to do with the loaded sound when an interruption ends.
    enum AtInterruptionEnd: Equatable {
        /// Playing, and no loop time was recorded when the interruption began: it started during the
        /// interruption (or iOS never paused it). Its session is left exactly as it is (B1).
        case leaveAlone
        /// Play the loop again for this long (the urgent-low resume, as before D55).
        case resumeLoop(seconds: TimeInterval)
        /// A one-shot that is not playing: never resumed (as before D55), so let it go now rather
        /// than when its stop timer fires.
        case release
    }

    /// - Parameters:
    ///   - isPlaying: `AVAudioPlayer.isPlaying` now.
    ///   - loopSecondsLeftAtInterruption: recorded at `.began` for a loop that was loaded then; `nil`
    ///     for a one-shot, or for a loop that started after the interruption began.
    ///   - loopEndsIn: seconds until the loop's end time (negative once past); `nil` for a one-shot.
    static func atInterruptionEnd(isPlaying: Bool, loopSecondsLeftAtInterruption: TimeInterval?, loopEndsIn: TimeInterval?) -> AtInterruptionEnd {
        // The loop that was interrupted: it plays on for its remaining time, as before D55 (whether
        // iOS paused it or not; `play()` on a playing player changes nothing).
        if let left = loopSecondsLeftAtInterruption {
            return .resumeLoop(seconds: max(left, minimumResumeSeconds))
        }
        if isPlaying { return .leaveAlone }
        // A loop that stopped without an interruption notice of its own (it started during this
        // interruption): treated like an interrupted loop, so an urgent low is never left silent.
        if let loopEndsIn {
            return .resumeLoop(seconds: max(loopEndsIn, minimumResumeSeconds))
        }
        return .release
    }

    /// Review m2, round 2 B2. Whether a loaded sound that may still be waiting for an interruption's
    /// end is given up when volume monitoring starts (each foreground). iOS does not promise an end
    /// notice, and without one a paused one-shot would hold the session for good.
    ///   - playing: never (S7);
    ///   - a loop: never (S7). Its remaining time is frozen when the interruption begins and it plays
    ///     on when the interruption ends, however long that was (`atInterruptionEnd`), so its wall-clock
    ///     end time says nothing. At c32eeef a loop past that end time was released here, so opening
    ///     the app during a call longer than the loop's time left (or during 8 s of Siri near its end)
    ///     silenced the urgent low for good;
    ///   - a one-shot that is not playing: yes, it is never resumed.
    static func isAbandoned(isPlaying: Bool, isLoop: Bool) -> Bool {
        !isPlaying && !isLoop
    }

    /// Round 2 m1. Whether the interrupted loop is kept once its resume has been tried: whenever it
    /// is sounding, including when its session could not be set up again but iOS had never paused it
    /// (it still plays in the session it has). Kept, its stop timer and vibration are armed again; a
    /// silent loop is released, never left loaded. Before, a failed setup stopped a loop that was
    /// still sounding (since before D55).
    static func keepsLoopAfterResumeAttempt(isPlaying: Bool) -> Bool {
        isPlaying
    }
}
