import AlertEngine
import XCTest
@testable import Sensor

final class AlertsViewTests: XCTestCase {
    /// S7 in the UI: urgent low offers no off switch, always sounds on silent, and offers no snooze
    /// longer than 30 minutes. (AlertEngine enforces the same; this proves the screen never offers it.)
    func test_S7_urgentLowCannotBeDisabledOrSnoozedPast30Minutes() {
        XCTAssertFalse(AlertKind.urgentLow.canBeDisabled)
        XCTAssertTrue(AlertKind.urgentLow.soundOnSilentIsFixed)
        XCTAssertEqual(AlertKind.urgentLow.maxSnoozeMinutes, 30)
        XCTAssertEqual(AlertKind.urgentLow.maxSnoozeMinutes, AlertLimits.urgentLowMaximumSnoozeMinutes, "one source of truth")
        XCTAssertEqual(AlertsText.snoozeOptions(for: .urgentLow).max(), 30)
        XCTAssertTrue(AlertsText.snoozeOptions(for: .urgentLow, current: 45).allSatisfy { $0 <= 30 }, "an out-of-range current value is not offered")
        for kind in AlertKind.allCases where kind != .urgentLow {
            XCTAssertTrue(kind.canBeDisabled, "\(kind) is configurable")
        }
        // Whatever the stored flag says, the row reads as on.
        let row = AlertRow(kind: .urgentLow, isEnabled: false, threshold: nil, soundID: .cascade, soundOnSilent: false, snoozeMinutes: 30, delayMinutes: nil, repeatMinutes: 5)
        XCTAssertTrue(row.effectiveIsEnabled)
        XCTAssertTrue(row.effectiveSoundOnSilent)
    }

    /// Edits go through AlertEngine's clamping settings: urgent low cannot be turned off or made to
    /// follow the ringer switch, and its snooze stays within 1–30 minutes.
    func test_S7_editsKeepUrgentLowOnAndSnoozeCapped() {
        var settings = AlertSettings.defaults
        for edit in [AlertEdit.enabled(.urgentLow, false), .snooze(.urgentLow, 120), .soundOnSilent(.urgentLow, false)] {
            settings = AlertsMapping.apply(edit, to: settings)
        }
        let row = AlertsMapping.make(settings).row(.urgentLow)
        XCTAssertEqual(row?.isEnabled, true)
        XCTAssertEqual(row?.snoozeMinutes, 30)
        XCTAssertEqual(row?.soundOnSilent, true)
        XCTAssertTrue(settings.isEnabled(.urgentLow))
        settings = AlertsMapping.apply(.snooze(.urgentLow, 0), to: settings)
        XCTAssertEqual(settings.urgentLow.snoozeMinutes, 1)
        // Other alerts are configurable.
        settings = AlertsMapping.apply(.enabled(.low, false), to: settings)
        settings = AlertsMapping.apply(.soundOnSilent(.low, false), to: settings)
        XCTAssertEqual(AlertsMapping.make(settings).row(.low)?.isEnabled, false)
        XCTAssertEqual(AlertsMapping.make(settings).row(.low)?.soundOnSilent, false)
    }

    /// D27 / HANDOFF §5: quiet hours silence everything except urgent low — Low and missed
    /// readings included — and the screen says so plainly.
    func test_quietHoursSilenceEverythingExceptUrgentLow() {
        XCTAssertEqual(AlertKind.allCases.filter(\.soundsDuringQuietHours), [.urgentLow])
        XCTAssertFalse(AlertKind.low.soundsDuringQuietHours)
        XCTAssertFalse(AlertKind.missedReadings.soundsDuringQuietHours)
        XCTAssertEqual(AlertsText.quietHoursNote, "Silences all alerts except Urgent low.")
        XCTAssertEqual(AlertsText.quietHoursSchedule(QuietHours(isEnabled: true, startMinuteOfDay: 22 * 60, endMinuteOfDay: 7 * 60)), "10 PM – 7 AM")
        let edited = AlertsMapping.apply(.quietHours(QuietHours(isEnabled: true, startMinuteOfDay: 23 * 60 + 30, endMinuteOfDay: 6 * 60)), to: .defaults)
        XCTAssertEqual(AlertsMapping.make(edited).quietHours, edited.quietHours)
    }

