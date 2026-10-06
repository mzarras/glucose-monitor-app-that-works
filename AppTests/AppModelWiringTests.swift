import AlertEngine
import GlucoseCore
import GlucoseStore
import NightscoutKit
import UIKit
import WidgetCore
import XCTest
@testable import Sensor

/// Test clock the model reads (AppModel.clock).
@MainActor
final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// Waits until `condition` holds (view states that follow `services.changes()` update asynchronously).
@MainActor
func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// The view states `AppModel` builds from `AppServices` (with `PreviewAppServices` as the facade).
@MainActor
final class AppModelWiringTests: XCTestCase {
    private var clock = TestClock(t0)

    /// - Parameter sensorStateArrived: the source's first state has reached the facade (it sends
    ///   `.sensor`); until then `.notPaired` is only the facade's default (review M1).
    private func launch(_ services: PreviewAppServices, arguments: [String] = [], onboardingCompleted: Bool = true,
                        sensorStateArrived: Bool = true, protectedData: ProtectedData = ProtectedData(true)) -> AppModel {
        let defaults = UserDefaults(suiteName: "AppModelWiringTests.\(UUID().uuidString)")!
        let preferences = AppUIPreferences(defaults: defaults)
        preferences.onboardingCompleted = onboardingCompleted
        let clock = self.clock
        let model = AppModel.launch(services: services, arguments: arguments, preferences: preferences, calendar: utcCalendar,
                                    clock: { clock.now }, protectedDataAvailable: { protectedData.available })
        if sensorStateArrived { model.apply(.sensor) }
        return model
    }

    /// Whether the phone's protected data is readable (before the first unlock it isn't).
    @MainActor
    final class ProtectedData {
        var available: Bool
        init(_ available: Bool) { self.available = available }
    }

    private func liveServices(latestAge: Double = 3, value: GlucoseValue = .mgdl(112)) -> PreviewAppServices {
        let readings = series(from: minutes(-30 * 60), to: minutes(-latestAge + 0.01)) { _ in value }
        let services = PreviewAppServices(readings: readings, sensorState: activeSensor, sensorSession: nil)
        services.latestLiveReading = readings.last
        services.previousLiveReading = readings.dropLast().last
        return services
    }

    private func kinds(_ model: AppModel) -> Set<AppBanner.Kind> {
        Set(model.now.banners(now: clock.now, context: testContext).map(\.kind))
    }

    // MARK: - S5

