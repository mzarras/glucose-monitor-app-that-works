// Review M1(b) (D55 B1, m2): the real `PlaybackAlertAudioPlayer`, hosted on the simulator. It plays
// only the silent `alert-vibrate.caf` (D53), so nothing is audible on the Mac running the tests, and
// the simulator cannot vibrate.
//
// The interruption notices are posted by the test with `object: AVAudioSession.sharedInstance()`, so
// the player's own observer and handler run. What the iOS 26.2 simulator does with them, measured for
// this fix (20 of 20 runs each):
//   - AVAudioPlayer pauses itself on a posted `.began` at once, as on a phone when a call starts, and
//     does not resume by itself on `.ended`. So a posted `.began` gives the real "paused by an
//     interruption" state.
//   - Deactivating the session does NOT stop a playing AVAudioPlayer here (`isPlaying` stays true and
//     `currentTime` keeps advancing), unlike a phone (AVAudioSession.h, `setActive:error:`: with I/O
//     running "the session will be deactivated"). So `isPlaying` alone cannot catch B1 here. The
//     session's category options can: B1's interruption end set up monitoring (`.mixWithOthers`
//     only) under the playing alarm, which must keep its own setup (`.duckOthers` +
//     `.mixWithOthers`) until it ends. On e3fde03 both B1 tests below fail on exactly that.

import AlertEngine
import AVFoundation
import XCTest

@MainActor
final class PlaybackAlertAudioPlayerTests: XCTestCase {
    /// Silent (Resources/Sounds/README.md, D53); copied flat into the app bundle, the test host.
    private let silentSound = "alert-vibrate.caf"
    private var clock: Clock!
    private var player: PlaybackAlertAudioPlayer!
    private var events: [VolumeMonitoringEvent] = []

    /// The player's wall clock, moved by the test.
    @MainActor
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    override func setUp() async throws {
        let clock = Clock()
        self.clock = clock
        player = PlaybackAlertAudioPlayer(bundle: .main, now: { clock.now })
    }

    override func tearDown() async throws {
        player.stopVolumeMonitoring()
        player.stop()
        player = nil
    }