    /// Phase 2 must-do: thresholds use AlertEngine's `AlertLimits` (not the screen's own numbers) and
    /// stay inside them whatever the screen sends (review m5).
    func test_S7_thresholdsUseAlertLimits() {
        let rows = AlertsMapping.make(.defaults)
        XCTAssertEqual(rows.row(.urgentLow)?.threshold, .glucose(mgdl: 55, isBelow: true, allowed: AlertLimits.urgentLowThresholdMgdl))
        XCTAssertEqual(rows.row(.low)?.threshold, .glucose(mgdl: 70, isBelow: true, allowed: AlertLimits.lowThresholdMgdl))
        XCTAssertEqual(rows.row(.high)?.threshold, .glucose(mgdl: 250, isBelow: false, allowed: AlertLimits.highThresholdMgdl))
        XCTAssertEqual(rows.row(.fallingFast)?.threshold, .rate(mgdlPerMinute: 3, allowed: AlertLimits.rateThresholdMgdlPerMinute))
        XCTAssertEqual(rows.row(.missedReadings)?.threshold, .window(minutes: 15, allowed: AlertLimits.missedReadingsWindowMinutes))
        XCTAssertEqual(rows.row(.urgentLowSoon)?.threshold, .projected(mgdl: 55, minutes: AlertLimits.urgentLowSoonHorizonMinutes))

        var s = AlertSettings.defaults
        s = AlertsMapping.apply(.glucoseThreshold(.urgentLow, 45), to: s)
        XCTAssertEqual(s.urgentLow.thresholdMgdl, AlertLimits.urgentLowThresholdMgdl.lowerBound)
        s = AlertsMapping.apply(.glucoseThreshold(.urgentLow, 75), to: s)
        XCTAssertEqual(s.urgentLow.thresholdMgdl, AlertLimits.urgentLowThresholdMgdl.upperBound)
        s = AlertsMapping.apply(.glucoseThreshold(.low, 30), to: s)
        XCTAssertEqual(s.low.thresholdMgdl, AlertLimits.lowThresholdMgdl.lowerBound)
        s = AlertsMapping.apply(.glucoseThreshold(.high, 500), to: s)
        XCTAssertEqual(s.high.thresholdMgdl, AlertLimits.highThresholdMgdl.upperBound)
        s = AlertsMapping.apply(.rateThreshold(.risingFast, 9), to: s)
        XCTAssertEqual(s.risingFast.thresholdMgdlPerMinute, AlertLimits.rateThresholdMgdlPerMinute.upperBound)
        s = AlertsMapping.apply(.window(.missedReadings, 2), to: s)
        XCTAssertEqual(s.missedReadings.windowMinutes, AlertLimits.missedReadingsWindowMinutes.lowerBound)
        s = AlertsMapping.apply(.delay(.high, 500), to: s)
        XCTAssertEqual(s.high.delayMinutes, AlertLimits.highDelayMinutes.upperBound)
        s = AlertsMapping.apply(.repeatInterval(.urgentLow, 60), to: s)
        XCTAssertEqual(s.urgentLow.repeatMinutes, AlertLimits.urgentLowRepeatMinutes.upperBound)
        // An edit that doesn't fit the alert changes nothing.
        XCTAssertEqual(AlertsMapping.apply(.rateThreshold(.low, 4), to: .defaults), .defaults)
        XCTAssertEqual(AlertsMapping.apply(.delay(.low, 30), to: .defaults), .defaults)
    }

    func test_thresholdText() {
        XCTAssertEqual(AlertsText.threshold(.glucose(mgdl: 55, isBelow: true, allowed: 50...60)), "≤ 55 mg/dL")
        XCTAssertEqual(AlertsText.threshold(.glucose(mgdl: 250, isBelow: false, allowed: 120...400)), "≥ 250 mg/dL")
        XCTAssertEqual(AlertsText.threshold(.projected(mgdl: 55, minutes: 20)), "projected ≤ 55 in 20 min")
        XCTAssertEqual(AlertsText.threshold(.rate(mgdlPerMinute: 3, allowed: 2...5)), "≥ 3 mg/dL/min")
        XCTAssertEqual(AlertsText.threshold(.rate(mgdlPerMinute: 2.5, allowed: 2...5)), "≥ 2.5 mg/dL/min")
        XCTAssertEqual(AlertsText.threshold(.window(minutes: 15, allowed: 10...60)), "no reading for 15 min")
        XCTAssertNil(AlertsText.threshold(nil))
        XCTAssertEqual(AlertsText.time(TimeOfDay(hour: 22, minute: 0)), "10 PM")
        XCTAssertEqual(AlertsText.time(TimeOfDay(hour: 7, minute: 5)), "7:05 AM")
        XCTAssertEqual(TimeOfDay(minuteOfDay: 22 * 60 + 15), TimeOfDay(hour: 22, minute: 15))
    }

    /// D36: "Calibration needed" is a configurable sensor alert with its own sound and
    /// sound-on-silent setting.
    func test_calibrationNeededAlertRow() {
        XCTAssertEqual(AlertKind.calibrationNeeded.section, .sensor)
        XCTAssertTrue(AlertKind.calibrationNeeded.canBeDisabled)
        XCTAssertFalse(AlertKind.calibrationNeeded.soundOnSilentIsFixed)
        XCTAssertEqual(AlertsMapping.make(.defaults).row(.calibrationNeeded)?.soundID, .warble)
        var s = AlertSettings.defaults
        s = AlertsMapping.apply(.enabled(.calibrationNeeded, false), to: s)
        s = AlertsMapping.apply(.soundOnSilent(.calibrationNeeded, false), to: s)
        s = AlertsMapping.apply(.sound(.calibrationNeeded, .sonar), to: s)
        let row = AlertsMapping.make(s).row(.calibrationNeeded)
        XCTAssertEqual(row?.isEnabled, false)
        XCTAssertEqual(row?.soundOnSilent, false)
        XCTAssertEqual(row?.soundID, .sonar)
    }