    /// Every problem the facade can report becomes a visible banner on Now (and a tab dot).
    func test_S5_everyServiceHealthProblemBecomesABanner() async {
        let failingStatus: NightscoutKit.UploadStatus = {
            var status = NightscoutKit.UploadStatus(destination: "Nightscout")
            status.consecutiveFailures = 3
            status.lastError = UploadError(.unauthorized, "HTTP 401")
            status.lastErrorAt = minutes(-10)
            return status
        }()
        let enabled = UploaderSummary(isEnabled: true, isConfigured: true, liveOutputsAllowed: true, status: NightscoutKit.UploadStatus(destination: "x"), setupError: nil, problemSince: nil)
        func permissions(_ authorization: NotificationPermissionState.Authorization, alerts: NotificationPermissionState.Setting = .enabled,
                         sounds: NotificationPermissionState.Setting = .enabled, timeSensitive: NotificationPermissionState.Setting = .enabled) -> NotificationPermissionState {
            NotificationPermissionState(authorization: authorization, alerts: alerts, sounds: sounds, criticalAlerts: .notSupported, timeSensitive: timeSensitive)
        }
        let healthyDelivery = AlertDeliveryReport(permissions: permissions(.authorized), outputVolume: 0.8, urgentLowAlarm: .authorized, problems: [])

        typealias Setup = (PreviewAppServices) -> Void
        let cases: [(String, Setup, AppBanner.Kind)] = [
            ("trio write failing", { $0.trio = TrioBridgeSummary.off; $0.trio.isEnabled = true; $0.trio.liveOutputsAllowed = true; $0.trio.appGroupID = "group.trio"; $0.trio.consecutiveFailures = 2; $0.trio.lastErrorDescription = "write failed" }, .trioBridgeFailing),
            ("trio starving", { $0.trio = TrioBridgeSummary.off; $0.trio.isEnabled = true; $0.trio.liveOutputsAllowed = true; $0.trio.appGroupID = "group.trio"; $0.trio.isStarving = true }, .trioBridgeFailing),
            ("trio on, unavailable (m4)", { $0.trio = TrioBridgeSummary.off; $0.trio.isEnabled = true; $0.trio.liveOutputsAllowed = true; $0.trio.unavailableReason = "No Trio App Group" }, .trioBridgeFailing),
            ("trio on, no App Group (m4, defence in depth)", { $0.trio = TrioBridgeSummary.off; $0.trio.isEnabled = true; $0.trio.liveOutputsAllowed = true; $0.trio.appGroupID = nil }, .trioBridgeFailing),
            ("trio heartbeat", { $0.trio = TrioBridgeSummary.off; $0.trio.isEnabled = true; $0.trio.liveOutputsAllowed = true; $0.trio.appGroupID = "group.trio"; $0.trio.heartbeatError = "denied" }, .trioHeartbeatFailing),
            ("nightscout failing", { $0.nightscout.upload = enabled; $0.nightscout.upload.status = failingStatus }, .nightscoutUploadFailing),
            ("nightscout setup error", { $0.nightscout.upload = enabled; $0.nightscout.upload.setupError = "QueueFileInUse" }, .nightscoutUploadFailing),
            ("nightscout on, not set up", { $0.nightscout.upload = enabled; $0.nightscout.upload.isConfigured = false }, .nightscoutUploadFailing),
            ("share failing", { $0.dexcomShare.upload = enabled; $0.dexcomShare.upload.status = failingStatus }, .shareUploadFailing),
            ("share on, not set up", { $0.dexcomShare.upload = enabled; $0.dexcomShare.upload.isConfigured = false }, .shareUploadFailing),
            ("notifications denied", { $0.alertDelivery = AlertDeliveryReport(permissions: permissions(.denied), outputVolume: 0.8, urgentLowAlarm: .authorized, problems: [.notificationsDenied]) }, .notificationsDisabled),
            ("notifications quiet", { $0.alertDelivery = AlertDeliveryReport(permissions: permissions(.provisional), outputVolume: 0.8, urgentLowAlarm: .authorized, problems: []) }, .notificationsDisabled),
            ("notifications not asked", { $0.alertDelivery = AlertDeliveryReport(permissions: permissions(.notDetermined), outputVolume: 0.8, urgentLowAlarm: .authorized, problems: [.notificationsNotRequested]) }, .notificationsNotSetUp),
            ("banners/sounds/time sensitive off", { $0.alertDelivery = AlertDeliveryReport(permissions: permissions(.authorized, alerts: .disabled, sounds: .disabled, timeSensitive: .disabled), outputVolume: 0.8, urgentLowAlarm: .authorized, problems: [.notificationAlertsOff, .notificationSoundsOff, .timeSensitiveOff]) }, .notificationSettingsIncomplete),
            ("volume low", { $0.alertDelivery = AlertDeliveryReport(permissions: permissions(.authorized), outputVolume: 0.1, urgentLowAlarm: .authorized, problems: [.alarmVolumeLow(0.1)]) }, .alarmVolumeTooLow),
            ("volume muted", { $0.alertDelivery = AlertDeliveryReport(permissions: permissions(.authorized), outputVolume: 0, urgentLowAlarm: .authorized, problems: [.alarmVolumeMuted]) }, .alarmVolumeTooLow),
            ("alarms denied", { $0.alertDelivery = AlertDeliveryReport(permissions: permissions(.authorized), outputVolume: 0.8, urgentLowAlarm: .denied, problems: [.urgentLowAlarmDenied]) }, .urgentLowAlarmOff),
            ("alarms not asked", { $0.alertDelivery = AlertDeliveryReport(permissions: permissions(.authorized), outputVolume: 0.8, urgentLowAlarm: .notDetermined, problems: [.urgentLowAlarmNotRequested]) }, .urgentLowAlarmNotSetUp),
            ("alarm scheduling failed", { $0.alertDelivery = AlertDeliveryReport(permissions: permissions(.authorized), outputVolume: 0.8, urgentLowAlarm: .authorized, problems: [.urgentLowAlarmFailed("limit")]) }, .urgentLowAlarmFailed),
            ("repeats short", { $0.alertDelivery = AlertDeliveryReport(permissions: permissions(.authorized), outputVolume: 0.8, urgentLowAlarm: .authorized, problems: [.repeatsNotAllScheduled(.urgentLow, missing: 3)]) }, .alertRepeatsShort),
            ("force-quit gap", { $0.forceQuitGap = ForceQuitGapReport(from: minutes(-300), to: minutes(-200)) }, .forceQuitGap),
            ("store locked", { $0.storage.availability = .waitingForFirstUnlock(heldReadings: 2) }, .storageUnavailable),
            ("store failed", { $0.storage.availability = .failed(message: "disk full") }, .storageUnavailable),
            ("inserts failing (D42)", { $0.storage.availability = .failed(message: "3 reading(s) are held in memory: disk full") }, .storageUnavailable),
            ("bluetooth denied", { $0.bluetoothAuthorization = .denied }, .bluetoothUnauthorized),
            ("bluetooth restricted", { $0.bluetoothAuthorization = .restricted }, .bluetoothUnauthorized),
            ("bluetooth off", { $0.sensorState = .bluetoothUnavailable(.poweredOff) }, .bluetoothOff),
            ("sensor failed", { $0.sensorState = .failed(SensorFailure(kind: .sensorFailed, message: "m")) }, .sensorNeedsReplacement),
            ("pairing lost", { $0.sensorState = .failed(SensorFailure(kind: .bondRemoved, message: "m")) }, .sensorNeedsPairing),
            ("unclassified failure (D37)", { $0.sensorState = .failed(SensorFailure(kind: .other, message: "m")) }, .sensorProblem),
            ("transient failure", { $0.sensorState = .failed(SensorFailure(kind: .otherAppRejected, message: "m")) }, .sensorInterrupted),
            ("sensor error", { $0.sensorState = .error(code: 7, description: "signal") }, .sensorError),
            ("calibration needed", { $0.sensorState = .calibrationNeeded(code: 4) }, .calibrationNeeded),
            ("expired", { $0.sensorState = .expired }, .sensorExpired),
            ("expiring", { $0.sensorState = .active(sessionStart: minutes(-9 * 1_440), expiresAt: minutes(120)) }, .sensorExpiring),
            ("missed readings", { $0.latestLiveReading = sensorReading(minutes(-20), .mgdl(110)) }, .missedReadings),
            ("clock mismatch", { $0.latestLiveReading = sensorReading(minutes(30), .mgdl(110)) }, .missedReadings),
        ]
        // A healthy baseline shows nothing.
        let baseline = liveServices()
        baseline.alertDelivery = healthyDelivery
        baseline.bluetoothAuthorization = .allowed
        XCTAssertEqual(kinds(launch(baseline)), [], "healthy: no banner")

        for (name, setup, kind) in cases {
            let services = liveServices()
            services.alertDelivery = healthyDelivery
            services.bluetoothAuthorization = .allowed
            setup(services)
            let model = launch(services)
            XCTAssertTrue(kinds(model).contains(kind), "\(name): no \(kind) banner in \(kinds(model))")
            XCTAssertFalse(model.now.banners(now: clock.now).isEmpty, "\(name): the Now tab shows a problem dot")
        }
    }

    /// The Trio bridge switched on but unavailable in this build says why, in Settings and as a
    /// failing banner; a failing store (D42) says history isn't saved while alerts and Trio carry on.
    func test_S5_trioUnavailableAndStorageFailureAreExplained() {
        let services = liveServices()
        services.trio = .off
        services.trio.isEnabled = true
        services.trio.liveOutputsAllowed = true
        services.trio.unavailableReason = "This build has no Trio App Group."
        services.storage.availability = .failed(message: "3 reading(s) are held in memory: disk full")
        let model = launch(services)
        XCTAssertEqual(model.settings.trio.unavailableReason, "This build has no Trio App Group.")
        guard case .failing(_, let message) = model.settings.trio.status else { return XCTFail("Trio unavailable reads as failing") }
        XCTAssertEqual(message, "This build has no Trio App Group.")
        let banners = model.now.banners(now: clock.now, context: testContext)
        XCTAssertTrue(banners.contains { $0.kind == .trioBridgeFailing && $0.detail.contains("no Trio App Group") })
        let storage = banners.first { $0.kind == .storageUnavailable }
        XCTAssertEqual(storage?.title, "History isn't being saved")
        XCTAssertTrue(storage?.detail.contains("still reach alerts and Trio") ?? false)
        XCTAssertTrue(SettingsText.storageProblem(model.settings.storageAvailability)?.contains("Alerts and Trio still get new readings") ?? false)
    }

