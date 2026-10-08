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

    // MARK: - m2: an interruption end that never comes

    /// A loop paused by an interruption whose end never came, past its end time: the next start of
    /// monitoring (a foreground) releases it, so monitoring gets the session and reports again.
    func test_aPausedLoopPastItsEndIsReleasedWhenMonitoringStarts() async {
        XCTAssertTrue(player.play(fileName: silentSound, loopSeconds: 30))
        await post(.began)
        XCTAssertFalse(player.isPlaying)
        clock.now += 600 // no `.ended`
        startMonitoring()
        XCTAssertEqual(sessionOptions, monitoringOptions, "monitoring has the session")
        await waitUntil("the current volume is reported", timeout: 5) { !self.events.isEmpty }
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
