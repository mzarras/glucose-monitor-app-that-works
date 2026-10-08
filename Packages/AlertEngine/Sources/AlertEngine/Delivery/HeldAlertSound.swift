// What the in-app player does with an alert sound it has loaded when an interruption (a phone call,
// Siri) ends, and when it may let go of one whose interruption end never came (reviews B1, m2 of
// D55). Pure and platform-neutral so the host tests cover every case (HeldAlertSoundTests);
// Platform/PlaybackAlertAudioPlayer.swift applies the rules. The session steps themselves are
// AudioSessionPlan's.
//
// One principle runs through both (S7): a sound that is playing is never stopped or touched here.
// A loop (only urgent alerts loop, DeliveryPolicy.swift) that is not playing is played again rather
// than dropped while its time lasts. Only a sound that will never play again is released: loaded but
// silent, it would report `isPlaying == false` (so `AlertDeliveryExecutor.playInApp` already lets
// another alert take its place) while still holding the audio session that volume monitoring needs.

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

    /// Review m2. Whether a loaded sound that may still be waiting for an interruption's end is given
    /// up when volume monitoring starts (each foreground). iOS does not promise an end notice, and
    /// without one a paused sound would hold the session for good: monitoring could never take it
    /// and the Settings volume would stay stale.
    ///   - playing: never (S7);
    ///   - a one-shot that is not playing: yes, it is never resumed;
    ///   - a loop that is not playing: only once its end time has passed. Until then it is waiting
    ///     for the interruption's end to play on (`atInterruptionEnd`).
    static func isAbandoned(isPlaying: Bool, loopEndsIn: TimeInterval?) -> Bool {
        if isPlaying { return false }
        guard let loopEndsIn else { return true }
        return loopEndsIn <= 0
    }
}
