// DEBUG `-silenceAlertAudio` (UI tests, simulator runs): the flag selects silent alert outputs,
// and only the audible part changes.

#if DEBUG
import AlertEngine
import Foundation
import GlucoseCore
import UserNotifications
import XCTest
@testable import Sensor

@MainActor
final class SilentAlertAudioTests: XCTestCase {
    func test_silenceAlertAudioFlagSelectsTheSilentOutputs() {
        let silenced = AppEnvironment.makeAlertPorts(arguments: ["Sensor", "-silenceAlertAudio"], diagnostics: NullDiagnosticLog())
        XCTAssertTrue(silenced.audio is SilentAlertAudioPlayer)
        XCTAssertTrue(silenced.notificationCenter is SilentNotificationCenter)
        XCTAssertTrue(silenced.alarms is SilentSystemAlarms)
        XCTAssertTrue(silenced.haptics is NoAlertHaptics, "D53: no vibration either")

        let normal = AppEnvironment.makeAlertPorts(arguments: ["Sensor"], diagnostics: NullDiagnosticLog())
        XCTAssertTrue(normal.audio is PlaybackAlertAudioPlayer)
        XCTAssertTrue(normal.notificationCenter is UserNotificationCenterAdapter)
        XCTAssertTrue(normal.alarms is SystemAlarmAdapter)
        XCTAssertNil(normal.haptics, "nil: AlertService uses the system vibration (SystemAlertHaptics)")
    }

    func test_silentPlayerPlaysNothingButReportsSuccess() {
        let player = SilentAlertAudioPlayer(volumeSource: RecordingAudioPlayer(clock: PipelineTestClock(PipelineFixtures.start)))
        XCTAssertTrue(player.play(fileName: AlertSoundCatalog.fileName(.cascade), loopSeconds: 30))
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.silencedPlays, ["alert-cascade.wav"])
        XCTAssertEqual(player.outputVolume, 0.8, "the real media volume, so the volume warning still works")
    }

    /// D55: silenced runs see the real volume live too; the real player is never asked to play.
    func test_silentPlayerForwardsVolumeMonitoringToTheRealPlayer() {
        let real = RecordingAudioPlayer(clock: PipelineTestClock(PipelineFixtures.start))
        let player = SilentAlertAudioPlayer(volumeSource: real)
        var events: [VolumeMonitoringEvent] = []
        player.startVolumeMonitoring { events.append($0) }
        XCTAssertTrue(real.isMonitoringVolume)
        real.changeVolume(to: 0.1)
        XCTAssertEqual(events, [.changed(0.8), .changed(0.1)])
        XCTAssertEqual(player.outputVolume, 0.1)
        XCTAssertTrue(player.play(fileName: AlertSoundCatalog.fileName(.cascade), loopSeconds: 30))
        XCTAssertTrue(real.plays.isEmpty, "never audible")
        player.stopVolumeMonitoring()
        XCTAssertFalse(real.isMonitoringVolume)
        real.changeVolume(to: 0.6)
        XCTAssertEqual(events, [.changed(0.8), .changed(0.1)])
    }

    /// D43: an announcement whose sound is off is an `.active` notification without sound; the
    /// silent adapter keeps the level.
    func test_silentNotificationMapsTheActiveLevel() {
        let notice = AlertNotice(
            kind: .sensorExpiringIn24Hours, title: "Sensor expires in 24 h", body: "At 8:15 PM tomorrow", sound: .doorbell,
            soundsOnSilent: false, isSilenced: false, snoozeMinutes: nil, fireDate: nil, style: .silent
        )
        let decision = DeliveryPolicy.decide(for: notice, criticalAlertsEnabled: false, systemAlarmsAvailable: false, timing: .now)
        XCTAssertEqual(decision.interruption, .active)
        let content = SilentNotificationCenter.content(for: NotificationRequestBuilder.request(for: notice, decision: decision))
        XCTAssertEqual(content.interruptionLevel, .active)
        XCTAssertNil(content.sound)
    }

    func test_silentNotificationKeepsEverythingButTheSound() {
        let notice = AlertNotice(
            kind: .urgentLow, title: "Urgent low", body: "49 mg/dL at 12:00", sound: .cascade, soundsOnSilent: true,
            isSilenced: false, snoozeMinutes: 30, fireDate: nil
        )
        let decision = DeliveryDecision(interruption: .timeSensitive, notificationSound: .named(fileName: "alert-cascade.wav"), inAppSound: nil)
        let spec = NotificationRequestBuilder.request(for: notice, decision: decision)
        let content = SilentNotificationCenter.content(for: spec)
        XCTAssertNil(content.sound)
        XCTAssertEqual(content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(content.title, spec.title)
        XCTAssertEqual(content.body, spec.body)
        XCTAssertEqual(content.categoryIdentifier, spec.categoryIdentifier)
        XCTAssertEqual(content.threadIdentifier, spec.threadIdentifier)
        XCTAssertEqual(content.userInfo as? [String: String], spec.userInfo)
    }
}
#endif
