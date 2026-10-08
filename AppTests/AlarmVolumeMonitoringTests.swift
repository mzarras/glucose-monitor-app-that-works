// D55: while the app is in the foreground the active alert service observes the media volume live,
// so Settings' "Alarm volume" row and warning follow the volume buttons without a relaunch; in the
// background nothing is observed. Drives the real `LiveAppServices` with the recording audio player
// (`RecordingAudioPlayer.changeVolume(to:)` is a press of a volume button).

import AlertEngine
import Foundation
import GlucoseCore
import XCTest
@testable import Sensor

@MainActor
final class AlarmVolumeMonitoringTests: XCTestCase {
    /// What `stream` announced up to now: the test sends `.appearance` as an end marker (send is
    /// synchronous, so everything announced before it is already in the stream).
    private func announced(_ services: LiveAppServices, _ stream: AsyncStream<ServiceChange>) async -> [ServiceChange] {
        services.send(.appearance)
        var changes: [ServiceChange] = []
        for await change in stream {
            if change == .appearance { break }
            changes.append(change)
        }
        return changes
    }

    func test_D55_inTheForegroundAVolumeChangeReachesSettingsAtOnce() async {
        let persistence = LiveServicesHarness.Persistence(now: Date())
        let harness = LiveServicesHarness(persistence)
        let services = harness.services
        await services.bootstrap()
        XCTAssertFalse(harness.audio.isMonitoringVolume, "not before the app is in the foreground")

        await services.handleForeground()
        defer { services.handleBackground() }
        XCTAssertTrue(harness.audio.isMonitoringVolume)
        XCTAssertEqual(services.productionAlerts?.isMonitoringVolume, true)
        XCTAssertEqual(services.alertDelivery.outputVolume, 0.8)
        XCTAssertEqual(services.alertDelivery.problems, [])

        var stream = services.changes()
        harness.audio.changeVolume(to: 0.1)
        XCTAssertEqual(services.alertDelivery.outputVolume, 0.1)
        XCTAssertEqual(services.alertDelivery.problems, [.alarmVolumeLow(0.1)], "the warning appears")
        var changes = await announced(services, stream)
        XCTAssertTrue(changes.contains(.alertDelivery))

        stream = services.changes()
        harness.audio.changeVolume(to: 0.5)
        XCTAssertEqual(services.alertDelivery.outputVolume, 0.5)
        XCTAssertEqual(services.alertDelivery.problems, [], "the warning clears with no relaunch")
        changes = await announced(services, stream)
        XCTAssertTrue(changes.contains(.alertDelivery))

        services.handleBackground()
        XCTAssertFalse(harness.audio.isMonitoringVolume, "off in the background")
        XCTAssertEqual(services.productionAlerts?.isMonitoringVolume, false)
        stream = services.changes()
        harness.audio.changeVolume(to: 0.1)
        XCTAssertEqual(services.alertDelivery.outputVolume, 0.5, "not observed in the background")
        changes = await announced(services, stream)
        XCTAssertFalse(changes.contains(.alertDelivery))

        // Back in the foreground: the current value is read at once.
        await services.handleForeground()
        XCTAssertTrue(harness.audio.isMonitoringVolume)
        XCTAssertEqual(services.alertDelivery.outputVolume, 0.1)
        XCTAssertEqual(services.alertDelivery.problems, [.alarmVolumeLow(0.1)])
    }

    /// The service is created by bootstrap; it monitors only if the app is in the foreground then.
    func test_D55_bootstrapAfterTheFirstUnlockFollowsTheForeground() async {
        let persistence = LiveServicesHarness.Persistence(now: Date())
        let harness = LiveServicesHarness(persistence, protectedData: false)
        let services = harness.services
        await services.handleForeground()
        defer { services.handleBackground() }
        XCTAssertFalse(services.isBootstrapped, "before the first unlock")
        harness.protectedData.value = true
        harness.sensor.startFails = false
        services.protectedDataDidBecomeAvailable()
        await waitUntil("bootstrapped") { services.isBootstrapped }
        XCTAssertTrue(harness.audio.isMonitoringVolume)
        XCTAssertEqual(services.productionAlerts?.isMonitoringVolume, true)
    }

    // MARK: - Review m3: a background always wins over the foreground work