    /// Problems that arrive later, through `changes()`, raise their banner without a relaunch.
    func test_S5_problemsArrivingLaterRaiseTheirBanner() async {
        let services = liveServices()
        let model = launch(services)
        XCTAssertFalse(kinds(model).contains(.trioBridgeFailing))
        services.trio = .off
        services.trio.isEnabled = true
        services.trio.liveOutputsAllowed = true
        services.trio.consecutiveFailures = 1
        services.send(.trio)
        let raised = await eventually { self.kinds(model).contains(.trioBridgeFailing) }
        XCTAssertTrue(raised)
        XCTAssertEqual(model.settings.trio.status, model.now.health.trio, "Settings and Now agree")
    }

    // MARK: - S1

    /// A reading dated ahead of the clock is never the current value — also after the clock has
    /// caught up with it, until a newer reading arrives (latch, S1/S5).
    func test_S1_nowNeverShowsAFutureDatedReadingAsCurrent() async {
        let services = liveServices()
        let future = sensorReading(minutes(10), .mgdl(180))
        services.latestLiveReading = future
        let model = launch(services)
        guard case .clockMismatch = model.now.display(now: clock.now) else { return XCTFail("future-dated reading shown as \(model.now.display(now: clock.now))") }
        guard case .message = NowHero.make(model.now.display(now: clock.now), now: clock.now) else { return XCTFail("hero shows a number") }
        XCTAssertEqual(model.calibration.clockMismatchLatchedFor, future.date, "mirrored into calibration")

        // The clock catches up (the facade's latch is nil in the preview): still not current.
        clock.now = minutes(11)
        model.tick()
        XCTAssertEqual(model.now.clockMismatchLatchedFor, future.date)
        guard case .clockMismatch = model.now.display(now: clock.now) else { return XCTFail("latched reading became current") }
        XCTAssertTrue(services.calls.contains("updateClockMismatchLatch"), "the tick re-evaluates the facade's latch")

        // A newer reading clears it.
        services.latestLiveReading = sensorReading(minutes(15), .mgdl(170))
        clock.now = minutes(16)
        model.apply(.readings)
        guard case .current(let reading) = model.now.display(now: clock.now) else { return XCTFail("a newer reading is current") }
        XCTAssertEqual(reading.value, .mgdl(170))
    }

    /// The facade's persisted latch (e.g. from before a relaunch) is honoured.
    func test_S1_facadeLatchKeepsAReadingFromBeingCurrent() {
        let services = liveServices(latestAge: 2)
        services.clockMismatchLatchedFor = services.latestLiveReading?.date
        let model = launch(services)
        guard case .clockMismatch = model.now.display(now: clock.now) else { return XCTFail("latched reading shown as current") }
        XCTAssertTrue(kinds(model).contains(.missedReadings))
    }

    // MARK: - S6

    /// Imported history is charted and counted, but never the current value — even if it is newer.
    func test_S6_importedHistoryNeverBecomesTheCurrentValue() async {
        let services = liveServices(latestAge: 40)
        let imported = stride(from: -35.0, through: -1, by: 5).map { importedReading(minutes($0), .mgdl(250)) }
        services.readingsStore += imported
        let model = launch(services)
        await model.settle()
        XCTAssertEqual(model.now.latestLiveReading?.date, minutes(-40), "the live reading, not the newer imported ones")
        guard case .noData = model.now.display(now: clock.now) else { return XCTFail("no current value: the live reading is 40 min old") }
        XCTAssertTrue(model.now.chartPoints.contains { $0.date == imported.last?.date }, "imported history is charted")
        XCTAssertEqual(model.calibration.latestLiveReading, model.now.latestLiveReading)

        // Defence in depth: a facade that reported an imported reading as live is refused.
        services.latestLiveReading = imported.last
        services.previousLiveReading = imported.dropLast().last
        model.apply(.readings)
        XCTAssertNil(model.now.latestLiveReading)
        XCTAssertNil(NowMapping.latestLiveReading(imported.last, previous: nil))
    }

    // MARK: - S7

    /// Alert edits through the model cannot turn urgent low off, stop it sounding on silent, or
    /// snooze it longer than 30 minutes — in the view state and in what reaches the engine.
    func test_S7_alertEditsCannotDisableUrgentLowOrExceed30MinSnooze() async {
        let services = liveServices()
        let model = launch(services)
        model.editAlert(.enabled(.urgentLow, false))
        model.editAlert(.snooze(.urgentLow, 120))
        model.editAlert(.soundOnSilent(.urgentLow, false))
        model.editAlert(.snooze(.low, 45))
        await model.settle()
        XCTAssertTrue(services.alertSettings.isEnabled(.urgentLow))
        XCTAssertEqual(services.alertSettings.urgentLow.snoozeMinutes, 30)
        XCTAssertTrue(services.alertSettings.soundsOnSilent(.urgentLow))
        XCTAssertEqual(services.alertSettings.low.snoozeMinutes, 45, "quick successive edits are all kept")
        XCTAssertEqual(services.calls.filter { $0 == "updateAlertSettings" }.count, 4)
        let row = model.alerts.row(.urgentLow)
        XCTAssertEqual(row?.effectiveIsEnabled, true)
        XCTAssertEqual(row?.snoozeMinutes, 30)
        XCTAssertTrue(AlertsText.snoozeOptions(for: .urgentLow, current: row?.snoozeMinutes).allSatisfy { $0 <= 30 })
    }

    // MARK: - Now

