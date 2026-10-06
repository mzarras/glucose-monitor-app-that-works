import XCTest
import GlucoseCore
@testable import AlertEngine

/// D26: urgent low and its repeats as AlarmKit system alarms (iOS 26+, authorized), through the
/// service with a fake AlarmKit port.
@MainActor
final class SystemAlarmTests: XCTestCase {
    /// After acknowledging an urgent low fired at t0: the snooze-end alarm at +30 and the 5-minute
    /// grid after it for an hour (D44).
    static let snoozeEndGrid = (0..<12).map { Fixtures.t0.addingTimeInterval(minutes(30) + Double($0) * minutes(5)) }

    func test_urgentLowRingsAsASystemAlarmWithRepeatsWhenAllowed() async throws {
        let alarms = FakeSystemAlarms()
        let h = ServiceHarness(alarms: alarms)
        await h.service.start()
        await h.reading(.mgdl(50))

        let immediate = try XCTUnwrap(alarms.scheduled[SystemAlarmIDs.immediate])
        XCTAssertEqual(immediate.fireDate, Fixtures.t0.addingTimeInterval(SystemAlarmIDs.minimumLeadTime), "a fixed alarm at now never rings: +2 s")
        XCTAssertEqual(immediate.soundFileName, "alert-cascade.caf")
        XCTAssertEqual(immediate.title, "Urgent low")
        XCTAssertEqual(alarms.repeatAlarms.map(\.fireDate), (1...12).map { Fixtures.t0.addingTimeInterval(Double($0) * minutes(5)) },
                       "repeat alarms at the same slots as the pending notifications, 60 minutes ahead")
        XCTAssertEqual(alarms.repeatAlarms.first?.id, SystemAlarmIDs.repeatSlot(0))
        XCTAssertTrue(h.audio.plays.isEmpty, "no in-app sound on top of the alarm")
        XCTAssertEqual(h.center.posted.last?.interruption, .timeSensitive, "the notification is still posted: visual, actions")
        XCTAssertEqual(h.center.pending(for: .urgentLow).count, 12)
        XCTAssertEqual(h.service.deliveryStatus.problems, [])
    }

    func test_acknowledgeAndRecoveryCancelEveryAlarm() async {
        let alarms = FakeSystemAlarms()
        let h = ServiceHarness(alarms: alarms)
        await h.service.start()
        await h.reading(.mgdl(50))
        await h.service.send(.user(.acknowledge(.urgentLow)))
        XCTAssertEqual(alarms.scheduled.values.map(\.fireDate).sorted(), Self.snoozeEndGrid,
                       "every old alarm is cancelled; exactly the snooze-end alarm and its grid remain (D44)")

        h.clock.advance(minutes: 31)
        await h.reading(.mgdl(50))
        XCTAssertFalse(alarms.scheduled.isEmpty, "fires again after the snooze")
        h.clock.advance(minutes: 5)
        await h.reading(.mgdl(90))
        XCTAssertTrue(alarms.scheduled.isEmpty, "recovery removes them")
    }

    func test_awakeRepeatWithAlarmsDoesNotPlayTheInAppSound() async {
        let alarms = FakeSystemAlarms()
        let h = ServiceHarness(alarms: alarms)
        await h.reading(.mgdl(50))
        await h.advance(minutes: 5)
        XCTAssertTrue(h.audio.plays.isEmpty, "the repeat alarm for that slot rang")
        XCTAssertNotNil(alarms.alarm(firingAt: Fixtures.t0.addingTimeInterval(minutes(5))), "the due alarm is left alone")
        XCTAssertEqual(alarms.repeatAlarms.last?.fireDate, Fixtures.t0.addingTimeInterval(minutes(65)), "and the tail rolled forward")
        XCTAssertNotNil(alarms.scheduled[SystemAlarmIDs.immediate], "rescheduling repeats leaves the immediate alarm alone")
    }

