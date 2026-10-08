import XCTest
@testable import AlertEngine

/// D55: the session rules `PlaybackAlertAudioPlayer` (iOS only, not runnable here) carries out. The
/// alarm sequences without monitoring are the calls the player made before D55, step for step.
final class AudioSessionPlanTests: XCTestCase {
    private let alarmSetup: [AudioSessionStep] = [.setPlaybackCategory(ducksOthers: true), .activate]
    private let monitoringSetup: [AudioSessionStep] = [.setPlaybackCategory(ducksOthers: false), .activate]

    // MARK: - Without monitoring: exactly as before D55

    func test_alarmWithoutMonitoringIsTheSequenceUsedBeforeD55() {
        var plan = AudioSessionPlan()
        // play(): setCategory(.playback, [.duckOthers, .mixWithOthers]), setActive(true).
        XCTAssertEqual(plan.startSound(), alarmSetup)
        XCTAssertEqual(plan.setup, .alarm)
        // stop(): setActive(false, .notifyOthersOnDeactivation).
        XCTAssertEqual(plan.endSound(), [.deactivate])
        XCTAssertEqual(plan.setup, .inactive)
        XCTAssertFalse(plan.holdsSound)
    }

    func test_replacingASoundWithoutMonitoringDeactivatesThenSetsUpAgain() {
        var plan = AudioSessionPlan()
        _ = plan.startSound()
        // play() calls stop() first, then sets the session up again.
        XCTAssertEqual(plan.endSound(), [.deactivate])
        XCTAssertEqual(plan.startSound(), alarmSetup)
    }

    func test_interruptedLoopResumesWithTheSameSetupAsBeforeD55() {
        for monitoring in [false, true] {
            var plan = AudioSessionPlan()
            if monitoring { _ = plan.startMonitoring() }
            _ = plan.startSound()
            plan.interruptionBegan()
            XCTAssertEqual(plan.setup, .inactive, "iOS deactivated the session")
            XCTAssertEqual(plan.interruptionEnded(resumeSound: true), alarmSetup, "monitoring \(monitoring)")
            XCTAssertEqual(plan.setup, .alarm)
            XCTAssertEqual(plan.endSound(), monitoring ? [.deactivate] + monitoringSetup : [.deactivate])
        }
    }

    func test_interruptionEndWithoutALoopChangesNothingWithoutMonitoring() {
        var plan = AudioSessionPlan()
        plan.interruptionBegan()
        XCTAssertEqual(plan.interruptionEnded(resumeSound: false), [])
        // A paused one-shot sound is not resumed, and its stop deactivates as before D55 (though
        // iOS already has).
        _ = plan.startSound()
        plan.interruptionBegan()
        XCTAssertEqual(plan.interruptionEnded(resumeSound: false), [])
        XCTAssertEqual(plan.endSound(), [.deactivate])
        XCTAssertEqual(plan.setup, .inactive)
    }

    /// Review B1: the interruption's end leaves a loaded sound's session alone, even with monitoring
    /// on; monitoring gets it when the sound is released (`stop()`), after a deactivation.
    func test_pausedOneShotWithMonitoringHandsTheSessionBackWhenItStops() {
        var plan = AudioSessionPlan()
        _ = plan.startMonitoring()
        _ = plan.startSound()
        plan.interruptionBegan()
        XCTAssertEqual(plan.interruptionEnded(resumeSound: false), [], "the sound still holds the session")
        XCTAssertEqual(plan.setup, .inactive)
        XCTAssertEqual(plan.endSound(), [.deactivate] + monitoringSetup)
        XCTAssertEqual(plan.setup, .monitoring)
    }

    // MARK: - B1: an interruption's end never takes a loaded sound's session (S7)

    /// A call begins while the app is open with nothing playing; an urgent low starts during the
    /// call (iOS lets a `.playback` session activate then). The call's end must not deactivate it:
    /// that stops the sound (AVAudioSession.h, `setActive:error:`).
    func test_S7_anAlertStartedDuringAnInterruptionKeepsItsSessionWhenItEnds() {
        var plan = AudioSessionPlan()
        _ = plan.startMonitoring()
        plan.interruptionBegan()
        XCTAssertEqual(plan.startSound(), alarmSetup, "from the session the call deactivated")
        XCTAssertEqual(plan.interruptionEnded(resumeSound: false), [])
        XCTAssertEqual(plan.setup, .alarm)
        XCTAssertTrue(plan.holdsSound)
        XCTAssertEqual(plan.startMonitoring(), [], "a foreground meanwhile leaves it alone too")
        XCTAssertEqual(plan.endSound(), [.deactivate] + monitoringSetup, "handed over when the sound ends")
    }

    /// An urgent-low loop is interrupted, and its repeat replaces it during the call (`play` ends
    /// the old sound first). The call's end must leave the new sound's session alone.
    func test_S7_anAlertThatReplacedAnInterruptedLoopKeepsItsSessionWhenItEnds() {
        var plan = AudioSessionPlan()
        _ = plan.startMonitoring()
        _ = plan.startSound()
        plan.interruptionBegan()
        XCTAssertEqual(plan.endSound(), [.deactivate] + monitoringSetup, "the old loop's stop()")
        XCTAssertEqual(plan.startSound(), [.deactivate] + alarmSetup, "the repeat's play()")
        XCTAssertEqual(plan.interruptionEnded(resumeSound: false), [])
        XCTAssertEqual(plan.setup, .alarm)
        XCTAssertTrue(plan.holdsSound)
    }