    /// "Today so far": TIR, average, and lows overlapping today — including one that began before
    /// midnight (docs/statistics.md, `level1EventCountOverlappingPeriod`).
    func test_todaySoFarCountsALowThatBeganBeforeMidnight() async {
        let midnight = utcCalendar.startOfDay(for: t0)
        clock.now = midnight.addingTimeInterval(42 * 60) // 00:42
        let readings = series(from: midnight.addingTimeInterval(-3 * 3_600), to: clock.now) { date in
            date >= midnight.addingTimeInterval(-20 * 60) ? .mgdl(50) : .mgdl(120) // low from 23:40
        }
        let services = PreviewAppServices(readings: readings, sensorState: activeSensor)
        services.latestLiveReading = readings.last
        services.previousLiveReading = readings.dropLast().last
        let model = launch(services)
        await model.settle()
        XCTAssertEqual(model.now.today.lowCount, 1)
        XCTAssertEqual(model.now.today.timeInRangePercent, 0)
        XCTAssertEqual(model.now.today.averageMgdl, 50)
        XCTAssertEqual(model.now.chartPoints.count, readings.count, "3 h of readings, all within 24 h")
    }

    func test_todaySoFarShowsDashesWithoutReadings() async {
        let services = PreviewAppServices(readings: [], sensorState: activeSensor)
        let model = launch(services)
        await model.settle()
        XCTAssertEqual(model.now.today, TodaySummary(timeInRangePercent: nil, averageMgdl: nil, lowCount: nil))
    }

    /// Sensor row "day X of 10 · time left" from the session while the state is a connection step.
    func test_sensorRowUsesTheSession() {
        let session = SensorSession(serial: "ABC123", start: minutes(-(5 * 1_440 + 16 * 60)), warmUpEndsAt: minutes(-(5 * 1_440 + 15 * 60)),
                                    expiresAt: minutes(4 * 1_440 + 7 * 60 + 20), gracePeriodEndsAt: minutes(4 * 1_440 + 19 * 60 + 20))
        let services = PreviewAppServices(readings: [], sensorState: .searching, sensorSession: session)
        let model = launch(services)
        XCTAssertEqual(SensorStatusText.row(model.now.sensorState, session: model.now.sensorSession, now: t0, context: testContext),
                       "day 6 of 10 · 4d 7h left · searching for sensor")
        XCTAssertEqual(model.settings.sensor.serial, "ABC123")
    }

    /// Fingerstick calibrations are chart markers (never readings, S1); the flow shows the outcome.
    func test_S1_calibrationsAreMarkersAndTheFlowShowsTheOutcome() async {
        let services = liveServices()
        let model = launch(services)
        await model.settle()
        let before = model.now.chartPoints
        XCTAssertFalse(before.isEmpty)
        let request = CalibrationRequest(mgdl: 155, takenAt: minutes(-1))
        model.submitCalibration(request)
        await model.settle()
        _ = await eventually { model.calibration.lastSubmission?.request.id == request.id }
        XCTAssertEqual(model.calibration.lastSubmission?.outcome, .status(.queued))
        XCTAssertEqual(model.now.fingersticks, [FingerstickMarker(date: request.takenAt, mgdl: 155)])
        XCTAssertTrue(model.now.chartPoints == before, "a calibration adds no chart point")
        XCTAssertFalse(model.now.chartPoints.contains { $0.date == request.takenAt })
        XCTAssertEqual(model.now.latestLiveReading?.value, .mgdl(112), "the hero is the sensor's reading")

        services.calibrationRefusal = .invalidTime
        let late = CalibrationRequest(mgdl: 120, takenAt: minutes(-30))
        model.submitCalibration(late)
        await model.settle()
        _ = await eventually { model.calibration.lastSubmission?.request.id == late.id }
        XCTAssertEqual(model.calibration.lastSubmission?.outcome, .refused(.invalidTime))
        XCTAssertEqual(model.calibration.acceptedRange, services.acceptedCalibrationRange)
    }

    // MARK: - Trends

    /// Trends through the model: statistics for the period from the store (GMI only ≥ 14 D).
    func test_trendsFromTheStore() async {
        let readings = series(from: minutes(-20 * 1_440), to: t0) { _ in .mgdl(120) }
        let services = PreviewAppServices(readings: readings, sensorState: activeSensor)
        let model = launch(services)
        model.selectTab(.trends)
        await model.settle()
        XCTAssertEqual(model.trends.period, .fourteenDays)
        XCTAssertEqual(model.trends.timeInRange, 100)
        XCTAssertNotNil(model.trends.gmiPercent)
        model.selectTrendsPeriod(.sevenDays)
        XCTAssertTrue(model.trends.isComputing, "a new period shows progress, not the old numbers")
        XCTAssertNil(model.trends.timeInRange)
        await model.settle()
        XCTAssertFalse(model.trends.isComputing)
        XCTAssertNil(model.trends.gmiPercent, "GMI needs 14 days")
        XCTAssertEqual(model.trends.meanMgdl, 120)
    }

    // MARK: - Settings actions

    func test_settingsActionsCallTheFacade() async {
        let services = liveServices()
        let model = launch(services)
        model.setTrioEnabled(true)
        model.setNightscoutUpload(true)
        model.setShareEnabled(true)
        model.setShareRegion(.outsideUS)
        model.retryUploads()
        model.setRetention(.oneYear)
        model.forgetSensor()
        model.requestNotifications()
        model.requestUrgentLowAlarm()
        model.refreshSettingsSummaries()
        model.setAccent(.rust)
        await model.settle()
        for call in ["setTrioBridgeEnabled(true)", "setNightscoutUploadEnabled(true)", "setDexcomShareEnabled(true)", "setDexcomShareRegion(outsideUS)",
                     "retryUploads", "setRetention(oneYear)", "forgetSensor", "requestNotificationAuthorization",
                     "requestUrgentLowAlarmAuthorization", "refreshAlertDelivery", "refreshStorageSummary", "setAccent(rust)"] {
            XCTAssertTrue(services.calls.contains(call), "\(call) not in \(services.calls)")
        }
        _ = await eventually { model.settings.accent == .rust && model.settings.retention == .oneYear }
        XCTAssertEqual(model.settings.accent, .rust)
        XCTAssertEqual(model.settings.retention, .oneYear)
        XCTAssertEqual(model.settings.trio.isEnabled, true)
        XCTAssertEqual(model.settings.dexcomShare.region, .outsideUS)
    }

