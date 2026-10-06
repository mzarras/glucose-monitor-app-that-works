import XCTest
import GlucoseCore
@testable import AlertEngine

/// The service end to end with fake notification center and audio player: what is posted, what
/// is pending, what plays, in what order.
@MainActor
final class ServiceHarness {
    let clock: TestClock
    let center: FakeNotificationCenter
    let audio = FakeAudioPlayer()
    let log = RecordingDiagnosticLog()
    let alarms: FakeSystemAlarms?
    private(set) var snapshots: [AlertEngineSnapshot] = []
    private(set) var service: AlertService!

    /// Pass `center`, `alarms` and `clock` from another harness to simulate a relaunch: the system
    /// keeps its pending notifications and alarms across processes.
    init(settings: AlertSettings = .defaults, snapshot: AlertEngineSnapshot? = nil, alarms: FakeSystemAlarms? = nil,
         center: FakeNotificationCenter? = nil, clock: TestClock? = nil) {
        self.clock = clock ?? TestClock()
        self.center = center ?? FakeNotificationCenter()
        self.alarms = alarms
        service = AlertService(
            settings: settings, restoring: snapshot, configuration: Fixtures.configuration, clock: self.clock,
            notificationCenter: self.center, audio: audio, systemAlarms: alarms, diagnostics: log,
            onSnapshot: { [weak self] in self?.snapshots.append($0) }
        )
    }

    func reading(_ value: GlucoseValue, source: ReadingSource = .sensor) async {
        await service.send(.reading(Fixtures.reading(value, at: clock.now, source: source), session: Fixtures.session))
    }

    func advance(minutes m: Double) async {
        clock.advance(minutes: m)
        await service.send(.tick)
    }
}

@MainActor
final class AlertServiceTests: XCTestCase {
    func test_startRegistersCategoriesAndSchedulesMissedReadings() async {
        let h = ServiceHarness()
        await h.service.start()
        XCTAssertEqual(h.center.categoriesRegistered, 1)
        let pending = h.center.pending(for: .missedReadings)
        XCTAssertEqual(pending.count, 12)
        XCTAssertEqual(pending.first?.fireDate, Fixtures.t0.addingTimeInterval(minutes(15)))
        XCTAssertEqual(pending.first?.interruption, .timeSensitive)
        XCTAssertEqual(pending.first?.sound, .named(fileName: "alert-sonar.wav"))
        XCTAssertEqual(h.service.settings, .defaults)
        XCTAssertEqual(h.service.phase(of: .missedReadings), .armed)
    }

    func test_urgentLowWithoutCriticalAlerts_postsTimeSensitivePlaysInAppSoundAndSchedulesRepeats() async {
        let h = ServiceHarness()
        await h.service.start()
        await h.reading(.mgdl(50))
        let posted = try? XCTUnwrap(h.center.posted.last)
        XCTAssertEqual(posted?.identifier, "sensor.alert.urgentLow")
        XCTAssertEqual(posted?.interruption, .timeSensitive)
        XCTAssertEqual(posted?.sound, .named(fileName: "alert-cascade.wav"))
        XCTAssertEqual(h.audio.plays.map(\.fileName), ["alert-cascade.wav"])
        XCTAssertEqual(h.audio.plays.map(\.loopSeconds), [30])
        XCTAssertEqual(h.service.executor.soundOwner, .urgentLow)
        let repeats = h.center.pending(for: .urgentLow)
        XCTAssertEqual(repeats.map(\.fireDate), (1...12).map { Fixtures.t0.addingTimeInterval(Double($0) * minutes(5)) })
        XCTAssertTrue(repeats.allSatisfy { $0.interruption == .timeSensitive && $0.sound == .named(fileName: "alert-cascade.wav") })
    }

    func test_urgentLowUsesCriticalDeliveryWhenGranted() async {
        let h = ServiceHarness()
        h.center.permissions.criticalAlerts = .enabled
        await h.service.start()
        await h.reading(.mgdl(50))
        XCTAssertEqual(h.center.posted.last?.interruption, .critical)
        XCTAssertEqual(h.center.posted.last?.sound, .critical(fileName: "alert-cascade.wav", volume: 1.0))
        XCTAssertTrue(h.audio.plays.isEmpty, "the system plays a Critical Alert; no second sound")
        XCTAssertTrue(h.center.pending(for: .urgentLow).allSatisfy { $0.interruption == .critical })
    }

    func test_repeatWhileAwakePlaysTheSoundAgain() async {
        let h = ServiceHarness()
        await h.service.start()
        await h.reading(.mgdl(50))
        h.audio.finish()
        await h.advance(minutes: 5)
        XCTAssertEqual(h.audio.plays.count, 2)
        XCTAssertEqual(h.center.posted.count, 1, "the repeat's notification was already pending")
    }