    func test_launchCancelsLeftoverAlarmsUnlessUrgentLowIsFiring() async throws {
        let alarms = FakeSystemAlarms()
        let h = ServiceHarness(alarms: alarms)
        await h.service.start()
        XCTAssertEqual(alarms.cancelAllCalls, 1, "not firing: whatever a previous process left is cancelled")

        await h.reading(.mgdl(50))
        let snapshot = try XCTUnwrap(h.snapshots.last)
        let relaunchAlarms = FakeSystemAlarms()
        let relaunched = ServiceHarness(snapshot: snapshot, alarms: relaunchAlarms)
        relaunched.clock.advance(minutes: 1)
        await relaunched.service.start()
        XCTAssertEqual(relaunchAlarms.cancelAllCalls, 0)
        XCTAssertEqual(relaunchAlarms.repeatAlarms.count, 12, "firing: the repeat alarms are rebuilt")
    }

    func test_S5_alarmSchedulingFailureFallsBackAndSurfaces() async {
        let alarms = FakeSystemAlarms()
        alarms.failWith = FakeSystemAlarms.Refused()
        let h = ServiceHarness(alarms: alarms)
        await h.service.start()
        await h.reading(.mgdl(50))
        XCTAssertEqual(h.audio.plays.map(\.fileName), ["alert-cascade.wav"], "falls back to the in-app sound")
        XCTAssertEqual(h.audio.plays.first?.loopSeconds, AlertLimits.urgentInAppAudioSeconds)
        XCTAssertEqual(h.center.posted.last?.sound, .named(fileName: "alert-cascade.wav"))
        XCTAssertEqual(h.center.pending(for: .urgentLow).count, 12, "pending notifications still carry the repeats")
        XCTAssertEqual(h.service.deliveryStatus.problems, [.urgentLowAlarmFailed("maximumLimitReached")])
        XCTAssertTrue(h.log.messages.contains { $0.contains("urgent-low alarm") && $0.contains("FAILED") })

        alarms.failWith = nil
        h.clock.advance(minutes: 5)
        await h.reading(.mgdl(90))   // recovers
        h.clock.advance(minutes: 5)
        await h.reading(.mgdl(50))   // a new urgent low: alarms schedule again
        XCTAssertNotNil(alarms.scheduled[SystemAlarmIDs.immediate])
        XCTAssertEqual(h.service.deliveryStatus.problems, [], "cleared once alarms schedule again")
    }

    func test_S5_aPartialRepeatFailureIsSurfaced() async {
        let alarms = FakeSystemAlarms()
        alarms.failWith = FakeSystemAlarms.Refused()
        alarms.failFromCall = 5   // immediate + 4 repeats succeed, the rest are refused
        let h = ServiceHarness(alarms: alarms)
        await h.reading(.mgdl(50))
        XCTAssertEqual(alarms.repeatAlarms.count, 4)
        XCTAssertEqual(h.service.deliveryStatus.problems, [.urgentLowAlarmFailed("maximumLimitReached")])
        XCTAssertEqual(h.center.pending(for: .urgentLow).count, 12)
    }

    func test_S7_alarmStopCannotSnoozePast30Minutes() async {
        var settings = AlertSettings.defaults
        settings.urgentLow.snoozeMinutes = 30
        let alarms = FakeSystemAlarms()
        let h = ServiceHarness(settings: settings, alarms: alarms)
        let bridge = UrgentLowAlarmIntentBridge()
        await bridge.connect { [service = h.service!] action in await service.send(.user(action)) }
        await h.reading(.mgdl(50))

        await bridge.stopTapped()
        XCTAssertEqual(h.service.phase(of: .urgentLow), .snoozed(until: Fixtures.t0.addingTimeInterval(minutes(30))), "Stop = acknowledge")
        XCTAssertEqual(alarms.scheduled.values.map(\.fireDate).sorted(), Self.snoozeEndGrid,
                       "the remaining repeat alarms are cancelled; exactly the snooze-end alarm (≤ 30 min) and its grid remain (D44)")

        h.clock.advance(minutes: 31)
        await h.reading(.mgdl(50))
        await bridge.snoozeTapped(minutes: 600)
        XCTAssertEqual(h.service.phase(of: .urgentLow), .snoozed(until: h.clock.now.addingTimeInterval(minutes(30))), "a Snooze button is clamped too")
    }