    /// D42: "History isn't being saved" is a configurable data-flow alert, sound-on-silent off by default.
    func test_storageFailingAlertRow() {
        let row = AlertsMapping.make(.defaults).row(.storageFailing)
        XCTAssertEqual(AlertKind.storageFailing.title, "History isn't being saved")
        XCTAssertEqual(AlertKind.storageFailing.section, .dataFlow)
        XCTAssertEqual(row?.isEnabled, true)
        XCTAssertEqual(row?.soundOnSilent, false)
        var s = AlertSettings.defaults
        s = AlertsMapping.apply(.snooze(.storageFailing, 45), to: s)
        s = AlertsMapping.apply(.enabled(.storageFailing, false), to: s)
        XCTAssertEqual(s.storageFailing.snoozeMinutes, 45)
        XCTAssertFalse(s.storageFailing.isEnabled)
    }

    /// D43: the five expiry reminders are grouped in the order they come due, with the new 12 h one;
    /// the one-off ones can be Silent (24 h silent by default, D43/D53); "expired" can't; urgent low
    /// has no style control (S7).
    func test_sensorExpiryRemindersGroupAndSoundSwitch() {
        let state = AlertsMapping.make(.defaults)
        XCTAssertEqual(state.rows(in: .expiryReminders).map(\.kind), AlertKind.sensorExpiryReminders)
        XCTAssertEqual(AlertKind.sensorExpiryReminders,
                       [.sensorExpiringIn24Hours, .sensorExpiringIn12Hours, .sensorExpiringIn2Hours, .sensorGracePeriod, .sensorExpired])
        XCTAssertEqual(AlertKind.sensorExpiringIn12Hours.title, "Sensor expires in 12 h")
        XCTAssertEqual(state.row(.sensorExpiringIn12Hours)?.isEnabled, true)
        XCTAssertEqual(state.row(.sensorExpiringIn12Hours)?.soundID, .doorbell)
        XCTAssertEqual(state.row(.sensorExpiringIn24Hours)?.style, .silent, "24 h: no sound by default")
        for kind in [AlertKind.sensorExpiringIn12Hours, .sensorExpiringIn2Hours, .sensorGracePeriod] {
            XCTAssertEqual(state.row(kind)?.style, .sound, "\(kind)")
            XCTAssertEqual(state.row(kind)?.allowedStyles, [.sound, .vibrateOnly, .silent], "\(kind): one-off events can be silent")
        }
        XCTAssertEqual(state.row(.sensorExpired)?.allowedStyles, [.sound, .vibrateOnly], "expired is never silent")
        XCTAssertEqual(state.row(.urgentLow)?.allowedStyles, [], "S7: urgent low has no style control")
        XCTAssertEqual(state.row(.urgentLow)?.style, .sound)
        for kind in AlertKind.allCases where !kind.isEventAlert && kind != .urgentLow {
            XCTAssertEqual(state.row(kind)?.allowedStyles, [.sound, .vibrateOnly], "\(kind)")
        }
        XCTAssertFalse(state.rows(in: .sensor).contains { AlertKind.sensorExpiryReminders.contains($0.kind) })

        var s = AlertSettings.defaults
        s = AlertsMapping.apply(.style(.sensorExpiringIn24Hours, .sound), to: s)
        s = AlertsMapping.apply(.style(.sensorExpiringIn12Hours, .silent), to: s)
        s = AlertsMapping.apply(.enabled(.sensorExpiringIn12Hours, false), to: s)
        XCTAssertTrue(s.playsSound(.sensorExpiringIn24Hours))
        XCTAssertFalse(s.playsSound(.sensorExpiringIn12Hours))
        XCTAssertFalse(s.isEnabled(.sensorExpiringIn12Hours))
        // S7: a style edit for urgent low changes nothing; Silent is refused for condition alerts.
        for style in AlertStyleChoice.allCases {
            XCTAssertEqual(AlertsMapping.apply(.style(.urgentLow, style), to: .defaults), .defaults, "\(style)")
        }
        XCTAssertEqual(AlertsMapping.apply(.style(.sensorExpired, .silent), to: .defaults), .defaults)
    }

    /// Every alert the engine can raise has a row (S5: Bluetooth and "sensor expired" included), in
    /// a section, with the engine's default sound.
    func test_everyEngineAlertHasARowInASection() {
        let state = AlertsMapping.make(.defaults)
        XCTAssertEqual(state.rows.map(\.kind), AlertKind.allCases)
        XCTAssertEqual(Set(AlertKind.allCases.map(\.section)), Set(AlertSection.allCases))
        for row in state.rows {
            XCTAssertEqual(row.soundID, AlertSoundCatalog.defaultSound(for: row.kind), "\(row.kind)")
        }
        XCTAssertEqual(state.sounds.map(\.id), AlertSoundID.allCases)
    }
}