    /// Posts an interruption notice as iOS does and waits until the player has handled it.
    private func post(_ type: AVAudioSession.InterruptionType) async {
        let handled = player.interruptionNoticesHandled
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue]
        )
        await waitUntil("the player handled the notice", timeout: 5) { self.player.interruptionNoticesHandled == handled + 1 }
    }

    private func startMonitoring() {
        player.startVolumeMonitoring { [weak self] event in self?.events.append(event) }
    }

    /// The real session's options: the alarm's ducking setup, or monitoring's mixable-only one.
    private var sessionOptions: AVAudioSession.CategoryOptions {
        AVAudioSession.sharedInstance().categoryOptions
    }

    private let alarmOptions: AVAudioSession.CategoryOptions = [.duckOthers, .mixWithOthers]
    private let monitoringOptions: AVAudioSession.CategoryOptions = [.mixWithOthers]

    // MARK: - D55 monitoring on the real session

    func test_monitoringAloneUsesAMixableNonDuckingSessionAndReportsTheVolume() async {
        startMonitoring()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        XCTAssertEqual(sessionOptions, monitoringOptions)
        await waitUntil("the current volume is reported", timeout: 5) { !self.events.isEmpty }
        guard case .changed(let volume) = events.first else { return XCTFail("\(events)") }
        XCTAssertTrue((0...1).contains(volume))
    }

    /// While a playing alarm holds the session, monitoring leaves it alone and reports from it.
    func test_monitoringReportsTheVolumeWhileAnAlarmHoldsTheSession() async {
        XCTAssertTrue(player.play(fileName: silentSound, loopSeconds: 30))
        startMonitoring()
        await waitUntil("the current volume is reported", timeout: 5) { !self.events.isEmpty }
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(sessionOptions, alarmOptions, "monitoring did not take the alarm's session")
        player.stop()
        XCTAssertEqual(sessionOptions, monitoringOptions, "handed to monitoring when the sound ends")
    }

    // MARK: - B1: an interruption's end never takes a playing sound's session (S7)

    func test_S7_aSoundStartedDuringAnInterruptionKeepsPlayingWhenItEnds() async {
        startMonitoring()
        await post(.began) // a call starts while the app is open; no sound is loaded
        XCTAssertTrue(player.play(fileName: silentSound, loopSeconds: 30), "an urgent low during the call")
        XCTAssertEqual(sessionOptions, alarmOptions)
        await post(.ended)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(sessionOptions, alarmOptions, "the call's end must leave the alarm's session alone")
        player.stop()
        XCTAssertEqual(sessionOptions, monitoringOptions, "handed to monitoring when the sound ends")
    }

    func test_S7_aSoundThatReplacedAnInterruptedLoopKeepsPlayingWhenItEnds() async {
        startMonitoring()
        XCTAssertTrue(player.play(fileName: silentSound, loopSeconds: 30))
        await post(.began)
        XCTAssertFalse(player.isPlaying, "paused by the interruption; its remaining time is recorded")
        XCTAssertTrue(player.play(fileName: silentSound, loopSeconds: 30), "a repeat replaces it during the call")
        await post(.ended)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(sessionOptions, alarmOptions, "the call's end must leave the new sound's session alone")
    }

    func test_S7_anInterruptedLoopPlaysOnWhenItEnds() async {
        startMonitoring()
        XCTAssertTrue(player.play(fileName: silentSound, loopSeconds: 30))
        await post(.began)
        XCTAssertFalse(player.isPlaying)
        clock.now += 120 // a long call: the loop's end time has passed
        await post(.ended)
        XCTAssertTrue(player.isPlaying, "plays on for the time it had left (at least 10 s)")
        XCTAssertEqual(sessionOptions, alarmOptions)
    }

    /// A one-shot paused by the interruption is not resumed; it is released when the interruption
    /// ends, and monitoring takes the session.
    func test_aPausedOneShotIsReleasedWhenTheInterruptionEnds() async {
        startMonitoring()
        XCTAssertTrue(player.play(fileName: silentSound, loopSeconds: 0))
        await post(.began)
        await post(.ended)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(sessionOptions, monitoringOptions)
        XCTAssertTrue(player.play(fileName: silentSound, loopSeconds: 30), "the next sound plays")
    }

    // MARK: - m2 and round-2 B2: a start of monitoring never drops an interrupted loop

    /// The app is opened (monitoring starts) during a call that has outlasted the interrupted
    /// loop's remaining time; when the call ends the loop plays on, as it does without monitoring.
    /// Round-2 B2: at c32eeef the start of monitoring released the loop and it never resumed.
    private func assertForegroundDuringCallKeepsTheLoop(callSecondsBeforeForeground: TimeInterval,
                                                        file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertTrue(player.play(fileName: silentSound, loopSeconds: 30), file: file, line: line)
        await post(.began) // remaining time recorded: 30 s
        XCTAssertFalse(player.isPlaying, "paused by the call", file: file, line: line)
        clock.now += callSecondsBeforeForeground
        startMonitoring() // the app comes to the foreground during the call
        XCTAssertEqual(sessionOptions, alarmOptions, "still the sound's session", file: file, line: line)
        await post(.ended)
        XCTAssertTrue(player.isPlaying, "the urgent-low loop plays on after the call", file: file, line: line)
        XCTAssertEqual(player.loopEndsAt, clock.now.addingTimeInterval(30), "for the 30 s it had left", file: file, line: line)
    }

    func test_S7_aForegroundDuringA40SecondCallKeepsTheInterruptedLoop() async {
        await assertForegroundDuringCallKeepsTheLoop(callSecondsBeforeForeground: 40)
    }

    func test_S7_aForegroundDuringATenMinuteCallKeepsTheInterruptedLoop() async {
        await assertForegroundDuringCallKeepsTheLoop(callSecondsBeforeForeground: 600)
    }

    /// The reviewer's case: monitoring on, the loop has played 25 of its 30 s, Siri for 8 s, and the
    /// scene's `.active` is handled before the interruption's `.ended`.
    func test_S7_aForegroundDuringAShortSiriKeepsALoopNearItsEnd() async {
        startMonitoring()
        XCTAssertTrue(player.play(fileName: silentSound, loopSeconds: 30))
        clock.now += 25
        await post(.began) // 5 s left
        clock.now += 8
        startMonitoring()
        XCTAssertEqual(sessionOptions, alarmOptions)
        await post(.ended)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.loopEndsAt, clock.now.addingTimeInterval(10), "the 10 s minimum")
    }

    /// Within its time the paused loop keeps waiting for the interruption's end, and then plays on.
    func test_S7_startingMonitoringKeepsAPausedLoopWithinItsTime() async {
        XCTAssertTrue(player.play(fileName: silentSound, loopSeconds: 30))
        await post(.began)
        clock.now += 20
        startMonitoring()
        XCTAssertEqual(sessionOptions, alarmOptions, "still the sound's")
        await post(.ended)
        XCTAssertTrue(player.isPlaying)
    }

    /// A one-shot paused by an interruption whose end never came is never resumed: the next start
    /// of monitoring (a foreground) releases it, so monitoring gets the session and reports again.
    func test_aPausedOneShotIsReleasedWhenMonitoringStarts() async {
        XCTAssertTrue(player.play(fileName: silentSound, loopSeconds: 0))
        await post(.began)
        XCTAssertFalse(player.isPlaying)
        startMonitoring() // before its stop timer (1.25 s of real time) fires
        XCTAssertEqual(sessionOptions, monitoringOptions, "monitoring has the session")
        await waitUntil("the current volume is reported", timeout: 5) { !self.events.isEmpty }
    }

    // MARK: - Round-2: a second interruption notice

    /// A second `.began` before any `.ended` (Siri during a call) keeps the time recorded at the
    /// first: the loop plays on for that, not for the 10 s minimum.
    func test_S7_aSecondBeganKeepsTheLoopsRecordedTime() async {
        XCTAssertTrue(player.play(fileName: silentSound, loopSeconds: 30))
        await post(.began) // 30 s left
        clock.now += 20
        await post(.began)
        await post(.ended)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.loopEndsAt, clock.now.addingTimeInterval(30))
    }

    /// A loop playing past its end time (it started during an interruption, its stop timer runs on
    /// real time) is never cut by a start of monitoring.
    func test_S7_startingMonitoringNeverCutsAPlayingLoop() async {
        startMonitoring()
        await post(.began)
        XCTAssertTrue(player.play(fileName: silentSound, loopSeconds: 30))
        clock.now += 600
        startMonitoring() // the app comes to the foreground again
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(sessionOptions, alarmOptions)
    }
}
