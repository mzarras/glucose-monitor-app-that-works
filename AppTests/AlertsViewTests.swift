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

    func test_everyAlertHasASection() {
        XCTAssertEqual(Set(AlertKind.allCases.map(\.section)), Set(AlertSection.allCases))
    }
}
