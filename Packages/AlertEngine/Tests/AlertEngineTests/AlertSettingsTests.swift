import XCTest
@testable import AlertEngine

final class AlertSettingsTests: XCTestCase {
    private func decode(_ json: String) throws -> AlertSettings {
        try JSONDecoder().decode(AlertSettings.self, from: Data(json.utf8))
    }

    // MARK: Defaults (HANDOFF §5)

    func test_defaultsMatchHandoffSection5() {
        let s = AlertSettings.defaults
        XCTAssertTrue(s.isEnabled(.urgentLow))
        XCTAssertEqual(s.urgentLow.thresholdMgdl, 55)
        XCTAssertEqual(s.urgentLow.repeatMinutes, 5)
        XCTAssertEqual(s.urgentLow.snoozeMinutes, 30)
        XCTAssertFalse(s.urgentLowSoon.isEnabled, "urgent low soon is off by default")
        XCTAssertTrue(s.low.isEnabled)
        XCTAssertEqual(s.low.thresholdMgdl, 70)
        XCTAssertTrue(s.high.isEnabled)
        XCTAssertEqual(s.high.thresholdMgdl, 250)
        XCTAssertEqual(s.high.delayMinutes, 0)
        XCTAssertFalse(s.fallingFast.isEnabled, "rate alerts are off by default")
        XCTAssertFalse(s.risingFast.isEnabled)
        XCTAssertEqual(s.fallingFast.thresholdMgdlPerMinute, 3)
        XCTAssertEqual(s.risingFast.thresholdMgdlPerMinute, 3)
        XCTAssertTrue(s.missedReadings.isEnabled)
        XCTAssertEqual(s.missedReadings.windowMinutes, 15)
        for kind: AlertKind in [
            .sensorWarmUpComplete, .sensorExpiringIn24Hours, .sensorExpiringIn2Hours, .sensorGracePeriod,
            .sensorFailed, .sensorError, .calibrationNeeded, .sensorExpired, .bluetoothUnavailable, .trioBridge,
        ] {
            XCTAssertTrue(s.isEnabled(kind), "\(kind) on by default")
        }
        XCTAssertFalse(s.quietHours.isEnabled)
    }

    func test_soundOnSilentDefaults() {
        let s = AlertSettings.defaults
        let on: [AlertKind] = [
            .urgentLow, .urgentLowSoon, .low, .high, .missedReadings,
            .sensorFailed, .sensorError, .calibrationNeeded, .sensorExpired, .bluetoothUnavailable, .trioBridge,
        ]
        let off: [AlertKind] = [
            .fallingFast, .risingFast,
            .sensorWarmUpComplete, .sensorExpiringIn24Hours, .sensorExpiringIn2Hours, .sensorGracePeriod,
        ]
        XCTAssertEqual(Set(on).union(off), Set(AlertKind.allCases), "every alert has a stated default")
        for kind in on { XCTAssertTrue(s.soundsOnSilent(kind), "\(kind)") }
        for kind in off { XCTAssertFalse(s.soundsOnSilent(kind), "\(kind)") }
    }

    func test_snoozeMinutesIsNilOnlyForOneOffEvents() {
        for kind in AlertKind.allCases {
            XCTAssertEqual(AlertSettings.defaults.snoozeMinutes(kind) == nil, kind.isEventAlert, "\(kind)")
        }
    }

    // MARK: Clamping on every path

    func test_initialisersClamp() {
        XCTAssertEqual(UrgentLowSettings(thresholdMgdl: 20).thresholdMgdl, 50)
        XCTAssertEqual(UrgentLowSettings(thresholdMgdl: 99).thresholdMgdl, 60)
        XCTAssertEqual(LowAlertSettings(thresholdMgdl: 10).thresholdMgdl, 60)
        XCTAssertEqual(HighAlertSettings(thresholdMgdl: 1000).thresholdMgdl, 400)
        XCTAssertEqual(HighAlertSettings(delayMinutes: -5).delayMinutes, 0)
        XCTAssertEqual(HighAlertSettings(delayMinutes: 500).delayMinutes, 120)
        XCTAssertEqual(RateAlertSettings(thresholdMgdlPerMinute: 10).thresholdMgdlPerMinute, 5)
        XCTAssertEqual(RateAlertSettings(thresholdMgdlPerMinute: 0.5).thresholdMgdlPerMinute, 2)
        XCTAssertEqual(RateAlertSettings(thresholdMgdlPerMinute: .nan).thresholdMgdlPerMinute, 2)
        XCTAssertEqual(MissedReadingsSettings(windowMinutes: 5).windowMinutes, 10)
        XCTAssertEqual(MissedReadingsSettings(windowMinutes: 100).windowMinutes, 60)
        XCTAssertEqual(LowAlertSettings(snoozeMinutes: 0).snoozeMinutes, 5)
        XCTAssertEqual(StatusAlertSettings(isEnabled: true, sound: .warble, soundsOnSilent: true, snoozeMinutes: 100_000).snoozeMinutes, 1440)
        XCTAssertEqual(UrgentLowSoonSettings(snoozeMinutes: 1).snoozeMinutes, 5)
    }