    func test_acknowledgingFromTheNotificationRemovesEverythingAndStopsTheSound() async {
        let h = ServiceHarness()
        await h.service.start()
        await h.reading(.mgdl(50))
        let userInfo = h.center.posted.last?.userInfo ?? [:]
        await h.service.handleNotificationResponse(.opened, userInfo: userInfo)
        XCTAssertNil(h.center.delivered["sensor.alert.urgentLow"])
        XCTAssertEqual(h.center.pending(for: .urgentLow).compactMap(\.fireDate).min(), Fixtures.t0.addingTimeInterval(minutes(30)),
                       "the repeats are gone; only the snooze-end alarm and its grid are pending (D44)")
        XCTAssertEqual(h.audio.stops, 1)
        XCTAssertNil(h.service.executor.soundOwner)
        XCTAssertEqual(h.service.phase(of: .urgentLow), .snoozed(until: Fixtures.t0.addingTimeInterval(minutes(30))))
    }

    func test_swipingAwayOnlyStopsTheSound() async {
        let h = ServiceHarness()
        await h.service.start()
        await h.reading(.mgdl(50))
        await h.service.handleNotificationResponse(.dismissed, userInfo: ["alertKind": "urgentLow"])
        XCTAssertEqual(h.audio.stops, 1)
        XCTAssertEqual(h.center.pending(for: .urgentLow).count, 12, "repeats stay")
        XCTAssertEqual(h.service.phase(of: .urgentLow), .firing(since: Fixtures.t0))
        await h.service.handleNotificationResponse(.opened, userInfo: ["alertKind": "nope"])
        XCTAssertEqual(h.service.phase(of: .urgentLow), .firing(since: Fixtures.t0), "foreign responses change nothing")
    }

    func test_aLessImportantAlertDoesNotCutOffTheUrgentLowSound() async {
        let h = ServiceHarness()
        await h.service.start()
        await h.reading(.mgdl(50))
        await h.service.send(.sensorState(.bluetoothUnavailable(.poweredOff)))
        XCTAssertEqual(h.audio.plays.map(\.fileName), ["alert-cascade.wav"])
        XCTAssertTrue(h.log.messages.contains { $0.contains("kept for urgentLow") })
        XCTAssertNotNil(h.center.delivered["sensor.alert.bluetoothUnavailable"], "its notification is still posted")
        // Cancelling the lesser alert does not stop the urgent sound either.
        await h.service.send(.sensorState(.searching))
        XCTAssertEqual(h.audio.stops, 0)
        h.audio.finish()
        await h.service.send(.sensorState(.bluetoothUnavailable(.poweredOff)))
        XCTAssertEqual(h.audio.plays.last?.fileName, "alert-warble.wav", "once the urgent sound has ended, others may play")
    }

    func test_previewNeverInterruptsAnAlert() async {
        let h = ServiceHarness()
        XCTAssertTrue(h.service.previewSound(.tide))
        XCTAssertEqual(h.audio.plays.last?.fileName, "alert-tide.wav")
        XCTAssertEqual(h.audio.plays.last?.loopSeconds, 0)
        h.service.stopPreview()
        XCTAssertEqual(h.audio.stops, 1)
        await h.reading(.mgdl(50))
        XCTAssertFalse(h.service.previewSound(.tide))
        h.service.stopPreview()
        XCTAssertEqual(h.audio.stops, 1, "stopping a preview never stops an alarm")
    }

    func test_snapshotIsHandedOverAfterEveryInput() async {
        let h = ServiceHarness()
        await h.service.send(.tick)
        await h.reading(.mgdl(120))
        await h.service.send(.trioBridge(.healthy))
        XCTAssertEqual(h.snapshots.count, 3)
        XCTAssertEqual(h.snapshots.last, h.service.engine.snapshot)
    }

    func test_deliveryFailuresAreLoggedAndDoNotChangeAlertState() async {
        let h = ServiceHarness()
        h.center.failAdds = true
        h.audio.startsSuccessfully = false
        await h.reading(.mgdl(50))
        XCTAssertTrue(h.log.messages.contains { $0.contains("notification sensor.alert.urgentLow FAILED") })
        XCTAssertTrue(h.log.messages.contains { $0.contains("in-app sound FAILED") })
        XCTAssertNil(h.service.executor.soundOwner)
        XCTAssertEqual(h.service.phase(of: .urgentLow), .firing(since: Fixtures.t0), "still firing; it repeats")
    }

