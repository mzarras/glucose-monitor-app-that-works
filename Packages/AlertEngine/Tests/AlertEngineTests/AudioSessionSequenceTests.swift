import XCTest
@testable import AlertEngine

/// Review M1 (D55 B1): every sequence of plan events the player can produce, up to `depth` events
/// long, checked against the rules that keep an alert sound audible (S7) and other apps' audio
/// undisturbed. `AudioSessionPlanTests`' pair test looks at one move at a time and cannot see
/// `holdsSound`; this walk carries the plan's whole state from event to event, which is what catches
/// B1 (an interruption end that deactivated the session of a sound still playing).
final class AudioSessionSequenceTests: XCTestCase {
    /// One call `PlaybackAlertAudioPlayer` makes on its plan.
    enum Event: CaseIterable {
        case startSound, endSound, startMonitoring, stopMonitoring
        case interruptionBegan, interruptionEndedResuming, interruptionEndedNotResuming, stepFailed
    }

    /// Eight events, so up to 8^7 ≈ 2.1 million sequences before the player's constraints prune them.
    private static let depth = 7

    /// The plan, and what the walk tracks about the real session beside it.
    private struct Walk {
        var plan = AudioSessionPlan()
        var events: [Event] = []
        /// A ducking category was set and no `.deactivate` step has run since (invariant 3). iOS's own
        /// deactivation at an interruption does not clear it: the plan must not rely on it.
        var mayBeDucking = false
    }

    /// For each invariant, the shortest sequence found ending in each event that breaks it, as text.
    private struct Violations {
        var heldSoundLostItsSession: [Event: String] = [:]
        var heldSoundInMonitoringSetup: [Event: String] = [:]
        var duckedWithoutASound: [Event: String] = [:]
        var monitoringWhileDucked: [Event: String] = [:]
        var sequencesWalked = 0
    }

    /// Invariant 1 (S7): while a sound is held, no event other than `endSound` returns `.deactivate`
    /// (it stops a playing sound: AVAudioSession.h, `setActive:error:`) or moves the setup away from
    /// `.alarm`. `interruptionBegan` and `stepFailed` return no steps: they record what iOS or a
    /// failed call did to the session, so they are not moves of the plan's.
    /// Invariant 2: a ducking category is never set without a held sound.
    /// Invariant 3: after a sound, monitoring's (non-ducking) category is set only after a
    /// `.deactivate`, so other audio has come back up (ducking ends at deactivation).
    /// Also: with a sound held the session is never set up for monitoring, which is why the resume
    /// may re-apply the alarm setup without a deactivation (AudioSessionPlan.interruptionEnded).
    func test_S7_everyEventSequenceKeepsAHeldSoundsSessionAndNeverLeavesOtherAudioDucked() {
        let found = Self.walkAll()
        XCTAssertGreaterThan(found.sequencesWalked, 100_000, "the walk is not vacuous")
        XCTAssertEqual(found.heldSoundLostItsSession, [:], "invariant 1 (S7): a held sound's session was taken")
        XCTAssertEqual(found.heldSoundInMonitoringSetup, [:], "a held sound's session set up for monitoring")
        XCTAssertEqual(found.duckedWithoutASound, [:], "invariant 2: ducking without a held sound")
        XCTAssertEqual(found.monitoringWhileDucked, [:], "invariant 3: monitoring set up before other audio un-ducked")
    }

    /// The walk reaches the states that matter (so a pass is not an artefact of the constraints):
    /// a sound held with monitoring on during an interruption, and a sound started during one.
    func test_theWalkReachesASoundHeldWithMonitoringDuringAnInterruption() {
        var plan = AudioSessionPlan()
        for event in [Event.startMonitoring, .interruptionBegan, .startSound] {
            XCTAssertTrue(Self.isPossible(event, in: plan))
            _ = Self.apply(event, to: &plan)
        }
        XCTAssertTrue(plan.holdsSound && plan.isMonitoring && plan.setup == .alarm)
        XCTAssertTrue(Self.isPossible(.interruptionEndedNotResuming, in: plan))
        XCTAssertFalse(Self.isPossible(.startSound, in: plan), "play() ends the held sound first")
        XCTAssertFalse(Self.isPossible(.endSound, in: AudioSessionPlan()), "stop() without a sound touches nothing")
    }