    func test_settersClamp() {
        var s = AlertSettings.defaults
        s.urgentLow.thresholdMgdl = 45
        s.low.thresholdMgdl = 150
        s.high.thresholdMgdl = 50
        s.high.delayMinutes = 999
        s.fallingFast.thresholdMgdlPerMinute = 9
        s.missedReadings.windowMinutes = 1
        s.low.snoozeMinutes = -1
        s.high.snoozeMinutes = 5000
        s.urgentLowSoon.snoozeMinutes = 0
        s.risingFast.snoozeMinutes = 0
        s.missedReadings.snoozeMinutes = 0
        s.sensorFailed.snoozeMinutes = 0
        s.quietHours.startMinuteOfDay = -10
        s.quietHours.endMinuteOfDay = 5000
        XCTAssertEqual(s.urgentLow.thresholdMgdl, 50)
        XCTAssertEqual(s.low.thresholdMgdl, 100)
        XCTAssertEqual(s.high.thresholdMgdl, 120)
        XCTAssertEqual(s.high.delayMinutes, 120)
        XCTAssertEqual(s.fallingFast.thresholdMgdlPerMinute, 5)
        XCTAssertEqual(s.missedReadings.windowMinutes, 10)
        XCTAssertEqual(s.low.snoozeMinutes, 5)
        XCTAssertEqual(s.high.snoozeMinutes, 1440)
        XCTAssertEqual(s.urgentLowSoon.snoozeMinutes, 5)
        XCTAssertEqual(s.risingFast.snoozeMinutes, 5)
        XCTAssertEqual(s.missedReadings.snoozeMinutes, 5)
        XCTAssertEqual(s.sensorFailed.snoozeMinutes, 5)
        XCTAssertEqual(s.quietHours.startMinuteOfDay, 0)
        XCTAssertEqual(s.quietHours.endMinuteOfDay, 1439)
    }

    // MARK: S7

    func test_S7_urgentLowCannotBeDisabledThroughTheSettingsAPI() {
        var s = AlertSettings.defaults
        XCTAssertFalse(s.setEnabled(false, for: .urgentLow), "the API refuses")
        XCTAssertTrue(s.isEnabled(.urgentLow))
        XCTAssertFalse(s.setSoundsOnSilent(false, for: .urgentLow))
        XCTAssertTrue(s.soundsOnSilent(.urgentLow))
        XCTAssertEqual(s, AlertSettings.defaults, "nothing changed")
    }

    func test_S7_urgentLowSnoozeAndRepeatAreClampedOnEveryAssignment() {
        XCTAssertEqual(UrgentLowSettings(snoozeMinutes: 120).snoozeMinutes, 30)
        XCTAssertEqual(UrgentLowSettings(snoozeMinutes: 0).snoozeMinutes, 1)
        var u = UrgentLowSettings()
        u.snoozeMinutes = 45
        XCTAssertEqual(u.snoozeMinutes, 30)
        u.repeatMinutes = 10
        XCTAssertEqual(u.repeatMinutes, 5, "repeats may be more frequent than 5 min, never less")
        u.repeatMinutes = 0
        XCTAssertEqual(u.repeatMinutes, 2, "repeating cannot be turned off (2-minute floor keeps an hour of repeats within iOS's 64 pending)")
        XCTAssertEqual(AlertSettings.defaults.snoozeMinutes(.urgentLow).map { $0 <= 30 }, true)
    }

    func test_S7_decodedDisabledUrgentLowStaysEnabledAndClamped() throws {
        let s = try decode("""
        {"urgentLow": {"isEnabled": false, "enabled": false, "disabled": true, "soundsOnSilent": false,
                       "snoozeMinutes": 240, "thresholdMgdl": 40, "repeatMinutes": 60}}
        """)
        XCTAssertTrue(s.isEnabled(.urgentLow))
        XCTAssertTrue(s.soundsOnSilent(.urgentLow))
        XCTAssertEqual(s.urgentLow.snoozeMinutes, 30)
        XCTAssertEqual(s.urgentLow.thresholdMgdl, 50)
        XCTAssertEqual(s.urgentLow.repeatMinutes, 5)
    }

    // MARK: Migration-safe decoding

    func test_emptyObjectDecodesToDefaults() throws {
        XCTAssertEqual(try decode("{}"), AlertSettings.defaults)
    }

