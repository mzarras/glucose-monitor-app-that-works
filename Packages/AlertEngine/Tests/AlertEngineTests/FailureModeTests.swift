import XCTest
import GlucoseCore
@testable import AlertEngine

/// Phase 3 failure-mode pass, AlertEngine side: time zones and DST, clock changes across a reboot,
/// snapshot restore after a kill, permissions, and the pending-notification budget. Modes already
/// proven elsewhere are cited, with these, in the failure-mode table (docs/failure-modes.md).
@MainActor
final class FailureModeTests: XCTestCase {
    private var originalTimeZone: TimeZone!

    override func setUp() async throws {
        originalTimeZone = NSTimeZone.default
    }

    override func tearDown() async throws {
        NSTimeZone.default = originalTimeZone
    }

    private func utc(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private let nightQuietHours = QuietHours(isEnabled: true, startMinuteOfDay: 22 * 60, endMinuteOfDay: 7 * 60)

    private func settings(_ change: (inout AlertSettings) -> Void = { _ in }) -> AlertSettings {
        var s = AlertSettings.defaults
        change(&s)
        return s
    }

    /// A session valid around `date`, so readings then pass the gate.
    private func session(around date: Date) -> SensorSession {
        let start = date.addingTimeInterval(-2 * 86_400)
        return SensorSession(serial: Fixtures.serial, start: start, warmUpEndsAt: start.addingTimeInterval(1800),
                             expiresAt: date.addingTimeInterval(8 * 86_400), gracePeriodEndsAt: date.addingTimeInterval(8 * 86_400 + 12 * 3600))
    }

    private func futurePending(_ center: FakeNotificationCenter, at now: Date) -> [NotificationRequestSpec] {
        center.pending.values.filter { ($0.fireDate ?? .distantPast) > now }
    }

    // MARK: Time zone and DST

    /// 2026-03-08, America/New_York: 02:00 EST jumps to 03:00 EDT. A 22:00–07:00 window lasts 8 hours.
    func test_quietHoursOnTheSpringForwardNight() {
        let q = nightQuietHours
        XCTAssertFalse(q.contains(utc("2026-03-08T02:59:00Z"), calendar: newYork), "21:59 EST")
        XCTAssertTrue(q.contains(utc("2026-03-08T03:00:00Z"), calendar: newYork), "22:00 EST")
        XCTAssertTrue(q.contains(utc("2026-03-08T06:59:00Z"), calendar: newYork), "01:59 EST")
        XCTAssertTrue(q.contains(utc("2026-03-08T07:00:00Z"), calendar: newYork), "03:00 EDT, the next minute")
        XCTAssertTrue(q.contains(utc("2026-03-08T10:59:00Z"), calendar: newYork), "06:59 EDT")
        XCTAssertFalse(q.contains(utc("2026-03-08T11:00:00Z"), calendar: newYork), "07:00 EDT")
        let start = utc("2026-03-08T01:00:00Z")
        let quietMinutes = (0..<(12 * 60)).filter { q.contains(start.addingTimeInterval(Double($0) * 60), calendar: newYork) }.count
        XCTAssertEqual(quietMinutes, 8 * 60)
    }

    /// 2026-11-01, America/New_York: 02:00 EDT falls back to 01:00 EST. The window lasts 10 hours and
    /// both 01:30s are inside it.
    func test_quietHoursOnTheFallBackNight() {
        let q = nightQuietHours
        XCTAssertFalse(q.contains(utc("2026-11-01T01:59:00Z"), calendar: newYork), "21:59 EDT")
        XCTAssertTrue(q.contains(utc("2026-11-01T02:00:00Z"), calendar: newYork), "22:00 EDT")
        XCTAssertTrue(q.contains(utc("2026-11-01T05:30:00Z"), calendar: newYork), "01:30 EDT")
        XCTAssertTrue(q.contains(utc("2026-11-01T06:30:00Z"), calendar: newYork), "01:30 EST, again")
        XCTAssertTrue(q.contains(utc("2026-11-01T11:59:00Z"), calendar: newYork), "06:59 EST")
        XCTAssertFalse(q.contains(utc("2026-11-01T12:00:00Z"), calendar: newYork), "07:00 EST")
        let start = utc("2026-11-01T01:00:00Z")
        let quietMinutes = (0..<(12 * 60)).filter { q.contains(start.addingTimeInterval(Double($0) * 60), calendar: newYork) }.count
        XCTAssertEqual(quietMinutes, 10 * 60)
    }

    func test_S7_onDSTNightsEachPendingNotificationIsDecidedForItsOwnLocalTimeAndUrgentLowNeverSilenced() {
        let configuration = AlertEngineConfiguration(calendar: newYork, locale: Locale(identifier: "en_US_POSIX"))
        let quiet = settings { $0.quietHours = self.nightQuietHours }

        // Spring forward, 06:40 EDT: missed readings is pending at 06:55 (quiet) and 07:10 (not).
        let spring = EngineHarness(settings: quiet, configuration: configuration)
        spring.clock.set(utc("2026-03-08T10:40:00Z"))
        spring.session = session(around: spring.now)
        let pending = spring.mgdl(120).scheduledNotices(.missedReadings) ?? []
        XCTAssertEqual(pending.prefix(3).map(\.isSilenced), [true, false, false])
        spring.clock.advance(minutes: 1)
        let low = spring.mgdl(50)
        XCTAssertEqual(low.firedNotice(.urgentLow)?.isSilenced, false)
        XCTAssertTrue((low.scheduledNotices(.urgentLow) ?? []).allSatisfy { !$0.isSilenced })

        // Fall back, at the second 01:30 (EST): low is silenced, urgent low is not.
        let fall = EngineHarness(settings: quiet, configuration: configuration)
        fall.clock.set(utc("2026-11-01T06:30:00Z"))
        fall.session = session(around: fall.now)
        XCTAssertEqual(fall.mgdl(65).firedNotice(.low)?.isSilenced, true)
        fall.clock.advance(minutes: 5)
        let urgent = fall.mgdl(50)
        XCTAssertEqual(urgent.firedNotice(.urgentLow)?.isSilenced, false)
        XCTAssertEqual(urgent.firedNotice(.urgentLow)?.body, "50 mg/dL at 1:35 AM. Treat now.", "local time; ambiguous on this night")
    }

    /// The default calendar follows the phone's zone live. Pending notifications built in the old zone
    /// (quiet-hours decisions, clock times in the text) are rebuilt at the first input after a change.
    func test_aTimeZoneChangeRebuildsPendingNotificationsForTheNewZone() {
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        let configuration = AlertEngineConfiguration(calendar: .autoupdatingCurrent, locale: Locale(identifier: "en_US_POSIX"))
        let h = EngineHarness(settings: settings { $0.quietHours = self.nightQuietHours }, configuration: configuration)
        h.clock.set(utc("2026-09-24T02:00:00Z"))   // 22:00 EDT: quiet hours in New York
        h.send(.sensorState(.active(sessionStart: Fixtures.session.start, expiresAt: Fixtures.session.expiresAt)))
        let before = h.mgdl(65)
        XCTAssertEqual(before.firedNotice(.low)?.isSilenced, true)
        XCTAssertTrue((before.scheduledNotices(.missedReadings) ?? []).allSatisfy(\.isSilenced))
        XCTAssertEqual(h.engine.snapshot.expiryPlan.flatMap { _ in h.engine.snapshot.timeZoneIdentifier }, "America/New_York")

        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!   // 19:01 PDT: outside
        h.clock.advance(minutes: 1)
        let after = h.tick()
        XCTAssertTrue(after.contains { if case .cancelSlots(.missedReadings, _) = $0 { return true } else { return false } })
        XCTAssertEqual(after.scheduledNotices(.missedReadings)?.first?.isSilenced, false, "decided again in the new zone")
        XCTAssertEqual(after.scheduledNotices(.sensorExpiringIn2Hours)?.first?.title, "Sensor expires in 2 hours (at 5:00 AM)",
                       "reminder texts written again with the new zone's clock time (was 8:00 AM)")
        XCTAssertEqual(h.engine.snapshot.timeZoneIdentifier, "America/Los_Angeles")

        h.clock.advance(minutes: 1)
        XCTAssertEqual(h.mgdl(260).firedNotice(.high)?.isSilenced, false, "an alert now is decided in the new zone")
        h.clock.advance(minutes: 1)
        XCTAssertNil(h.tick().scheduled(.sensorExpiringIn2Hours), "rebuilt once, not on every input")
    }

    /// Review m1: a zone change first seen on an input the engine refuses must not remove anything
    /// it does not plan again; the next accepted input rebuilds for the new zone.
    func test_aTimeZoneChangeSeenOnARejectedReadingLosesNothing() {
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        let configuration = AlertEngineConfiguration(calendar: .autoupdatingCurrent, locale: Locale(identifier: "en_US_POSIX"))
        let h = EngineHarness(configuration: configuration)
        h.mgdl(50)
        h.user(.acknowledge(.urgentLow))
        let urgentLow = h.pendingDates(.urgentLow)
        let missed = h.pendingDates(.missedReadings)
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        h.clock.advance(minutes: 5)
        let refused = h.send(.reading(Fixtures.reading(.mgdl(50), at: h.now.addingTimeInterval(300)), session: h.session))
        XCTAssertEqual(refused.rejected.count, 1)
        XCTAssertEqual(refused.count, 1, "nothing but the rejection")
        XCTAssertEqual(h.pendingDates(.urgentLow), urgentLow, "the snooze-end alarm is still pending")
        XCTAssertEqual(h.pendingDates(.missedReadings), missed)
        XCTAssertEqual(h.engine.snapshot.timeZoneIdentifier, "America/New_York", "not recorded: the next accepted input rebuilds")
        h.clock.advance(minutes: 1)
        let next = h.tick()
        XCTAssertTrue(next.contains { if case .cancelSlots(.urgentLow, _) = $0 { return true } else { return false } })
        XCTAssertEqual(h.pendingDates(.urgentLow).first, Fixtures.t0.addingTimeInterval(minutes(30)), "rebuilt and planned again")
        XCTAssertEqual(h.engine.snapshot.timeZoneIdentifier, "America/Los_Angeles")
    }

    func test_aRestoredSnapshotFromAnotherZoneIsRebuiltByTheLaunch() throws {
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        let configuration = AlertEngineConfiguration(calendar: .autoupdatingCurrent, locale: Locale(identifier: "en_US_POSIX"))
        let h = EngineHarness(configuration: configuration)
        h.send(.sensorState(.active(sessionStart: Fixtures.session.start, expiresAt: Fixtures.session.expiresAt)))
        h.mgdl(120)
        let stored = try XCTUnwrap(AlertEngineSnapshot.decode(h.engine.snapshot.encoded()))
        NSTimeZone.default = TimeZone(identifier: "Europe/Paris")!
        var engine = AlertEngine(settings: .defaults, configuration: configuration, restoring: stored, now: h.now)
        let launch = engine.handle(.launched, at: h.now)
        XCTAssertEqual(launch.scheduledNotices(.sensorExpiringIn2Hours)?.first?.title, "Sensor expires in 2 hours (at 2:00 PM)")
        XCTAssertNil(engine.handle(.tick, at: h.now.addingTimeInterval(60)).scheduled(.sensorExpiringIn2Hours), "the launch already did it")
    }

    // MARK: Clock changes across a reboot

    func test_S7_aRebootWithTheClockSetBackEndsTheUrgentLowSnooze() throws {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.snooze(.urgentLow, minutes: 30))
        let stored = try XCTUnwrap(AlertEngineSnapshot.decode(h.engine.snapshot.encoded()))   // then killed
        h.clock.advance(minutes: 10)
        h.clock.reboot(uptime: 40)        // a new boot session: the monotonic clocks are not comparable
        h.clock.advance(minutes: -20)     // and the wall clock was set back
        var engine = AlertEngine(settings: .defaults, configuration: Fixtures.configuration, restoring: stored, now: h.now, uptime: h.clock.uptime)
        XCTAssertEqual(engine.phase(of: .urgentLow), .snoozed(until: h.now), "caught against the latest wall clock seen: the snooze ends")
        let reading = Fixtures.reading(.mgdl(50), at: h.now)
        XCTAssertEqual(engine.handle(.reading(reading, session: Fixtures.session), at: h.now, uptime: h.clock.uptime).fired, [.urgentLow])
    }

