import XCTest
import GlucoseCore
@testable import AlertEngine

/// D55: while the app is in the foreground the service has the player report the media volume
/// live; each change updates `deliveryStatus` (and its volume problems) and calls
/// `onDeliveryStatusChange`. Alarm playback is the same with monitoring on or off.
@MainActor
final class VolumeMonitoringTests: XCTestCase {
    /// A started service whose delivery-status callbacks are counted.
    private func harness(volume: Float? = 0.8) async -> (ServiceHarness, Counter) {
        let h = ServiceHarness()
        h.audio.outputVolume = volume
        await h.service.start()
        let counter = Counter()
        h.service.onDeliveryStatusChange = { counter.value += 1 }
        return (h, counter)
    }

    @MainActor
    final class Counter {
        var value = 0
    }

    // MARK: - Monitoring on

    func test_volumeChangesMoveTheWarningAcrossTheLowVolumeLevelAndCallBack() async {
        let (h, calls) = await harness()
        h.service.setVolumeMonitoring(true)
        XCTAssertTrue(h.audio.isMonitoringVolume)
        XCTAssertEqual(calls.value, 0, "the value reported at once is the one already known")
        XCTAssertEqual(h.service.deliveryStatus.problems, [])

        // (volume, expected volume problems), stepping across AlertLimits.lowAlarmVolume (0.25)
        // and the muted level (≤ 0.001).
        let steps: [(Float, [DeliveryProblem])] = [
            (0.24, [.alarmVolumeLow(0.24)]),
            (0.25, []),
            (0.0625, [.alarmVolumeLow(0.0625)]),
            (0, [.alarmVolumeMuted]),
            (0.001, [.alarmVolumeMuted]),
            (1, []),
        ]
        for (index, (volume, problems)) in steps.enumerated() {
            h.audio.changeVolume(to: volume)
            XCTAssertEqual(h.service.deliveryStatus.outputVolume, volume)
            XCTAssertEqual(h.service.deliveryStatus.problems, problems, "at \(volume)")
            XCTAssertEqual(calls.value, index + 1, "one callback per change, at \(volume)")
        }
        XCTAssertEqual(h.log.messages.filter { $0.contains("alarm volume warning on") }.count, 2, "0.24 and 0.0625")
        XCTAssertEqual(h.log.messages.filter { $0.contains("alarm volume warning off") }.count, 2, "0.25 and 1")
    }

    func test_theCurrentVolumeIsReportedAtOnceWhenMonitoringStarts() async {
        let (h, calls) = await harness()
        // Changed while not monitored (the stale value the warning used to keep until a relaunch).
        h.audio.outputVolume = 0.1
        XCTAssertEqual(h.service.deliveryStatus.outputVolume, 0.8)
        h.service.setVolumeMonitoring(true)
        XCTAssertEqual(h.service.deliveryStatus.outputVolume, 0.1)
        XCTAssertEqual(h.service.deliveryStatus.problems, [.alarmVolumeLow(0.1)])
        XCTAssertEqual(calls.value, 1)
    }

    func test_theCallbackRunsAfterTheStatusIsUpdated() async {
        let (h, _) = await harness()
        var seen: Float?
        h.service.onDeliveryStatusChange = { [weak service = h.service] in seen = service?.deliveryStatus.outputVolume }
        h.service.setVolumeMonitoring(true)
        h.audio.changeVolume(to: 0.2)
        XCTAssertEqual(seen, 0.2)
    }

    func test_anUnchangedVolumeDoesNotCallBack() async {
        let (h, calls) = await harness()
        h.service.setVolumeMonitoring(true)
        h.audio.changeVolume(to: 0.8)
        XCTAssertEqual(calls.value, 0)
    }

    func test_aVolumeChangeIsNotAnAlertInput() async {
        let (h, _) = await harness()
        let snapshots = h.snapshots.count
        let posted = h.center.posted.count
        h.service.setVolumeMonitoring(true)
        h.audio.changeVolume(to: 0)
        XCTAssertEqual(h.snapshots.count, snapshots, "the engine is not run")
        XCTAssertEqual(h.center.posted.count, posted)
        XCTAssertTrue(h.audio.plays.isEmpty)
    }

    func test_turningMonitoringOnAgainRestartsThePlayersMonitor() async {
        let (h, _) = await harness()
        h.service.setVolumeMonitoring(true)
        h.service.setVolumeMonitoring(true)
        XCTAssertEqual(h.audio.monitoringStarts, 2, "each foreground re-activates the session")
        XCTAssertTrue(h.service.isMonitoringVolume)
        h.service.setVolumeMonitoring(false)
        h.service.setVolumeMonitoring(false)
        XCTAssertEqual(h.audio.monitoringStops, 1)
        XCTAssertFalse(h.service.isMonitoringVolume)
        XCTAssertFalse(h.audio.isMonitoringVolume)
        // Logged once per change, for the §10 device check (docs/alerts.md item 12).
        XCTAssertEqual(h.log.messages.filter { $0.hasPrefix("volume monitoring o") }, ["volume monitoring on (D55)", "volume monitoring off (D55)"])
    }