    func test_sharingSaveErrorsAreShown() async {
        let services = liveServices()
        let model = launch(services)
        model.saveNightscout(url: "http://insecure.example.com", token: "t")
        model.saveShareCredentials(accountName: "me", password: nil, receiverSerialNumber: "")
        await model.settle()
        XCTAssertEqual(model.settings.feedback.nightscout, "That isn't a valid https:// address for a Nightscout site.")
        XCTAssertEqual(model.settings.feedback.dexcomShare, "Enter the account name, password and receiver serial number.")
        model.saveNightscout(url: "https://ns.example.com", token: "secret")
        model.saveShareCredentials(accountName: "me", password: "pw", receiverSerialNumber: "SM12345678")
        await model.settle()
        XCTAssertEqual(model.settings.feedback.nightscout, "Saved.")
        XCTAssertEqual(model.settings.feedback.dexcomShare, "Saved.")
        _ = await eventually { model.settings.nightscout.hasToken && model.settings.dexcomShare.receiverSerialNumber == "SM12345678" }
        XCTAssertTrue(model.settings.nightscout.hasToken)
        XCTAssertEqual(model.settings.dexcomShare.receiverSerialNumber, "SM12345678")
    }

    /// Exports go to the share sheet; a failure is shown.
    func test_exportsAreHandedToTheShareSheet() async {
        let model = launch(liveServices())
        model.exportAllReadings()
        await model.settle()
        XCTAssertEqual(model.sharedFile?.url.lastPathComponent, "preview-readings.csv")
        model.exportDiagnostics()
        await model.settle()
        XCTAssertEqual(model.sharedFile?.url.lastPathComponent, "preview-diagnostics.txt")
    }

    /// Settings › Sensor: pair a new sensor or pair the worn one again (PairingGuidance offers
    /// which); G7 sessions can't be stopped, so the row is hidden.
    func test_pairingFromSettings() async {
        let services = PreviewAppServices(readings: [], sensorState: .notPaired)
        let model = launch(services)
        XCTAssertFalse(model.settings.sensor.canStopSession)
        model.pairNewSensor(code: "1234")
        XCTAssertTrue(model.settings.sensor.pairingInProgress)
        await model.settle()
        XCTAssertTrue(services.calls.contains("pair(1234)"))
        services.pairingError = .invalidCode
        model.pairNewSensor(code: "12")
        await model.settle()
        XCTAssertEqual(model.settings.feedback.pairing, "Enter the 4 digits printed on the sensor applicator.")
        XCTAssertFalse(model.settings.sensor.pairingInProgress)
    }

    /// Pair again goes to `pairAgain(code:)`; `noSensorToPairAgain` is shown, never retried as a new
    /// pairing (review N2). The stored sensor's serial shows before a session exists.
    func test_pairAgainFromSettings() async {
        let services = liveServices()
        services.sensorState = .failed(SensorFailure(kind: .pairingRejected, message: "Rejected"))
        services.hasStoredSensor = true
        services.storedSensorSerial = "DXCM01-1A2B3C4D"
        let model = launch(services)
        XCTAssertTrue(model.hasStoredSensor)
        XCTAssertEqual(model.settings.sensor.serial, "DXCM01-1A2B3C4D")
        guard case .enterCode(_, _, .pairAgain)? = PairingGuidance.settingsOffer(for: model.settings.sensor.state, failureSince: nil,
                                                                                 hasStoredSensor: model.hasStoredSensor, now: t0) else {
            return XCTFail("Settings offers pair again for a stored sensor")
        }
        model.pairSensorAgain(code: "4321")
        await model.settle()
        XCTAssertTrue(services.calls.contains("pairAgain(4321)"))
        XCTAssertFalse(services.calls.contains("pair(4321)"))

        services.pairingError = .noSensorToPairAgain
        model.pairSensorAgain(code: "4321")
        await model.settle()
        XCTAssertEqual(model.settings.feedback.pairing, OnboardingMapping.pairingErrorText(.noSensorToPairAgain))
        XCTAssertEqual(services.calls.filter { $0 == "pair(4321)" }.count, 0, "never falls back to a new pairing")
    }

    /// Review N1 item 3: a new pairing that has authenticated (a sensor is stored now that wasn't
    /// when it started) retries with `pairAgain(code:)`.
    func test_onboardingPairingContextFollowsHasStoredSensor() async {
        let services = PreviewAppServices(sensorState: .notPaired)
        let model = launch(services, onboardingCompleted: false)
        model.goToOnboardingStep(.pairing)
        model.pairNewSensor(code: "1234")
        await model.settle()
        XCTAssertFalse(model.onboardingPairingContext.authenticatedInThisPairing)
        services.hasStoredSensor = true
        services.sensorState = .failed(SensorFailure(kind: .pairingRejected, message: "m"))
        services.send(.sensor)
        _ = await eventually { model.hasStoredSensor }
        XCTAssertTrue(model.onboardingPairingContext.isNewPairing)
        XCTAssertTrue(model.onboardingPairingContext.authenticatedInThisPairing)
        XCTAssertTrue(model.onboardingPairingContext.canPairAgain)
    }

    /// The Settings failure timer for `credentialsUnavailable` starts when the failure begins.
    func test_failureSinceStartsWithTheFailure() {
        let services = liveServices()
        let model = launch(services)
        XCTAssertNil(model.settings.sensor.failureSince)
        services.sensorState = .failed(SensorFailure(kind: .credentialsUnavailable, message: "m"))
        clock.now = minutes(5)
        model.apply(.sensor)
        XCTAssertEqual(model.settings.sensor.failureSince, minutes(5))
        clock.now = minutes(20)
        model.apply(.sensor)
        XCTAssertEqual(model.settings.sensor.failureSince, minutes(5), "same failure: unchanged")
        services.sensorState = activeSensor
        model.apply(.sensor)
        XCTAssertNil(model.settings.sensor.failureSince)
    }