    // MARK: - The walk

    private static func walkAll() -> Violations {
        var found = Violations()
        walk(Walk(), remaining: depth, into: &found)
        return found
    }

    private static func walk(_ current: Walk, remaining: Int, into found: inout Violations) {
        guard remaining > 0 else { return }
        for event in Event.allCases where isPossible(event, in: current.plan) {
            var next = current
            next.events.append(event)
            let steps = apply(event, to: &next.plan)
            found.sequencesWalked += 1
            check(event, steps: steps, before: current, after: &next, into: &found)
            walk(next, remaining: remaining - 1, into: &found)
        }
    }

    private static func check(_ event: Event, steps: [AudioSessionStep], before: Walk, after: inout Walk, into found: inout Violations) {
        let sequence = after.events.map { "\($0)" }.joined(separator: ", ")
        // Invariant 1.
        if before.plan.holdsSound, event != .endSound, event != .interruptionBegan, event != .stepFailed {
            let deactivates = steps.contains(.deactivate)
            let leftAlarm = before.plan.setup == .alarm && after.plan.setup != .alarm
            if deactivates || leftAlarm {
                record(sequence, endingIn: event, in: &found.heldSoundLostItsSession)
            }
        }
        if after.plan.holdsSound, after.plan.setup == .monitoring {
            record(sequence, endingIn: event, in: &found.heldSoundInMonitoringSetup)
        }
        // Invariant 2.
        if steps.contains(.setPlaybackCategory(ducksOthers: true)), !after.plan.holdsSound {
            record(sequence, endingIn: event, in: &found.duckedWithoutASound)
        }
        // Invariant 3, step by step.
        for step in steps {
            switch step {
            case .deactivate:
                after.mayBeDucking = false
            case .setPlaybackCategory(ducksOthers: true):
                after.mayBeDucking = true
            case .setPlaybackCategory(ducksOthers: false):
                if after.mayBeDucking { record(sequence, endingIn: event, in: &found.monitoringWhileDucked) }
            case .activate:
                break
            }
        }
    }

    private static func record(_ sequence: String, endingIn event: Event, in found: inout [Event: String]) {
        if let known = found[event], known.count <= sequence.count { return }
        found[event] = sequence
    }

    /// The player's own call constraints (PlaybackAlertAudioPlayer.swift), nothing more:
    /// - `play` ends any held sound (`stop()`) before `startSound()`;
    /// - `endSound()` runs only with a sound held: `stop()` returns early without a player, and
    ///   `play`'s failure paths run after `startSound()`;
    /// - the resume path runs only with a sound held (an interrupted loop).
    /// Everything else may come at any time, `stepFailed` included.
    static func isPossible(_ event: Event, in plan: AudioSessionPlan) -> Bool {
        switch event {
        case .startSound: return !plan.holdsSound
        case .endSound, .interruptionEndedResuming: return plan.holdsSound
        case .startMonitoring, .stopMonitoring, .interruptionBegan, .interruptionEndedNotResuming, .stepFailed: return true
        }
    }

    static func apply(_ event: Event, to plan: inout AudioSessionPlan) -> [AudioSessionStep] {
        switch event {
        case .startSound: return plan.startSound()
        case .endSound: return plan.endSound()
        case .startMonitoring: return plan.startMonitoring()
        case .stopMonitoring: return plan.stopMonitoring()
        case .interruptionBegan:
            plan.interruptionBegan()
            return []
        case .interruptionEndedResuming: return plan.interruptionEnded(resumeSound: true)
        case .interruptionEndedNotResuming: return plan.interruptionEnded(resumeSound: false)
        case .stepFailed:
            plan.stepFailed()
            return []
        }
    }
}
