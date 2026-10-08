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

    func test_pausedOneShotWithMonitoringHandsTheSessionBackWhenItStops() {
        var plan = AudioSessionPlan()
        _ = plan.startMonitoring()
        _ = plan.startSound()
        plan.interruptionBegan()
        XCTAssertEqual(plan.interruptionEnded(resumeSound: false), monitoringSetup, "monitoring resumes; the sound does not")
        XCTAssertEqual(plan.endSound(), [.deactivate] + monitoringSetup)
        XCTAssertEqual(plan.setup, .monitoring)
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