    /// Review minor 4: the calibration need survives a transient failure and a relaunch.
    func test_calibrationNeedIsKeptThroughTransientFailures() {
        let services = liveServices()
        services.sensorState = .calibrationNeeded(code: 4)
        let defaults = UserDefaults(suiteName: "AppModelWiringTests.\(UUID().uuidString)")!
        let preferences = AppUIPreferences(defaults: defaults)
        preferences.onboardingCompleted = true
        let clock = self.clock
        let model = AppModel.launch(services: services, arguments: [], preferences: preferences, calendar: utcCalendar, clock: { clock.now },
                                    protectedDataAvailable: { true })
        XCTAssertTrue(model.now.sensorNeedsCalibration)
        services.sensorState = .failed(SensorFailure(kind: .clockMismatch, message: "clock"))
        model.apply(.sensor)
        XCTAssertTrue(model.now.sensorNeedsCalibration)
        XCTAssertTrue(kinds(model).contains(.calibrationNeeded))
        let relaunched = AppModel.launch(services: services, arguments: [], preferences: preferences, calendar: utcCalendar, clock: { clock.now },
                                         protectedDataAvailable: { true })
        XCTAssertTrue(relaunched.now.sensorNeedsCalibration, "persisted with the Now state")
        services.sensorState = activeSensor
        relaunched.apply(.sensor)
        XCTAssertFalse(relaunched.now.sensorNeedsCalibration)
    }

    // MARK: - Review M1: in-app pairing is never a trap; nothing offers to pair before the state is known

    /// Every in-app way to pair (hero "Pair a sensor"/"Replace sensor", the replacement and pairing
    /// banners) opens Settings › Sensor — a normal page with the tab bar — never the full-screen
    /// onboarding. Onboarding itself (first launch) can be left from every step.
    func test_inAppPairingCanAlwaysBeDismissed() async {
        let services = liveServices()
        services.sensorState = .failed(SensorFailure(kind: .sensorFailed, message: "Replace it"))
        let model = launch(services)
        for action in [AppBanner.Action.pairSensor, .pairAgain] {
            model.selectTab(.now)
            model.settingsRoute = nil
            model.perform(action)
            XCTAssertNil(model.onboarding, "\(action): no full-screen onboarding from inside the app")
            XCTAssertEqual(model.selectedTab, .settings, "\(action)")
            XCTAssertEqual(model.settingsRoute, .sensor, "\(action)")
        }
        // The page offers what this state needs (a new sensor here), so it is never a dead end.
        XCTAssertNotNil(PairingGuidance.settingsOffer(for: model.settings.sensor.state, failureSince: nil, hasStoredSensor: true, now: t0))
        XCTAssertNotNil(PairingGuidance.settingsOffer(for: .expired, failureSince: nil, hasStoredSensor: true, now: t0))
        XCTAssertNotNil(PairingGuidance.settingsOffer(for: .gracePeriod(endsAt: minutes(-1)), failureSince: nil, hasStoredSensor: true, now: t0),
                        "grace period over: the hero says expired and sends the person here")

        // First-launch onboarding: "Set up later" from every step leaves it, without marking it done.
        let fresh = PreviewAppServices(sensorState: .notPaired)
        let firstRun = launch(fresh, onboardingCompleted: false)
        for step in OnboardingStep.allCases {
            firstRun.presentOnboarding(at: step)
            XCTAssertEqual(firstRun.onboarding?.isDismissible, true, "\(step)")
            firstRun.dismissOnboarding()
            XCTAssertNil(firstRun.onboarding, "\(step)")
        }
        XCTAssertEqual(firstRun.preferences?.onboardingCompleted, false, "offered again next launch while no sensor is set up")
    }

    /// Before the source's first state the facade reports `.notPaired` by default: no "Pair a sensor",
    /// no onboarding, no pairing offer in Settings — until a `.sensor` change says it is real.
    func test_pairActionHiddenUntilSensorStateKnown() {
        let services = PreviewAppServices(sensorState: .notPaired)
        let model = launch(services, onboardingCompleted: false, sensorStateArrived: false)
        XCTAssertNil(model.onboarding, "not decided on the facade's default")
        guard case .message(let title, _, let action) = NowHero.make(model.now.display(now: t0), now: t0, sensorStateKnown: model.now.sensorStateKnown) else {
            return XCTFail("hero message expected")
        }
        XCTAssertEqual(title, "Starting up")
        XCTAssertNil(action, "no pair action before the state is known")
        XCTAssertEqual(StateLine.make(model.now.display(now: t0), sensorState: .notPaired, now: t0, sensorStateKnown: false).text, "STARTING UP")
        XCTAssertTrue(model.settings.sensor.isWaitingForFirstState, "Settings › Sensor shows 'Checking…' instead of a pairing offer")

        // The source's first state arrives: now it is real.
        model.apply(.sensor)
        XCTAssertTrue(model.now.sensorStateKnown)
        XCTAssertFalse(model.settings.sensor.isWaitingForFirstState)
        guard case .message(_, _, let pair) = NowHero.make(model.now.display(now: t0), now: t0, sensorStateKnown: model.now.sensorStateKnown) else {
            return XCTFail("hero message expected")
        }
        XCTAssertEqual(pair, .pairSensor)
        XCTAssertNotNil(model.onboarding, "first run, no sensor: onboarding is offered now")

        // Any other state, or a stored sensor, is evidence at launch.
        XCTAssertTrue(launch(PreviewAppServices(sensorState: .searching), sensorStateArrived: false).now.sensorStateKnown)
        let stored = PreviewAppServices(sensorState: .notPaired)
        stored.hasStoredSensor = true
        XCTAssertTrue(launch(stored, sensorStateArrived: false).now.sensorStateKnown)
    }

    /// Review m2: before the first unlock (e.g. a Bluetooth-restoration launch) preferences are
    /// neither read nor written and onboarding isn't decided; both happen once protected data is
    /// available.
    func test_preferencesAndOnboardingWaitForProtectedData() async {
        let defaults = UserDefaults(suiteName: "AppModelWiringTests.\(UUID().uuidString)")!
        let preferences = AppUIPreferences(defaults: defaults)
        preferences.appearance = .dark
        preferences.sensorNeedsCalibration = true
        let protectedData = ProtectedData(false)
        let services = PreviewAppServices(sensorState: .failed(SensorFailure(kind: .credentialsUnavailable, message: "locked")))
        let clock = self.clock
        let model = AppModel.launch(services: services, arguments: [], preferences: preferences, calendar: utcCalendar, clock: { clock.now },
                                    protectedDataAvailable: { protectedData.available })
        model.apply(.sensor)
        XCTAssertFalse(model.preferencesLoaded)
        XCTAssertEqual(model.settings.appearance, .system, "not read before the first unlock")
        XCTAssertNil(model.onboarding, "not decided before the first unlock")
        XCTAssertFalse(model.now.sensorNeedsCalibration)

        protectedData.available = true
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        let loaded = await eventually { model.preferencesLoaded }
        XCTAssertTrue(loaded)
        XCTAssertEqual(model.settings.appearance, .dark)
        XCTAssertTrue(model.now.sensorNeedsCalibration, "the stored need survives a transient failure (review minor 4)")
        XCTAssertNotNil(model.onboarding, "decided now: first run, no sensor set up")
    }

