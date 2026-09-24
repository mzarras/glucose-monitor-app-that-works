import XCTest
@testable import Sensor

final class AlertsViewTests: XCTestCase {
    /// S7 in the UI: urgent low offers no off switch, always sounds on silent, and offers no snooze
    /// longer than 30 minutes. (AlertEngine enforces the same; this proves the screen never offers it.)
    func test_S7_urgentLowCannotBeDisabledOrSnoozedPast30Minutes() {
        XCTAssertFalse(AlertKind.urgentLow.canBeDisabled)
        XCTAssertTrue(AlertKind.urgentLow.soundOnSilentIsFixed)
        XCTAssertEqual(AlertKind.urgentLow.maxSnoozeMinutes, 30)
        XCTAssertEqual(AlertsText.snoozeOptions(for: .urgentLow).max(), 30)
        XCTAssertTrue(AlertsText.snoozeOptions(for: .urgentLow).allSatisfy { $0 <= 30 })
        for kind in AlertKind.allCases where kind != .urgentLow {
            XCTAssertTrue(kind.canBeDisabled, "\(kind) is configurable")
        }
        // Whatever the stored flag says, the row reads as on.
        let row = AlertRow(kind: .urgentLow, isEnabled: false, threshold: nil, soundID: nil, soundOnSilent: false, snoozeMinutes: 30, delayMinutes: nil, repeatMinutes: 5)
        XCTAssertTrue(row.effectiveIsEnabled)
        XCTAssertTrue(row.effectiveSoundOnSilent)
    }

    @MainActor
    func test_S7_modelKeepsUrgentLowOnAndSnoozeCapped() {
        let model = AppModel.launch(arguments: [])
        model.updateAlert(.urgentLow) {
            $0.isEnabled = false
            $0.snoozeMinutes = 120
            $0.soundOnSilent = false
        }
        let row = model.alerts.row(.urgentLow)
        XCTAssertEqual(row?.isEnabled, true)
        XCTAssertEqual(row?.snoozeMinutes, 30)
        XCTAssertEqual(row?.soundOnSilent, true)
        model.updateAlert(.low) { $0.isEnabled = false; $0.soundOnSilent = false }
        XCTAssertEqual(model.alerts.row(.low)?.isEnabled, false, "other alerts are configurable")
        XCTAssertEqual(model.alerts.row(.low)?.soundOnSilent, false)
    }

    /// D27 / HANDOFF §5: quiet hours silence everything except urgent low — Low and missed
    /// readings included — and the screen says so plainly.
    func test_quietHoursSilenceEverythingExceptUrgentLow() {
        XCTAssertEqual(AlertKind.allCases.filter(\.soundsDuringQuietHours), [.urgentLow])
        XCTAssertFalse(AlertKind.low.soundsDuringQuietHours)
        XCTAssertFalse(AlertKind.missedReadings.soundsDuringQuietHours)
        XCTAssertEqual(AlertsText.quietHoursNote, "Silences all alerts except Urgent low.")
        XCTAssertEqual(AlertsText.quietHoursSchedule(QuietHours(isEnabled: true, start: TimeOfDay(hour: 22, minute: 0), end: TimeOfDay(hour: 7, minute: 0))), "10 PM – 7 AM")
    }

    /// Review m5: thresholds stay inside their limits whatever the screen sends.
    @MainActor
    func test_S7_thresholdsAreClampedToTheirLimits() {
        let model = AppModel.launch(arguments: [])
        model.updateAlert(.urgentLow) { $0.threshold = .glucose(mgdl: 45, isBelow: true, allowed: 40...80) }
        XCTAssertEqual(model.alerts.row(.urgentLow)?.threshold, .glucose(mgdl: 50, isBelow: true, allowed: 50...60))
        model.updateAlert(.urgentLow) { $0.threshold = .glucose(mgdl: 75, isBelow: true, allowed: 40...80) }
        XCTAssertEqual(model.alerts.row(.urgentLow)?.threshold, .glucose(mgdl: 60, isBelow: true, allowed: 50...60))
        model.updateAlert(.low) { $0.threshold = .glucose(mgdl: 30, isBelow: true, allowed: 0...500) }
        XCTAssertEqual(model.alerts.row(.low)?.threshold, .glucose(mgdl: 60, isBelow: true, allowed: 60...100))
        model.updateAlert(.high) { $0.threshold = .glucose(mgdl: 500, isBelow: false, allowed: 0...600) }
        XCTAssertEqual(model.alerts.row(.high)?.threshold, .glucose(mgdl: 400, isBelow: false, allowed: 120...400))
        model.updateAlert(.rateOfChange) { $0.threshold = .rate(mgdlPerMinute: 9, allowed: 0...10) }
        XCTAssertEqual(model.alerts.row(.rateOfChange)?.threshold, .rate(mgdlPerMinute: 5, allowed: 2...5))
        model.updateAlert(.missedReadings) { $0.threshold = .window(minutes: 2, allowed: 0...90) }
        XCTAssertEqual(model.alerts.row(.missedReadings)?.threshold, .window(minutes: 10, allowed: 10...60))
        model.updateAlert(.high) { $0.delayMinutes = 500 }
        XCTAssertEqual(model.alerts.row(.high)?.delayMinutes, 60)
        model.updateAlert(.urgentLow) { $0.snoozeMinutes = 0 }
        XCTAssertEqual(model.alerts.row(.urgentLow)?.snoozeMinutes, 1)
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
    }

    /// D36: "Calibration needed" is a configurable sensor alert with its own sound and
    /// sound-on-silent setting.
    @MainActor
    func test_calibrationNeededAlertRow() {
        XCTAssertEqual(AlertKind.calibrationNeeded.section, .sensor)
        XCTAssertTrue(AlertKind.calibrationNeeded.canBeDisabled)
        XCTAssertFalse(AlertKind.calibrationNeeded.soundOnSilentIsFixed)
        let model = AppModel.launch(arguments: [])
        XCTAssertEqual(model.alerts.row(.calibrationNeeded)?.soundID, "warble")
        model.updateAlert(.calibrationNeeded) { $0.isEnabled = false; $0.soundOnSilent = false; $0.soundID = "sonar" }
        XCTAssertEqual(model.alerts.row(.calibrationNeeded)?.isEnabled, false)
        XCTAssertEqual(model.alerts.row(.calibrationNeeded)?.soundOnSilent, false)
        XCTAssertEqual(model.alerts.row(.calibrationNeeded)?.soundID, "sonar")
    }

    func test_everyAlertHasASection() {
        XCTAssertEqual(Set(AlertKind.allCases.map(\.section)), Set(AlertSection.allCases))
    }
}
