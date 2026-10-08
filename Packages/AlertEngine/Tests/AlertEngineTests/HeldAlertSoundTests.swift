import XCTest
@testable import AlertEngine

/// Reviews B1 and m2 of D55: what `PlaybackAlertAudioPlayer` (iOS only; its hosted tests are
/// AppTests/PlaybackAlertAudioPlayerTests.swift) does with a loaded sound when an interruption ends,
/// and when volume monitoring may give up a sound whose interruption end never came.
final class HeldAlertSoundTests: XCTestCase {
    // MARK: - At an interruption's end

    /// B1: started during the interruption and playing; nothing is recorded for it.
    func test_S7_aPlayingSoundWithNothingRecordedIsLeftAlone() {
        for loopEndsIn in [25.0, -5, nil] as [TimeInterval?] {
            XCTAssertEqual(HeldAlertSound.atInterruptionEnd(isPlaying: true, loopSecondsLeftAtInterruption: nil, loopEndsIn: loopEndsIn),
                           .leaveAlone, "loop ends in \(String(describing: loopEndsIn))")
        }
    }

    /// The interrupted urgent-low loop plays on for its remaining time, at least 10 s, as before D55.
    func test_S7_anInterruptedLoopResumesForItsRemainingTimeAndAtLeastTenSeconds() {
        XCTAssertEqual(HeldAlertSound.atInterruptionEnd(isPlaying: false, loopSecondsLeftAtInterruption: 25, loopEndsIn: -100),
                       .resumeLoop(seconds: 25), "the time left when the call began, however long the call")
        XCTAssertEqual(HeldAlertSound.atInterruptionEnd(isPlaying: false, loopSecondsLeftAtInterruption: 3, loopEndsIn: -100),
                       .resumeLoop(seconds: 10))
        XCTAssertEqual(HeldAlertSound.atInterruptionEnd(isPlaying: true, loopSecondsLeftAtInterruption: 25, loopEndsIn: 20),
                       .resumeLoop(seconds: 25), "iOS did not pause it: play() again changes nothing, the timers restart")
    }

    /// A loop that stopped without an interruption notice of its own is played again, never dropped.
    func test_S7_aSilentLoopWithNothingRecordedResumes() {
        XCTAssertEqual(HeldAlertSound.atInterruptionEnd(isPlaying: false, loopSecondsLeftAtInterruption: nil, loopEndsIn: 18),
                       .resumeLoop(seconds: 18))
        XCTAssertEqual(HeldAlertSound.atInterruptionEnd(isPlaying: false, loopSecondsLeftAtInterruption: nil, loopEndsIn: -60),
                       .resumeLoop(seconds: 10))
    }

    /// A one-shot is never resumed; one that is not playing is released at once.
    func test_aSilentOneShotIsReleased() {
        XCTAssertEqual(HeldAlertSound.atInterruptionEnd(isPlaying: false, loopSecondsLeftAtInterruption: nil, loopEndsIn: nil), .release)
    }

    // MARK: - Abandoned (review m2: volume monitoring starts with a sound still loaded)

    func test_S7_aPlayingSoundIsNeverAbandoned() {
        for loopEndsIn in [30.0, 0, -600, nil] as [TimeInterval?] {
            XCTAssertFalse(HeldAlertSound.isAbandoned(isPlaying: true, loopEndsIn: loopEndsIn), "\(String(describing: loopEndsIn))")
        }
    }

    /// A paused loop within its time is still waiting for the interruption's end to play on.
    func test_S7_aPausedLoopWithinItsTimeIsNotAbandoned() {
        XCTAssertFalse(HeldAlertSound.isAbandoned(isPlaying: false, loopEndsIn: 0.5))
        XCTAssertFalse(HeldAlertSound.isAbandoned(isPlaying: false, loopEndsIn: 29))
    }

    func test_aPausedLoopPastItsEndAndAPausedOneShotAreAbandoned() {
        XCTAssertTrue(HeldAlertSound.isAbandoned(isPlaying: false, loopEndsIn: 0))
        XCTAssertTrue(HeldAlertSound.isAbandoned(isPlaying: false, loopEndsIn: -120))
        XCTAssertTrue(HeldAlertSound.isAbandoned(isPlaying: false, loopEndsIn: nil))
    }
}