    /// Review m3: right after a code is submitted, the previous sensor's state (here: active) is not
    /// this pairing's result; only states after a connection step count.
    func test_onboardingPairingIgnoresThePreviousSensorsState() async {
        let services = PreviewAppServices(sensorState: .notPaired)
        let model = launch(services, onboardingCompleted: false)
        model.goToOnboardingStep(.pairing)
        services.pairingError = nil
        model.pairNewSensor(code: "1234")
        // Before the facade answers, a stale state from the previous sensor arrives.
        services.sensorState = activeSensor
        model.apply(.sensor)
        XCTAssertEqual(model.onboarding?.pairing, .inProgress, "the previous sensor's state is not this pairing's result")
        await model.settle()
        // The new pairing starts (searching), then the new sensor warms up.
        services.sensorState = .searching
        model.apply(.sensor)
        services.sensorState = .warmingUp(endsAt: minutes(30))
        model.apply(.sensor)
        XCTAssertEqual(model.onboarding?.pairing, .paired)
        XCTAssertEqual(OnboardingMapping.pairing(current: .inProgress, sensorState: .expired, sawConnectionStep: false), .inProgress)
    }

    /// Review m3 hardening: a sensor that becomes stored while the pairing is on its way proves the
    /// sensor answered, even with no connection step reported — the step can't stay "in progress".
    func test_onboardingPairingCountsANewlyStoredSensorAsAConnection() async {
        let services = PreviewAppServices(sensorState: .notPaired)
        let model = launch(services, onboardingCompleted: false)
        model.goToOnboardingStep(.pairing)
        // The code is submitted; the source then reports a sensor state without a connection step
        // (here before the facade's own pairing call has even run, so nothing reports `.searching`).
        model.pairNewSensor(code: "1234")
        services.sensorState = .warmingUp(endsAt: minutes(30))
        model.apply(.sensor)
        XCTAssertEqual(model.onboarding?.pairing, .inProgress, "no connection step and nothing stored yet")
        services.hasStoredSensor = true
        model.apply(.sensor)
        XCTAssertEqual(model.onboarding?.pairing, .paired)
        XCTAssertFalse(model.settings.sensor.pairingInProgress)
        await model.settle()
        XCTAssertEqual(model.onboarding?.pairing, .paired, "stays paired")
    }

    // MARK: - Onboarding

    func test_onboardingShowsOnlyWithoutASensor() {
        XCTAssertNotNil(launch(PreviewAppServices(sensorState: .notPaired), onboardingCompleted: false).onboarding)
        XCTAssertNil(launch(PreviewAppServices(sensorState: .notPaired), onboardingCompleted: true).onboarding, "completed once: not again")
        XCTAssertNil(launch(PreviewAppServices(sensorState: activeSensor), onboardingCompleted: false).onboarding)
        XCTAssertNil(launch(PreviewAppServices(sensorState: .notPaired), arguments: ["-replayScenario", "steady"], onboardingCompleted: false).onboarding,
                     "a replay run provides the sensor")
        XCTAssertNotNil(launch(PreviewAppServices(sensorState: activeSensor), arguments: ["-onboarding"]).onboarding)
        // Bluetooth problems and connection steps are no evidence of a sensor (the simulator reports
        // Bluetooth unsupported with nothing paired).
        let noBluetooth = PreviewAppServices(sensorState: .bluetoothUnavailable(.unsupported))
        let model = launch(noBluetooth, onboardingCompleted: false)
        XCTAssertNotNil(model.onboarding)
        noBluetooth.sensorState = .searching
        model.apply(.sensor)
        XCTAssertNotNil(model.onboarding, "not closed by a connection step")
        noBluetooth.sensorState = activeSensor
        model.apply(.sensor)
        XCTAssertNil(model.onboarding, "an existing sensor showed up before onboarding started: closed")
    }

    /// Pairing in onboarding follows the sensor: in progress → failed (source's failure) → paired.
    func test_onboardingPairingFollowsTheSensorState() async {
        let services = PreviewAppServices(sensorState: .notPaired)
        let model = launch(services, onboardingCompleted: false)
        model.goToOnboardingStep(.pairing)
        model.pairNewSensor(code: "1234")
        XCTAssertEqual(model.onboarding?.pairing, .inProgress)
        await model.settle()
        _ = await eventually { model.onboarding?.sensorState == .searching }
        XCTAssertEqual(model.onboarding?.pairing, .inProgress)
        let rejected = SensorFailure(kind: .pairingRejected, message: "Wrong code")
        services.sensorState = .failed(rejected)
        services.send(.sensor)
        _ = await eventually { model.onboarding?.pairing == .failed(rejected) }
        XCTAssertEqual(model.onboarding?.pairing, .failed(rejected))
        // A new pairing that hasn't authenticated retries with `pair(code:)` (review N2).
        XCTAssertFalse(model.onboardingPairingContext.canPairAgain)
        services.sensorState = .warmingUp(endsAt: minutes(30))
        services.send(.sensor)
        _ = await eventually { model.onboarding?.pairing == .paired }
        XCTAssertEqual(model.onboarding?.pairing, .paired)
        XCTAssertEqual(model.onboarding?.sensorState, .warmingUp(endsAt: minutes(30)), "the warm-up countdown's source")

        services.pairingError = .credentialStoreFailed("locked")
        model.pairNewSensor(code: "1234")
        await model.settle()
        guard case .couldNotStart(let message) = model.onboarding?.pairing else { return XCTFail("PairingError not shown") }
        XCTAssertTrue(message.contains("locked"))
        model.finishOnboarding()
        XCTAssertNil(model.onboarding)
    }