    func test_aSessionThatCannotBeActivatedIsLoggedAndTheLastVolumeStands() async {
        let (h, calls) = await harness()
        h.service.setVolumeMonitoring(true)
        h.audio.changeVolume(to: 0.5)
        h.audio.failMonitoringSession("Error Domain=NSOSStatusErrorDomain Code=560557684")
        XCTAssertEqual(h.service.deliveryStatus.outputVolume, 0.5)
        XCTAssertEqual(calls.value, 1, "only the change")
        XCTAssertTrue(h.log.messages.contains {
            $0.hasPrefix("volume monitoring: audio session not activated (Error Domain=NSOSStatusErrorDomain Code=560557684)")
                && $0.hasSuffix("media volume stays 0.50 until the next report")
        })
        XCTAssertTrue(h.service.isMonitoringVolume, "still on: the next report or foreground recovers")
    }

    // MARK: - Monitoring off

    func test_noCallbackAndNoUpdateAfterMonitoringIsTurnedOff() async {
        let (h, calls) = await harness()
        h.service.setVolumeMonitoring(true)
        h.audio.changeVolume(to: 0.6)
        XCTAssertEqual(calls.value, 1)
        h.service.setVolumeMonitoring(false)
        XCTAssertFalse(h.audio.isMonitoringVolume)
        h.audio.changeVolume(to: 0.1)
        // A report already on its way to the main actor when monitoring stopped is dropped too.
        h.audio.deliverLateReport(.changed(0.05))
        h.audio.deliverLateReport(.sessionFailed("late"))
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(h.service.deliveryStatus.outputVolume, 0.6)
        XCTAssertFalse(h.log.messages.contains { $0.contains("late") })
    }

    func test_neverMonitoredMeansNoCallbackAndTheVolumeIsReadOnRefreshAsBefore() async {
        let (h, calls) = await harness()
        h.audio.changeVolume(to: 0.1)
        XCTAssertEqual(h.audio.monitoringStarts, 0)
        XCTAssertEqual(h.service.deliveryStatus.outputVolume, 0.8, "not observed")
        let status = await h.service.refreshDeliveryStatus()
        XCTAssertEqual(status.outputVolume, 0.1, "refreshDeliveryStatus still reads it")
        XCTAssertEqual(status.problems, [.alarmVolumeLow(0.1)])
        XCTAssertEqual(calls.value, 0, "a refresh's caller reads the status itself")
    }

    func test_anUnknownVolumeHasNoVolumeProblem() {
        XCTAssertNil(AlertDeliveryStatus.volumeProblem(nil))
        XCTAssertEqual(AlertDeliveryStatus.volumeProblem(0.2), .alarmVolumeLow(0.2))
    }

    // MARK: - Alarms are unchanged (S7)

    /// The same urgent low, repeat and acknowledgement with monitoring on and off: the same sounds,
    /// stops and notifications.
    func test_S7_urgentLowSoundsTheSameWithVolumeMonitoringOnOrOff() async {
        func run(monitoring: Bool) async -> (plays: [String], loops: [TimeInterval], stops: Int, posted: [String], pending: Int) {
            let h = ServiceHarness()
            await h.service.start()
            h.service.setVolumeMonitoring(monitoring)
            await h.reading(.mgdl(50))
            h.audio.finish()
            await h.advance(minutes: 5)
            if monitoring { h.audio.changeVolume(to: 0.1) }
            let userInfo = h.center.posted.last?.userInfo ?? [:]
            await h.service.handleNotificationResponse(.opened, userInfo: userInfo)
            return (h.audio.plays.map(\.fileName), h.audio.plays.map(\.loopSeconds), h.audio.stops,
                    h.center.posted.map(\.identifier), h.center.pending(for: .urgentLow).count)
        }
        let off = await run(monitoring: false)
        let on = await run(monitoring: true)
        XCTAssertEqual(off.plays, ["alert-cascade.wav", "alert-cascade.wav"])
        XCTAssertEqual(on.plays, off.plays)
        XCTAssertEqual(on.loops, [30, 30])
        XCTAssertEqual(on.loops, off.loops)
        XCTAssertEqual(on.stops, off.stops)
        XCTAssertEqual(on.posted, off.posted)
        XCTAssertEqual(on.pending, off.pending)
    }

    /// Foreground ↔ background while the urgent-low loop plays: the sound is never stopped or
    /// replaced, and the acknowledgement still stops it.
    func test_S7_togglingVolumeMonitoringWhileUrgentLowPlaysNeverStopsIt() async {
        let h = ServiceHarness()
        await h.service.start()
        h.service.setVolumeMonitoring(true)
        await h.reading(.mgdl(50))
        XCTAssertTrue(h.audio.isPlaying)
        h.service.setVolumeMonitoring(false)
        h.service.setVolumeMonitoring(true)
        h.audio.changeVolume(to: 0.1)
        h.service.setVolumeMonitoring(false)
        XCTAssertTrue(h.audio.isPlaying)
        XCTAssertEqual(h.audio.plays.count, 1)
        XCTAssertEqual(h.audio.stops, 0)
        XCTAssertEqual(h.service.executor.soundOwner, .urgentLow)
        XCTAssertEqual(h.service.phase(of: .urgentLow), .firing(since: Fixtures.t0))
        await h.service.handleNotificationResponse(.opened, userInfo: h.center.posted.last?.userInfo ?? [:])
        XCTAssertEqual(h.audio.stops, 1)
        XCTAssertFalse(h.audio.isPlaying)
    }
}