    func test_decodingIgnoresUnknownKeysAndFillsMissingFields() throws {
        let s = try decode("""
        {"schemaVersion": 99, "futureAlert": {"isEnabled": true},
         "low": {"thresholdMgdl": 80, "someNewField": [1, 2, 3]},
         "high": {"isEnabled": false}}
        """)
        XCTAssertEqual(s.low.thresholdMgdl, 80)
        XCTAssertTrue(s.low.isEnabled, "missing field keeps its default")
        XCTAssertEqual(s.low.sound, AlertSettings.defaults.low.sound)
        XCTAssertFalse(s.high.isEnabled)
        XCTAssertEqual(s.high.thresholdMgdl, 250)
        XCTAssertEqual(s.missedReadings, AlertSettings.defaults.missedReadings)
    }

    func test_decodingFallsBackPerFieldOnWrongTypes() throws {
        let s = try decode("""
        {"low": {"thresholdMgdl": "eighty", "isEnabled": false},
         "missedReadings": {"windowMinutes": null, "snoozeMinutes": 45},
         "quietHours": "every night",
         "trioBridge": 7}
        """)
        XCTAssertEqual(s.low.thresholdMgdl, 70)
        XCTAssertFalse(s.low.isEnabled, "the readable field still applies")
        XCTAssertEqual(s.missedReadings.windowMinutes, 15)
        XCTAssertEqual(s.missedReadings.snoozeMinutes, 45)
        XCTAssertEqual(s.quietHours, .default)
        XCTAssertEqual(s.trioBridge, StatusAlertSettings.defaults(for: .trioBridge))
    }

    func test_decodingOutOfRangeNumbersClamps() throws {
        let s = try decode("""
        {"low": {"thresholdMgdl": 5}, "high": {"thresholdMgdl": 900, "delayMinutes": 9999},
         "risingFast": {"thresholdMgdlPerMinute": 0.1}, "missedReadings": {"windowMinutes": 2},
         "quietHours": {"isEnabled": true, "startMinuteOfDay": -1, "endMinuteOfDay": 99999}}
        """)
        XCTAssertEqual(s.low.thresholdMgdl, 60)
        XCTAssertEqual(s.high.thresholdMgdl, 400)
        XCTAssertEqual(s.high.delayMinutes, 120)
        XCTAssertEqual(s.risingFast.thresholdMgdlPerMinute, 2)
        XCTAssertEqual(s.missedReadings.windowMinutes, 10)
        XCTAssertEqual(s.quietHours, QuietHours(isEnabled: true, startMinuteOfDay: 0, endMinuteOfDay: 1439))
    }

    func test_decodingUnknownSoundFallsBackToThatAlertsDefault() throws {
        let s = try decode("""
        {"urgentLow": {"sound": "pagerduty"}, "high": {"sound": "nope"}, "sensorError": {"sound": 3},
         "low": {"sound": "sonar"}}
        """)
        XCTAssertEqual(s.urgentLow.sound, .cascade)
        XCTAssertEqual(s.high.sound, .summit)
        XCTAssertEqual(s.sensorError.sound, .warble)
        XCTAssertEqual(s.low.sound, .sonar)
    }