    /// D7: the Dexcom step saves Share credentials (US preselected), sets the region, turns upload
    /// on, and only then moves on; a save error stays on the step.
    func test_onboardingShareStep() async {
        let services = PreviewAppServices(sensorState: .notPaired)
        let model = launch(services, onboardingCompleted: false)
        XCTAssertEqual(model.onboarding?.shareRegion, .us)
        XCTAssertEqual(model.onboarding?.shareUploadEnabled, true)
        model.goToOnboardingStep(.removeDexcomApp)
        model.finishDexcomStep(shareEnabled: true, accountName: "me", password: "", receiverSerialNumber: "", region: .us)
        await model.settle()
        XCTAssertEqual(model.onboarding?.step, .removeDexcomApp)
        XCTAssertNotNil(model.onboarding?.shareMessage)
        model.finishDexcomStep(shareEnabled: true, accountName: "me", password: "pw", receiverSerialNumber: "SM1", region: .us)
        await model.settle()
        XCTAssertEqual(model.onboarding?.step, .permissions)
        XCTAssertTrue(services.calls.contains("setDexcomShareRegion(us)"))
        XCTAssertTrue(services.calls.contains("setDexcomShareEnabled(true)"))
        XCTAssertEqual(services.dexcomShare.upload.isEnabled, true)
    }

    /// History import: saves the site, starts the import, shows progress (incl. rejected future
    /// readings); imported data is for charts and stats only (S6).
    func test_onboardingImportFromNightscout() async {
        let services = PreviewAppServices(sensorState: .notPaired)
        let model = launch(services, onboardingCompleted: false)
        model.goToOnboardingStep(.importHistory)
        model.startNightscoutImport(url: "https://ns.example.com", token: "tok", depth: .everything)
        await model.settle()
        XCTAssertEqual(Array(services.calls.suffix(2)), ["saveNightscout", "startNightscoutImport"])
        _ = await eventually { model.onboarding?.importProgress?.isRunning == true }
        XCTAssertEqual(model.onboarding?.importProgress?.origin, .nightscout)
        XCTAssertNotNil(model.settings.runningImport)

        services.historyImport?.phase = .finished
        services.historyImport?.readingsImported = 1_000
        services.historyImport?.rejectedFutureDated = 3
        services.historyImport?.skipped = ["errorCode": 2]
        services.historyImport?.finishedAt = t0
        services.send(.historyImport)
        _ = await eventually { model.onboarding?.importProgress?.isFinished == true }
        XCTAssertEqual(model.onboarding?.importProgress?.rejectedFutureDated, 3)
        XCTAssertEqual(model.onboarding?.importProgress?.skippedNote, "2 entries skipped")
        XCTAssertEqual(model.settings.lastImport?.readingsImported, 1_000)
        XCTAssertNil(model.settings.runningImport)
    }

    /// With a saved site and token, the import doesn't ask for them again.
    func test_importFromTheSavedSite() async {
        let services = PreviewAppServices(sensorState: .notPaired)
        services.nightscout = NightscoutSummary(siteURL: "https://ns.example.com/", hasToken: true, upload: .off)
        let model = launch(services, onboardingCompleted: false)
        XCTAssertEqual(model.onboarding?.nightscoutSiteURL, "https://ns.example.com/")
        model.startNightscoutImport(url: "", token: "", depth: .ninetyDays)
        await model.settle()
        XCTAssertFalse(services.calls.contains("saveNightscout"))
        XCTAssertTrue(services.calls.contains("startNightscoutImport"))
    }

    /// Permissions come from the services (Bluetooth authorization, notification settings).
    func test_onboardingPermissions() {
        let services = PreviewAppServices(sensorState: .notPaired)
        services.bluetoothAuthorization = .denied
        services.alertDelivery = AlertDeliveryReport(
            permissions: NotificationPermissionState(authorization: .authorized, alerts: .enabled, sounds: .enabled, criticalAlerts: .notSupported, timeSensitive: .enabled),
            outputVolume: 0.5, urgentLowAlarm: .notDetermined, problems: [])
        let model = launch(services, onboardingCompleted: false)
        XCTAssertEqual(model.onboarding?.bluetooth, .denied)
        XCTAssertEqual(model.onboarding?.notifications, .authorized)
        XCTAssertEqual(model.onboarding?.criticalAlerts, .entitlementNotGranted)
        XCTAssertEqual(model.onboarding?.urgentLowAlarm, .notDetermined)
    }

    // MARK: - DEBUG replay

    func test_replayRunShowsInTheBuildBanner() async {
        let services = liveServices()
        services.replay = ReplayStatus(availableScenarios: ["steady", "sensorExpiry"], activeScenario: nil, speed: nil, developerLiveOutputsEnabled: false)
        let model = launch(services)
        XCTAssertEqual(model.settings.debug?.availableScenarios, ["steady", "sensorExpiry"])
        model.startReplay(scenario: "steady", speed: 60)
        await model.settle()
        _ = await eventually { model.now.replayScenario == "steady" }
        XCTAssertEqual(model.now.buildBanner?.title, "DEBUG BUILD · REPLAY: STEADY")
        XCTAssertEqual(model.settings.debug?.activeScenario, "steady")
        model.setDeveloperLiveOutputs(true)
        model.stopReplay()
        await model.settle()
        _ = await eventually { model.now.replayScenario == nil }
        XCTAssertEqual(model.now.buildBanner?.title, "DEBUG BUILD", "the DEBUG banner stays after replay")
        XCTAssertEqual(model.settings.debug?.developerLiveOutputsEnabled, true)
    }

    // MARK: - Change routing

    /// Each `ServiceChange` updates the view states that read what it names.
    func test_changesUpdateTheirViewStates() async {
        let services = liveServices()
        let model = launch(services)
        services.accent = .ink
        services.send(.appearance)
        var settings = AlertSettings.defaults
        settings.low.thresholdMgdl = 80
        services.alertSettings = settings
        services.send(.alertSettings)
        services.storage = StorageStatus(availability: .open, summary: StoreSummary(readingCount: 42, earliest: nil, latest: nil, fileSizeBytes: 4_096),
                                         retention: .forever, lastPurgeAt: nil, lastPurgeRemoved: 0)
        services.send(.storage)
        let updated = await eventually {
            model.settings.accent == .ink && model.alerts.row(.low)?.threshold == .glucose(mgdl: 80, isBelow: true, allowed: AlertLimits.lowThresholdMgdl)
                && model.settings.readingCount == 42
        }
        XCTAssertTrue(updated)
        XCTAssertEqual(model.settings.retention, .forever)
        XCTAssertEqual(model.settings.databaseSizeBytes, 4_096)
    }
}