    func test_alarmStopTappedBeforeTheServiceConnectsIsDelivered() async {
        let h = ServiceHarness(alarms: FakeSystemAlarms())
        await h.reading(.mgdl(50))
        let bridge = UrgentLowAlarmIntentBridge()
        await bridge.stopTapped()   // the system launched the app to run the intent
        XCTAssertEqual(h.service.phase(of: .urgentLow), .firing(since: Fixtures.t0))
        await bridge.connect { [service = h.service!] action in await service.send(.user(action)) }
        XCTAssertEqual(h.service.phase(of: .urgentLow), .snoozed(until: Fixtures.t0.addingTimeInterval(minutes(30))))
    }

    func test_urgentLowAlarmAuthorizationStatesForTheSettingsRow() async {
        let alarms = FakeSystemAlarms()
        alarms.authorization = .notDetermined
        let h = ServiceHarness(alarms: alarms)
        XCTAssertEqual(h.service.deliveryStatus.urgentLowAlarm, .notDetermined)
        XCTAssertEqual(h.service.deliveryStatus.problems, [.notificationsNotRequested, .urgentLowAlarmNotRequested])

        await h.service.start()
        await h.reading(.mgdl(50))
        XCTAssertTrue(alarms.scheduled.isEmpty, "not allowed yet: D17 path")
        XCTAssertEqual(h.audio.plays.count, 1)

        alarms.authorizationAfterRequest = .authorized
        let status = await h.service.requestUrgentLowAlarmAuthorization()
        XCTAssertEqual(status.urgentLowAlarm, .authorized)
        XCTAssertEqual(alarms.repeatAlarms.count, 12, "allowing alarms rebuilds the pending repeats as alarms")

        alarms.authorization = .denied
        let denied = await h.service.refreshDeliveryStatus()
        XCTAssertEqual(denied.problems, [.urgentLowAlarmDenied])

        let old = ServiceHarness()   // iOS < 26: no alarm port at all
        XCTAssertEqual(old.service.deliveryStatus.urgentLowAlarm, .unavailable)
        let unavailable = FakeSystemAlarms()
        unavailable.authorization = .unavailable
        XCTAssertFalse(ServiceHarness(alarms: unavailable).service.deliveryStatus.problems.contains(.urgentLowAlarmDenied))
    }

    func test_otherAlertsNeverScheduleAlarms() async {
        let alarms = FakeSystemAlarms()
        let h = ServiceHarness(alarms: alarms)
        await h.service.start()
        await h.reading(.mgdl(65))
        await h.service.send(.sensorState(.bluetoothUnavailable(.poweredOff)))
        await h.advance(minutes: 20)
        XCTAssertTrue(alarms.scheduled.isEmpty)
        XCTAssertEqual(alarms.scheduleCalls, 0)
    }

    // MARK: Safety review minors

    func test_S7_lockScreenSnoozeOf600MinutesIsClampedTo30() async {
        let h = ServiceHarness()
        await h.service.start()
        await h.reading(.mgdl(50))
        await h.service.handleNotificationResponse(
            .action(AlertNotificationIDs.snoozeAction), userInfo: ["alertKind": "urgentLow", "snoozeMinutes": "600"])
        XCTAssertEqual(h.service.phase(of: .urgentLow), .snoozed(until: Fixtures.t0.addingTimeInterval(minutes(30))))
    }

    func test_permissionsAreReadOnEveryInputSoUrgentLowUsesTheCurrentLevel() async {
        let h = ServiceHarness()
        await h.service.start()
        let checks = h.center.permissionChecks
        await h.service.send(.tick)
        XCTAssertEqual(h.center.permissionChecks, checks + 1)
        h.center.permissions.criticalAlerts = .enabled   // granted in Settings while the app slept
        await h.reading(.mgdl(50))
        XCTAssertEqual(h.center.posted.last?.interruption, .critical, "the wake that delivers urgent low sees the grant")
    }
}