    func test_S5_requestAuthorizationReportsDeniedNotificationsAndMutedVolume() async {
        let h = ServiceHarness()
        h.center.permissionsAfterRequest = NotificationPermissionState(
            authorization: .denied, alerts: .disabled, sounds: .disabled, criticalAlerts: .notSupported, timeSensitive: .disabled)
        h.audio.outputVolume = 0
        let status = await h.service.requestAuthorization()
        XCTAssertEqual(h.center.authorizationRequests, 1)
        XCTAssertEqual(status.problems, [.notificationsDenied, .alarmVolumeMuted])
        XCTAssertEqual(h.service.deliveryStatus, status)
    }

    func test_grantingCriticalAlertsRebuildsPendingNotifications() async {
        let h = ServiceHarness()
        await h.service.start()
        await h.reading(.mgdl(50))
        XCTAssertTrue(h.center.pending(for: .urgentLow).allSatisfy { $0.interruption == .timeSensitive })
        h.center.permissions.criticalAlerts = .enabled
        let status = await h.service.refreshDeliveryStatus()
        XCTAssertTrue(status.permissions.criticalAlertsEnabled)
        XCTAssertEqual(h.center.pending(for: .urgentLow).count, 12)
        XCTAssertTrue(h.center.pending(for: .urgentLow).allSatisfy { $0.interruption == .critical })
        XCTAssertTrue(h.center.pending(for: .missedReadings).allSatisfy { $0.interruption == .critical }, "missed readings sounds on silent by default")
    }

    func test_S6_serviceRefusesAnImportedReadingAndSaysSo() async {
        let h = ServiceHarness()
        await h.reading(.mgdl(45), source: .imported(.clarityCSV))
        XCTAssertTrue(h.center.posted.isEmpty)
        XCTAssertTrue(h.audio.plays.isEmpty)
        XCTAssertTrue(h.log.messages.contains { $0.contains("refused") && $0.contains("notLiveSensor") })
    }

    func test_quietHoursDeliverSilently() async {
        var settings = AlertSettings.defaults
        settings.quietHours = QuietHours(isEnabled: true, startMinuteOfDay: 11 * 60, endMinuteOfDay: 13 * 60)
        let h = ServiceHarness(settings: settings)
        await h.reading(.mgdl(65))
        XCTAssertEqual(h.center.posted.last?.interruption, .passive)
        XCTAssertEqual(h.center.posted.last?.sound, NotificationSoundChoice.none)
        XCTAssertTrue(h.audio.plays.isEmpty)
    }

    func test_missedReadingsDueWhileAwakePlaysItsSound() async {
        let h = ServiceHarness()
        await h.service.start()
        await h.advance(minutes: 15)
        XCTAssertEqual(h.audio.plays.map(\.fileName), ["alert-sonar.wav"])
        XCTAssertTrue(h.center.posted.isEmpty, "the pending notification is the one that shows")
    }

    func test_turningAnAlertOffRemovesOnlyPendingForCancelScheduled() async {
        let h = ServiceHarness()
        await h.service.start()
        var settings = h.service.settings
        settings.missedReadings.isEnabled = false
        await h.service.send(.settings(settings))
        XCTAssertTrue(h.center.pending(for: .missedReadings).isEmpty)
        XCTAssertTrue(h.log.messages.contains("cancel 12 pending missedReadings"))
    }

    func test_ignoredUserActionsAreLogged() async {
        let h = ServiceHarness()
        await h.service.send(.user(.snooze(.urgentLow, minutes: 30)))
        XCTAssertTrue(h.log.messages.contains { $0.hasPrefix("ignored") })
    }

    func test_executorDescribesEachPath() {
        XCTAssertEqual(AlertDeliveryExecutor.describe(DeliveryDecision(interruption: .passive, notificationSound: .none, inAppSound: nil)), "passive (quiet hours)")
        XCTAssertEqual(AlertDeliveryExecutor.describe(DeliveryDecision(interruption: .critical, notificationSound: .none, inAppSound: nil)), "critical")
        XCTAssertEqual(AlertDeliveryExecutor.describe(DeliveryDecision(interruption: .active, notificationSound: .none, inAppSound: nil)), "active, no sound")
        XCTAssertEqual(AlertDeliveryExecutor.describe(DeliveryDecision(interruption: .timeSensitive, notificationSound: .none,
                                                                       inAppSound: InAppSound(fileName: "x", loopSeconds: 0))), "time-sensitive + in-app sound")
    }

    func test_systemClockTellsTheTime() {
        let before = Date()
        let now = SystemAlertClock().now
        XCTAssertGreaterThanOrEqual(now, before)
    }
}