    /// AppEnvironment's `.active`, then `.background` before the foreground work's Task has run (a
    /// quick switch away): no `.playback` session is left active in the background.
    func test_D55_aBackgroundBeforeTheForegroundWorkRunsWins() async {
        let persistence = LiveServicesHarness.Persistence(now: Date())
        let harness = LiveServicesHarness(persistence)
        let services = harness.services
        await services.bootstrap()
        let foreground = services.sceneBecameActive() // scenePhaseChanged(to: .active)
        XCTAssertTrue(services.isInForeground)
        services.handleBackground() // scenePhaseChanged(to: .background), before that Task ran
        await foreground.value
        XCTAssertFalse(services.isInForeground)
        XCTAssertFalse(harness.audio.isMonitoringVolume, "no monitoring session in the background")
        XCTAssertEqual(services.productionAlerts?.isMonitoringVolume, false)

        // The next activation turns it on as usual.
        await services.sceneBecameActive().value
        XCTAssertTrue(harness.audio.isMonitoringVolume)
        services.handleBackground()
        XCTAssertFalse(harness.audio.isMonitoringVolume)
    }

    /// The background arrives while the foreground work is in flight (held in bootstrap's first
    /// permission read, after the new service has started monitoring): monitoring goes off, and
    /// nothing later in the foreground work turns it back on.
    func test_D55_aBackgroundDuringTheForegroundWorkWins() async {
        let persistence = LiveServicesHarness.Persistence(now: Date())
        let harness = LiveServicesHarness(persistence)
        let services = harness.services
        let gate = OpenGate()
        let held = LiveServicesHarness.Flag(false)
        persistence.center.holdNextPermissionRead = {
            held.value = true
            await gate.wait()
        }
        let foreground = services.sceneBecameActive()
        await waitUntil("the foreground work is held in bootstrap") { held.value }
        XCTAssertFalse(services.isBootstrapped)
        XCTAssertTrue(harness.audio.isMonitoringVolume, "on while the scene is active")
        services.handleBackground()
        XCTAssertFalse(harness.audio.isMonitoringVolume)
        await gate.open()
        await foreground.value
        XCTAssertTrue(services.isBootstrapped)
        XCTAssertFalse(services.isInForeground)
        XCTAssertFalse(harness.audio.isMonitoringVolume, "the rest of the foreground work leaves it off")
        XCTAssertEqual(services.productionAlerts?.isMonitoringVolume, false)
    }

    #if DEBUG
    /// One volume monitor per audio player: it moves to the replay service and back to production.
    func test_D55_aReplayRunHandsTheVolumeMonitorToTheActiveServiceAndBack() async throws {
        let persistence = LiveServicesHarness.Persistence(now: Date())
        let harness = LiveServicesHarness(persistence)
        let services = harness.services
        await services.bootstrap()
        await services.handleForeground()
        defer { services.handleBackground() }
        let production = try XCTUnwrap(services.productionAlerts)

        await services.startReplay(scenario: "steady", speed: 1)
        XCTAssertTrue(services.isReplaying)
        let replay = try XCTUnwrap(services.activeAlerts)
        XCTAssertFalse(replay === production)
        XCTAssertFalse(production.isMonitoringVolume, "the released service let go first")
        XCTAssertTrue(replay.isMonitoringVolume)
        harness.audio.changeVolume(to: 0.1)
        XCTAssertEqual(replay.deliveryStatus.outputVolume, 0.1)
        XCTAssertEqual(services.alertDelivery.outputVolume, 0.1)
        XCTAssertEqual(services.alertDelivery.problems, [.alarmVolumeLow(0.1)])

        await services.stopReplay()
        let resumed = try XCTUnwrap(services.productionAlerts)
        XCTAssertFalse(resumed === production)
        XCTAssertFalse(replay.isMonitoringVolume)
        XCTAssertTrue(resumed.isMonitoringVolume)
        harness.audio.changeVolume(to: 0.7)
        XCTAssertEqual(resumed.deliveryStatus.outputVolume, 0.7)
        XCTAssertEqual(replay.deliveryStatus.outputVolume, 0.1, "the ended run's service hears nothing")
        XCTAssertEqual(services.alertDelivery.outputVolume, 0.7)
        XCTAssertEqual(services.alertDelivery.problems, [])

        services.handleBackground()
        XCTAssertFalse(resumed.isMonitoringVolume)
        XCTAssertFalse(harness.audio.isMonitoringVolume)
    }
    #endif
}