    func test_roundTripPreservesEveryField() throws {
        var s = AlertSettings.defaults
        s.urgentLow = UrgentLowSettings(thresholdMgdl: 58, sound: .tide, repeatMinutes: 3, snoozeMinutes: 20)
        s.urgentLowSoon = UrgentLowSoonSettings(isEnabled: true, sound: .swoop, soundsOnSilent: false, snoozeMinutes: 25)
        s.low = LowAlertSettings(isEnabled: false, thresholdMgdl: 75, sound: .doorbell, soundsOnSilent: false, snoozeMinutes: 45)
        s.high = HighAlertSettings(isEnabled: true, thresholdMgdl: 220, delayMinutes: 30, sound: .sonar, soundsOnSilent: false, snoozeMinutes: 60)
        s.fallingFast = RateAlertSettings(isEnabled: true, thresholdMgdlPerMinute: 2.5, sound: .dusk, soundsOnSilent: true, snoozeMinutes: 20)
        s.risingFast = RateAlertSettings(isEnabled: true, thresholdMgdlPerMinute: 4, sound: .summit, soundsOnSilent: true, snoozeMinutes: 40)
        s.missedReadings = MissedReadingsSettings(isEnabled: false, windowMinutes: 25, sound: .cascade, soundsOnSilent: false, snoozeMinutes: 90)
        s.sensorWarmUpComplete = EventAlertSettings(isEnabled: false, sound: .summit, soundsOnSilent: true)
        s.sensorExpiringIn24Hours.isEnabled = false
        s.sensorExpiringIn2Hours.sound = .tide
        s.sensorGracePeriod.soundsOnSilent = true
        s.sensorFailed = StatusAlertSettings(isEnabled: false, sound: .sonar, soundsOnSilent: false, snoozeMinutes: 15)
        s.sensorError.snoozeMinutes = 200
        s.calibrationNeeded = StatusAlertSettings(isEnabled: false, sound: .doorbell, soundsOnSilent: false, snoozeMinutes: 45)
        s.sensorExpired.isEnabled = false
        s.bluetoothUnavailable.sound = .dusk
        s.trioBridge.soundsOnSilent = false
        s.quietHours = QuietHours(isEnabled: true, startMinuteOfDay: 23 * 60, endMinuteOfDay: 6 * 60 + 30)
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(AlertSettings.self, from: data), s)
        XCTAssertEqual(AlertSettings.decodeOrDefault(data), s)
    }

    func test_decodeOrDefaultNeverThrows() {
        XCTAssertEqual(AlertSettings.decodeOrDefault(nil), .defaults)
        XCTAssertEqual(AlertSettings.decodeOrDefault(Data("not json".utf8)), .defaults)
        XCTAssertEqual(AlertSettings.decodeOrDefault(Data("[1, 2]".utf8)), .defaults)
        XCTAssertEqual(AlertSettings.decodeOrDefault(Data("{}".utf8)), .defaults)
    }

    // MARK: Uniform accessors

    func test_uniformSettersReachEveryAlert() {
        var s = AlertSettings.defaults
        for kind in AlertKind.allCases {
            s.setSound(.warble, for: kind)
            XCTAssertEqual(s.sound(kind), .warble, "\(kind)")
            let applied = s.setEnabled(false, for: kind)
            XCTAssertEqual(applied, kind != .urgentLow)
            XCTAssertEqual(s.isEnabled(kind), kind == .urgentLow, "\(kind)")
            s.setEnabled(true, for: kind)
            XCTAssertTrue(s.isEnabled(kind))
            s.setSoundsOnSilent(true, for: kind)
            XCTAssertTrue(s.soundsOnSilent(kind))
            s.setSoundsOnSilent(false, for: kind)
            XCTAssertEqual(s.soundsOnSilent(kind), kind == .urgentLow, "\(kind)")
        }
    }
}

final class QuietHoursTests: XCTestCase {
    private func at(_ hour: Int, _ minute: Int) -> Date {
        Fixtures.utc.date(bySettingHour: hour, minute: minute, second: 0, of: Fixtures.t0)!
    }

    func test_sameDayWindow() {
        let q = QuietHours(isEnabled: true, startMinuteOfDay: 13 * 60, endMinuteOfDay: 15 * 60)
        XCTAssertFalse(q.contains(at(12, 59), calendar: Fixtures.utc))
        XCTAssertTrue(q.contains(at(13, 0), calendar: Fixtures.utc), "start is inclusive")
        XCTAssertTrue(q.contains(at(14, 59), calendar: Fixtures.utc))
        XCTAssertFalse(q.contains(at(15, 0), calendar: Fixtures.utc), "end is exclusive")
    }

    func test_windowWrappingPastMidnight() {
        let q = QuietHours(isEnabled: true, startMinuteOfDay: 22 * 60, endMinuteOfDay: 7 * 60)
        XCTAssertTrue(q.contains(at(23, 30), calendar: Fixtures.utc))
        XCTAssertTrue(q.contains(at(0, 0), calendar: Fixtures.utc))
        XCTAssertTrue(q.contains(at(6, 59), calendar: Fixtures.utc))
        XCTAssertFalse(q.contains(at(7, 0), calendar: Fixtures.utc))
        XCTAssertFalse(q.contains(at(21, 59), calendar: Fixtures.utc))
    }

    func test_disabledOrEmptyWindowContainsNothing() {
        XCTAssertFalse(QuietHours(isEnabled: false, startMinuteOfDay: 0, endMinuteOfDay: 1439).contains(at(12, 0), calendar: Fixtures.utc))
        XCTAssertFalse(QuietHours(isEnabled: true, startMinuteOfDay: 600, endMinuteOfDay: 600).contains(at(10, 0), calendar: Fixtures.utc))
    }

    func test_usesTheCalendarsTimeZone() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let q = QuietHours(isEnabled: true, startMinuteOfDay: 7 * 60, endMinuteOfDay: 9 * 60)
        // 12:00 UTC on 2026-09-23 is 08:00 in New York (EDT, UTC−4).
        XCTAssertTrue(q.contains(Fixtures.t0, calendar: newYork))
        XCTAssertFalse(q.contains(Fixtures.t0, calendar: Fixtures.utc))
    }
}