    /// The resume applies the alarm setup again exactly as before D55 (setCategory, setActive(true)),
    /// never with a deactivation first, whatever the plan believes about the session.
    func test_S7_resumingALoopNeverDeactivates() {
        func loopWithMonitoringOn() -> AudioSessionPlan {
            var plan = AudioSessionPlan()
            _ = plan.startMonitoring()
            _ = plan.startSound()
            return plan
        }
        var interrupted = loopWithMonitoringOn()
        interrupted.interruptionBegan()
        let neverPaused = loopWithMonitoringOn() // a second `.ended`, or iOS did not pause it
        var unknown = loopWithMonitoringOn()
        unknown.stepFailed()
        for (name, before) in [("interrupted", interrupted), ("never paused", neverPaused), ("unknown", unknown)] {
            var plan = before
            XCTAssertEqual(plan.interruptionEnded(resumeSound: true), alarmSetup, name)
            XCTAssertEqual(plan.setup, .alarm, name)
        }
    }

    // MARK: - Monitoring

    func test_monitoringAloneNeverDucksAndIsReleasedWhenTurnedOff() {
        var plan = AudioSessionPlan()
        XCTAssertEqual(plan.startMonitoring(), monitoringSetup)
        XCTAssertEqual(plan.setup, .monitoring)
        XCTAssertEqual(plan.stopMonitoring(), [.deactivate])
        XCTAssertEqual(plan.setup, .inactive)
        XCTAssertEqual(plan.stopMonitoring(), [], "already off")
    }

    func test_startingMonitoringAgainReappliesTheSameSetup() {
        var plan = AudioSessionPlan()
        _ = plan.startMonitoring()
        XCTAssertEqual(plan.startMonitoring(), monitoringSetup, "re-activates a session an interruption may have taken")
    }

    func test_alarmWhileMonitoringStartsFromAnInactiveSessionAndEndsWithADeactivation() {
        var plan = AudioSessionPlan()
        _ = plan.startMonitoring()
        XCTAssertEqual(plan.startSound(), [.deactivate] + alarmSetup)
        XCTAssertEqual(plan.setup, .alarm)
        // The deactivation un-ducks other audio; then monitoring takes the session back.
        XCTAssertEqual(plan.endSound(), [.deactivate] + monitoringSetup)
        XCTAssertEqual(plan.setup, .monitoring)
    }

    func test_turningMonitoringOffWhileASoundPlaysLeavesTheSessionToTheSound() {
        var plan = AudioSessionPlan()
        _ = plan.startMonitoring()
        _ = plan.startSound()
        XCTAssertEqual(plan.stopMonitoring(), [], "the alarm keeps its session")
        XCTAssertEqual(plan.setup, .alarm)
        XCTAssertTrue(plan.holdsSound)
        XCTAssertEqual(plan.endSound(), [.deactivate], "released when the sound ends, as before D55")
        XCTAssertEqual(plan.setup, .inactive)
    }

    func test_turningMonitoringOnWhileASoundPlaysLeavesTheSessionToTheSound() {
        var plan = AudioSessionPlan()
        _ = plan.startSound()
        XCTAssertEqual(plan.startMonitoring(), [], "the alarm keeps ducking")
        XCTAssertEqual(plan.setup, .alarm)
        XCTAssertEqual(plan.endSound(), [.deactivate] + monitoringSetup)
    }

    func test_interruptionEndWithoutALoopGivesMonitoringItsSessionBack() {
        var plan = AudioSessionPlan()
        _ = plan.startMonitoring()
        plan.interruptionBegan()
        XCTAssertEqual(plan.interruptionEnded(resumeSound: false), monitoringSetup)
        XCTAssertEqual(plan.setup, .monitoring)
    }

    func test_aFailedStepMakesTheNextMoveDeactivateFirst() {
        var plan = AudioSessionPlan()
        _ = plan.startSound()
        plan.stepFailed()
        XCTAssertNil(plan.setup)
        XCTAssertEqual(plan.endSound(), [.deactivate], "it may still be active and ducking")

        _ = plan.startMonitoring()
        plan.stepFailed()
        XCTAssertEqual(plan.startMonitoring(), [.deactivate] + monitoringSetup)
        plan.stepFailed()
        XCTAssertEqual(plan.startSound(), [.deactivate] + alarmSetup)
    }

    // MARK: - The rule, for every pair of setups

    /// The ducking option is switched only on an inactive session, and every move ends in the target
    /// setup. Simulated with a model of the session: active or not, and its ducking option.
    func test_duckingIsSwitchedOnlyOnAnInactiveSessionAndEveryMoveReachesItsTarget() {
        let currents: [AudioSessionSetup?] = [nil, .inactive, .monitoring, .alarm]
        let targets: [AudioSessionSetup] = [.inactive, .monitoring, .alarm]
        for current in currents {
            for target in targets {
                let steps = AudioSessionPlan.steps(from: current, to: target)
                // Unknown: possibly active, with either option.
                var active = current != .inactive
                var ducks: Bool? = current == .alarm ? true : current == .monitoring ? false : nil
                for step in steps {
                    switch step {
                    case .deactivate:
                        active = false
                    case .setPlaybackCategory(let newDucks):
                        if active && ducks != newDucks {
                            XCTFail("\(String(describing: current)) → \(target): ducking switched on an active session")
                        }
                        ducks = newDucks
                    case .activate:
                        active = true
                    }
                }
                switch target {
                case .inactive:
                    XCTAssertFalse(active, "\(String(describing: current)) → inactive")
                case .monitoring:
                    XCTAssertTrue(active && ducks == false, "\(String(describing: current)) → monitoring")
                case .alarm:
                    XCTAssertTrue(active && ducks == true, "\(String(describing: current)) → alarm")
                }
                XCTAssertFalse(target == .monitoring && steps.contains(.setPlaybackCategory(ducksOthers: true)),
                               "monitoring never ducks other audio")
            }
        }
    }
}