    func test_S7_aRebootWithTheClockSetForwardEndsTheUrgentLowSnoozeEarly() throws {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.snooze(.urgentLow, minutes: 30))
        let stored = try XCTUnwrap(AlertEngineSnapshot.decode(h.engine.snapshot.encoded()))
        h.clock.reboot(uptime: 40)
        h.clock.set(Fixtures.t0.addingTimeInterval(minutes(45)))   // 5 real minutes later, the clock jumped 40 forward
        var engine = AlertEngine(settings: .defaults, configuration: Fixtures.configuration, restoring: stored, now: h.now, uptime: h.clock.uptime)
        let reading = Fixtures.reading(.mgdl(50), at: h.now)
        let actions = engine.handle(.reading(reading, session: Fixtures.session), at: h.now, uptime: h.clock.uptime)
        XCTAssertEqual(actions.due, [.urgentLow], "the snooze is over by the wall clock: it sounds now (D44: as its snooze-end alarm)")
        XCTAssertEqual(engine.phase(of: .urgentLow), .firing(since: Fixtures.t0.addingTimeInterval(minutes(30))))
    }

    func test_S5_missedReadingsAfterAKillAndRebootSoundsAtRelaunch() async throws {
        let first = ServiceHarness()
        await first.service.start()
        await first.reading(.mgdl(120))
        let snapshot = try XCTUnwrap(first.snapshots.last)
        first.clock.advance(minutes: 20)        // killed; the phone rebooted; no reading for 20 minutes
        first.clock.reboot(uptime: 60)
        let relaunched = ServiceHarness(snapshot: snapshot, center: first.center, clock: first.clock)
        await relaunched.service.start()
        XCTAssertEqual(relaunched.service.phase(of: .missedReadings), .firing(since: Fixtures.t0.addingTimeInterval(minutes(15))))
        XCTAssertEqual(relaunched.audio.plays.map(\.fileName), ["alert-sonar.wav"], "iOS posted it at +15; the relaunch adds the sound")
        XCTAssertGreaterThanOrEqual(futurePending(relaunched.center, at: relaunched.clock.now)
            .filter { $0.userInfo[AlertNotificationIDs.userInfoKind] == "missedReadings" }.count, AlertLimits.scheduledNotificationCount - 1)
    }

    func test_S5_missedReadingsAfterARebootWithTheClockSetBackRestartsItsWindowFromNow() throws {
        let h = EngineHarness()
        h.mgdl(120)
        let stored = try XCTUnwrap(AlertEngineSnapshot.decode(h.engine.snapshot.encoded()))
        h.clock.reboot(uptime: 40)
        h.clock.set(Fixtures.t0.addingTimeInterval(-2 * 3600))
        var engine = AlertEngine(settings: .defaults, configuration: Fixtures.configuration, restoring: stored, now: h.now, uptime: h.clock.uptime)
        let launch = engine.handle(.launched, at: h.now, uptime: h.clock.uptime)
        XCTAssertEqual(launch.scheduled(.missedReadings)?.first, h.now.addingTimeInterval(minutes(15)), "15 minutes from now, not 2 h 15 min")
    }

    // MARK: Snapshot restore after a kill or reboot

    func test_S5_aCorruptSnapshotStartsFreshAndLoud() throws {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.snooze(.urgentLow, minutes: 30))
        let data = try XCTUnwrap(h.engine.snapshot.encoded())
        XCTAssertNil(AlertEngineSnapshot.decode(data.prefix(data.count / 2)), "a half-written file")
        let later = h.now.addingTimeInterval(minutes(2))
        var engine = AlertEngine(settings: .defaults, configuration: Fixtures.configuration, restoring: nil, now: later)
        let launch = engine.handle(.launched, at: later)
        XCTAssertEqual(launch.scheduled(.missedReadings)?.first, later.addingTimeInterval(minutes(15)), "missed readings armed from the restart")
        let reading = Fixtures.reading(.mgdl(50), at: later)
        XCTAssertEqual(engine.handle(.reading(reading, session: Fixtures.session), at: later).fired, [.urgentLow],
                       "the acknowledgement is lost: urgent low sounds again (louder, never quieter)")
    }

    func test_aSnapshotFromANewerBuildKeepsWhatItCanRead() throws {
        let h = EngineHarness()
        h.send(.sensorState(.active(sessionStart: Fixtures.session.start, expiresAt: Fixtures.session.expiresAt)))
        h.mgdl(120)
        let data = try XCTUnwrap(h.engine.snapshot.encoded())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var plan = try XCTUnwrap(object["expiryPlan"] as? [String: Any])
        var reminders = try XCTUnwrap(plan["reminders"] as? [String: Any])
        reminders["sensorExpiringIn2Hours"] = ["someFutureStatus": ["x": 1]]
        reminders["sensorExpiringIn6Hours"] = reminders["sensorExpiringIn24Hours"]
        plan["reminders"] = reminders
        plan["someFutureField"] = true
        object["expiryPlan"] = plan
        object["aFieldFromAFutureBuild"] = [1, 2, 3]
        let newer = try JSONSerialization.data(withJSONObject: object)

        let restored = try XCTUnwrap(AlertEngineSnapshot.decode(newer))
        XCTAssertNotNil(restored.expiryPlan, "one unreadable entry does not lose the plan")
        XCTAssertNil(restored.expiryPlan?[.sensorExpiringIn2Hours])
        XCTAssertEqual(restored.expiryPlan?[.sensorExpiringIn24Hours], h.engine.snapshot.expiryPlan?[.sensorExpiringIn24Hours])
        var engine = AlertEngine(settings: .defaults, configuration: Fixtures.configuration, restoring: restored, now: h.now)
        XCTAssertNil(engine.snapshot.expiryPlan?.reminders["sensorExpiringIn6Hours"], "an alert this build does not know is dropped")
        let launch = engine.handle(.launched, at: h.now)
        XCTAssertEqual(launch.scheduled(.sensorExpiringIn2Hours), [Fixtures.session.expiresAt.addingTimeInterval(-2 * 3600)],
                       "the unreadable reminder is scheduled again, not lost")
    }

    func test_aMalformedKnownSessionIsDroppedOnRestore() {
        var snapshot = AlertEngineSnapshot(start: Fixtures.t0)
        snapshot.knownSession = SensorSession(serial: "", start: Fixtures.t0, warmUpEndsAt: Fixtures.t0,
                                              expiresAt: Fixtures.t0.addingTimeInterval(-1), gracePeriodEndsAt: Fixtures.t0)
        XCTAssertNil(AlertEngine(settings: .defaults, configuration: Fixtures.configuration, restoring: snapshot, now: Fixtures.t0).snapshot.knownSession)
        snapshot.knownSession = Fixtures.session
        XCTAssertEqual(AlertEngine(settings: .defaults, configuration: Fixtures.configuration, restoring: snapshot, now: Fixtures.t0)
            .snapshot.knownSession, Fixtures.session)
    }

    func test_S7_anUrgentLowInProgressSurvivesAKillAndRelaunch() async throws {
        let first = ServiceHarness()
        await first.service.start()
        await first.reading(.mgdl(50))
        let postedBefore = first.center.posted.count
        let snapshot = try XCTUnwrap(first.snapshots.last)
        first.clock.advance(minutes: 7)   // killed; iOS posted the +5 repeat meanwhile
        let relaunched = ServiceHarness(snapshot: snapshot, center: first.center, clock: first.clock)
        await relaunched.service.start()
        XCTAssertEqual(relaunched.service.phase(of: .urgentLow), .firing(since: Fixtures.t0), "still the same episode")
        let future = futurePending(relaunched.center, at: relaunched.clock.now).filter { $0.userInfo[AlertNotificationIDs.userInfoKind] == "urgentLow" }
        XCTAssertGreaterThanOrEqual(future.count, 11, "repeats rebuilt for the next hour")
        XCTAssertEqual(future.compactMap(\.fireDate).min(), Fixtures.t0.addingTimeInterval(minutes(10)), "on the original grid")
        await relaunched.reading(.mgdl(48))
        XCTAssertEqual(relaunched.center.posted.count, postedBefore, "not posted as a new alert")
        XCTAssertEqual(relaunched.audio.plays.map(\.fileName), ["alert-cascade.wav"], "the +5 repeat sounds now (the app is awake)")
    }

    // MARK: Permissions

    private let denied = NotificationPermissionState(authorization: .denied, alerts: .disabled, sounds: .disabled,
                                                     criticalAlerts: .notSupported, timeSensitive: .disabled)

    func test_S7_withNotificationsDeniedUrgentLowStillSoundsInTheApp() async {
        let s = ServiceHarness()
        s.center.permissions = denied
        s.center.failAdds = true   // iOS refuses every request while notifications are off
        await s.service.start()
        await s.reading(.mgdl(50))
        XCTAssertEqual(s.audio.plays.first?.fileName, "alert-cascade.wav")
        XCTAssertEqual(s.audio.plays.first?.loopSeconds, AlertLimits.urgentInAppAudioSeconds)
        XCTAssertEqual(s.service.phase(of: .urgentLow), .firing(since: Fixtures.t0))
        XCTAssertEqual(s.service.deliveryStatus.problems.first, .notificationsDenied, "shown on the Settings screen (S5)")
        await s.advance(minutes: 5)
        XCTAssertEqual(s.audio.plays.count, 2, "each repeat while awake sounds again")
    }

    func test_S5_withNotificationsRevokedMissedReadingsStillSoundsWhenTheAppIsAwake() async {
        let s = ServiceHarness()
        await s.service.start()
        await s.reading(.mgdl(120))
        s.center.permissions = denied       // revoked in iOS Settings
        s.center.failAdds = true
        await s.advance(minutes: 15)
        XCTAssertEqual(s.service.phase(of: .missedReadings), .firing(since: Fixtures.t0.addingTimeInterval(minutes(15))))
        XCTAssertEqual(s.audio.plays.map(\.fileName), ["alert-sonar.wav"])
    }

    func test_S7_alarmPermissionRevokedWithRepeatsPendingFallsBackToTheNextLoudestPath() async throws {
        let alarms = FakeSystemAlarms()
        let s = ServiceHarness(alarms: alarms)
        await s.service.start()
        await s.reading(.mgdl(50))
        XCTAssertEqual(alarms.repeatAlarms.count, 12)
        XCTAssertTrue(s.audio.plays.isEmpty, "the alarm rings; no in-app sound on top")

        alarms.authorization = .denied   // revoked in Settings while the app slept
        s.clock.advance(minutes: 2)
        await s.service.send(.tick)
        let now = s.clock.now
        XCTAssertTrue(alarms.repeatAlarms.filter { $0.fireDate > now.addingTimeInterval(60) }.isEmpty, "no future repeat relies on an alarm")
        let pending = futurePending(s.center, at: now).filter { $0.userInfo[AlertNotificationIDs.userInfoKind] == "urgentLow" }
        XCTAssertEqual(pending.count, 12, "still an hour of repeats")
        XCTAssertTrue(pending.allSatisfy { $0.interruption == .timeSensitive && $0.sound == .named(fileName: "alert-cascade.wav") },
                      "the loudest path left while suspended: Time Sensitive with the sound")
        XCTAssertEqual(s.service.deliveryStatus.problems, [.urgentLowAlarmDenied])

        await s.advance(minutes: 3)   // the +5 repeat, app awake
        XCTAssertEqual(s.audio.plays.map(\.fileName), ["alert-cascade.wav"], "awake: the in-app sound, which ignores the ringer switch")
        let decision = DeliveryPolicy.decide(for: try XCTUnwrap(EngineHarness().mgdl(50).firedNotice(.urgentLow)),
                                             criticalAlertsEnabled: false, systemAlarmsAvailable: false, timing: .now)
        XCTAssertEqual(decision.loudness, 2)
    }

    func test_S7_criticalAlertsRevokedFallsBackToTimeSensitiveAndTheInAppSound() async {
        let s = ServiceHarness()
        s.center.permissions.criticalAlerts = .enabled
        await s.service.start()
        await s.reading(.mgdl(50))
        XCTAssertEqual(s.center.posted.last?.interruption, .critical)
        XCTAssertTrue(futurePending(s.center, at: s.clock.now).allSatisfy { $0.userInfo["alertKind"] != "urgentLow" || $0.interruption == .critical })

        s.center.permissions.criticalAlerts = .disabled   // turned off in Settings
        s.clock.advance(minutes: 2)
        await s.service.send(.tick)
        let pending = futurePending(s.center, at: s.clock.now).filter { $0.userInfo[AlertNotificationIDs.userInfoKind] == "urgentLow" }
        XCTAssertFalse(pending.isEmpty)
        XCTAssertTrue(pending.allSatisfy { $0.interruption == .timeSensitive }, "rebuilt for the fallback path")
        await s.advance(minutes: 3)
        XCTAssertEqual(s.audio.plays.map(\.fileName), ["alert-cascade.wav"], "awake: the in-app sound")
    }

    // MARK: Pending-notification budget

    func test_S5_pendingNotificationsStayUnderTheIOSLimitWithEveryAlertActive() async {
        let everything = settings {
            $0.urgentLow.repeatMinutes = 2   // the floor: the most repeats
            $0.urgentLowSoon.isEnabled = true
            $0.fallingFast.isEnabled = true
            $0.risingFast.isEnabled = true
        }
        let s = ServiceHarness(settings: everything)
        await s.service.start()
        await s.service.send(.sensorState(.active(sessionStart: Fixtures.session.start, expiresAt: Fixtures.session.expiresAt)))
        await s.service.send(.reading(Fixtures.reading(.mgdl(50), at: s.clock.now, rate: -4), session: Fixtures.session))
        await s.service.send(.trioBridge(.writeFailing(since: s.clock.now, reason: "x")))
        await s.service.send(.storage(.failing(since: s.clock.now.addingTimeInterval(-600))))
        var maximum = 0
        for _ in 0..<(3 * 60) {   // three hours with no reading: missed readings fires and repeats too
            await s.advance(minutes: 1)
            let count = futurePending(s.center, at: s.clock.now).count
            maximum = max(maximum, count)
            XCTAssertLessThanOrEqual(count, 64)
        }
        XCTAssertEqual(s.service.phase(of: .missedReadings), .firing(since: Fixtures.t0.addingTimeInterval(minutes(15))))
        // An hour of urgent-low repeats (30) and 12 missed-readings notifications beyond the protected
        // minute, plus the one of each due within that minute (never touched), plus 5 expiry reminders.
        // Every other alert posts at once and holds no pending notification.
        XCTAssertEqual(maximum, AlertLimits.worstCasePendingNotifications)
        XCTAssertEqual(maximum, (30 + 1) + (12 + 1) + 5)
    }
}
