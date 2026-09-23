import GlucoseCore
import WidgetCore
import XCTest
@testable import Sensor

final class CalibrationRulesTests: XCTestCase {
    private let range = 40...400

    private func state(_ sensor: SensorState = activeSensor, latest reading: LatestReading? = latest(.mgdl(105), ageMinutes: 3),
                       range: ClosedRange<Int>? = 40...400, submission: CalibrationSubmission? = nil) -> CalibrationViewState {
        CalibrationViewState(sensorState: sensor, latestLiveReading: reading, acceptedRange: range, lastSubmission: submission)
    }

    // MARK: Entry and typo protection

    func test_parse() {
        XCTAssertEqual(CalibrationRules.parse("", acceptedRange: range), .empty)
        XCTAssertEqual(CalibrationRules.parse("  ", acceptedRange: range), .empty)
        XCTAssertEqual(CalibrationRules.parse("abc", acceptedRange: range), .invalid)
        XCTAssertEqual(CalibrationRules.parse("1.5", acceptedRange: range), .invalid)
        XCTAssertEqual(CalibrationRules.parse("-50", acceptedRange: range), .invalid)
        XCTAssertEqual(CalibrationRules.parse("1234", acceptedRange: range), .invalid)
        XCTAssertEqual(CalibrationRules.parse("３４５", acceptedRange: range), .invalid, "full-width digits are refused")
        XCTAssertEqual(CalibrationRules.parse("39", acceptedRange: range), .outOfRange(range))
        XCTAssertEqual(CalibrationRules.parse("40", acceptedRange: range), .valid(40))
        XCTAssertEqual(CalibrationRules.parse(" 112 ", acceptedRange: range), .valid(112))
        XCTAssertEqual(CalibrationRules.parse("400", acceptedRange: range), .valid(400))
        XCTAssertEqual(CalibrationRules.parse("401", acceptedRange: range), .outOfRange(range))
    }

    func test_retypeMustMatchExactly() {
        XCTAssertTrue(CalibrationRules.retypeMatches(155, retyped: "155"))
        XCTAssertFalse(CalibrationRules.retypeMatches(155, retyped: "55"), "the typo this step exists to catch")
        XCTAssertFalse(CalibrationRules.retypeMatches(55, retyped: "155"))
        XCTAssertFalse(CalibrationRules.retypeMatches(155, retyped: ""))
        XCTAssertFalse(CalibrationRules.retypeMatches(155, retyped: "15x"))
    }

    // MARK: Difference check (larger of 20 mg/dL or 20 %)

    func test_differenceLimit() {
        XCTAssertEqual(CalibrationRules.differenceLimit(sensorMgdl: 50), 20)
        XCTAssertEqual(CalibrationRules.differenceLimit(sensorMgdl: 100), 20)
        XCTAssertEqual(CalibrationRules.differenceLimit(sensorMgdl: 150), 30, accuracy: 0.0001)
        XCTAssertEqual(CalibrationRules.differenceLimit(sensorMgdl: 300), 60, accuracy: 0.0001)
    }

    func test_differenceCheck() {
        let at105 = latest(.mgdl(105), ageMinutes: 3)
        XCTAssertEqual(CalibrationRules.difference(fingerstick: 125, latest: at105, sensorState: activeSensor, now: t0), .withinLimit(sensorMgdl: 105, difference: 20))
        // 20 % of 105 is exactly 21: a difference of 21 is not more than the limit, 22 is.
        XCTAssertEqual(CalibrationRules.difference(fingerstick: 126, latest: at105, sensorState: activeSensor, now: t0), .withinLimit(sensorMgdl: 105, difference: 21))
        XCTAssertEqual(CalibrationRules.difference(fingerstick: 127, latest: at105, sensorState: activeSensor, now: t0), .large(sensorMgdl: 105, difference: 22, limit: 21))
        XCTAssertEqual(CalibrationRules.difference(fingerstick: 121, latest: latest(.mgdl(100), ageMinutes: 3), sensorState: activeSensor, now: t0), .large(sensorMgdl: 100, difference: 21, limit: 20))
        XCTAssertFalse(CalibrationRules.isLargeDifference(20, sensorMgdl: 60), "under 100 the 20 mg/dL floor applies")
        XCTAssertTrue(CalibrationRules.isLargeDifference(21, sensorMgdl: 60))
        XCTAssertEqual(CalibrationRules.difference(fingerstick: 85, latest: at105, sensorState: activeSensor, now: t0), .withinLimit(sensorMgdl: 105, difference: 20))
        let at200 = latest(.mgdl(200), ageMinutes: 3)
        XCTAssertFalse(CalibrationRules.difference(fingerstick: 240, latest: at200, sensorState: activeSensor, now: t0).needsExtraConfirmation)
        XCTAssertTrue(CalibrationRules.difference(fingerstick: 241, latest: at200, sensorState: activeSensor, now: t0).needsExtraConfirmation)
        // S4: a LOW/HIGH reading cannot be compared numerically → always the "are you sure" step.
        XCTAssertEqual(CalibrationRules.difference(fingerstick: 45, latest: latest(.belowRange, ageMinutes: 1), sensorState: activeSensor, now: t0), .sensorFlag(.belowRange))
        // No current reading (stale) → "are you sure".
        XCTAssertEqual(CalibrationRules.difference(fingerstick: 105, latest: latest(.mgdl(105), ageMinutes: 12), sensorState: activeSensor, now: t0), .noCurrentReading)
        XCTAssertEqual(CalibrationRules.difference(fingerstick: 105, latest: nil, sensorState: activeSensor, now: t0), .noCurrentReading)
        XCTAssertNotNil(CalibrationRules.largeDifferenceMessage(.sensorFlag(.belowRange), fingerstick: 45))
        XCTAssertFalse(CalibrationRules.largeDifferenceMessage(.sensorFlag(.belowRange), fingerstick: 45)!.contains("40"), "S4")
    }

    // MARK: Trend advice (warn, don't block)

    func test_trendAdvice() {
        XCTAssertNil(CalibrationRules.trendAdvice(latest: latest(.mgdl(105), ageMinutes: 3, trend: .flat)))
        XCTAssertTrue(CalibrationRules.trendAdvice(latest: latest(.mgdl(105), ageMinutes: 3, trend: .singleUp))?.contains("rising") ?? false)
        XCTAssertNotNil(CalibrationRules.trendAdvice(latest: latest(.mgdl(105), ageMinutes: 3, trend: .notComputable)))
        // A non-flat trend never blocks: the flow still produces a request.
        var flow = CalibrationFlow(step: .entry, entryText: "108")
        flow.continueFromEntry(acceptedRange: range, now: t0)
        flow.confirmText = "108"
        XCTAssertNotNil(flow.continueFromConfirm(latest: latest(.mgdl(105), ageMinutes: 3, trend: .doubleUp), sensorState: activeSensor, now: t0))
    }

    // MARK: Availability

    func test_availability() {
        XCTAssertEqual(CalibrationRules.availability(state(), now: t0), .available)
        XCTAssertEqual(CalibrationRules.availability(state(.gracePeriod(endsAt: minutes(60))), now: t0), .available)
        let unavailable: [(String, CalibrationViewState)] = [
            ("warming up", state(.warmingUp(endsAt: minutes(30)))),
            ("expired", state(.expired)),
            ("grace ended", state(.gracePeriod(endsAt: minutes(-1)))),
            ("not paired", state(.notPaired)),
            ("error", state(.error(code: 1, description: "x"))),
            ("failed", state(.failed(reason: "x"))),
            ("Bluetooth off", state(.bluetoothUnavailable(.poweredOff))),
            ("searching", state(.searching)),
            ("source cannot calibrate", state(range: nil)),
            ("another pending", state(submission: CalibrationSubmission(request: CalibrationRequest(mgdl: 100, takenAt: t0), outcome: .status(.queued), updatedAt: t0))),
        ]
        for (name, value) in unavailable {
            guard case .unavailable(let reason) = CalibrationRules.availability(value, now: t0) else {
                XCTFail("\(name) should be unavailable")
                continue
            }
            XCTAssertFalse(reason.isEmpty, name)
        }
        // A finished submission does not block the next one.
        XCTAssertEqual(CalibrationRules.availability(state(submission: CalibrationSubmission(request: CalibrationRequest(mgdl: 100, takenAt: t0), outcome: .status(.accepted), updatedAt: t0)), now: t0), .available)
    }

    // MARK: Flow

    func test_flowHappyPath() {
        var flow = CalibrationFlow(step: .entry, entryText: "112")
        flow.continueFromEntry(acceptedRange: range, now: t0)
        XCTAssertEqual(flow.step, .confirm(value: 112, takenAt: t0))
        flow.confirmText = "11"
        XCTAssertFalse(flow.confirmMismatch, "no warning while still typing")
        XCTAssertNil(flow.continueFromConfirm(latest: latest(.mgdl(105), ageMinutes: 3), sensorState: activeSensor, now: t0))
        flow.confirmText = "121"
        XCTAssertTrue(flow.confirmMismatch)
        XCTAssertNil(flow.continueFromConfirm(latest: latest(.mgdl(105), ageMinutes: 3), sensorState: activeSensor, now: t0))
        XCTAssertEqual(flow.step, .confirm(value: 112, takenAt: t0), "a mismatch never submits")
        flow.confirmText = "112"
        let request = flow.continueFromConfirm(latest: latest(.mgdl(105), ageMinutes: 3), sensorState: activeSensor, now: minutes(1))
        XCTAssertEqual(request?.mgdl, 112)
        XCTAssertEqual(request?.takenAt, t0, "the time the value was entered")
        XCTAssertEqual(flow.step, request.map { .submitted($0) })
    }

    func test_flowLargeDifferenceNeedsExplicitConfirmation() {
        var flow = CalibrationFlow(step: .entry, entryText: "155")
        flow.continueFromEntry(acceptedRange: range, now: t0)
        flow.confirmText = "155"
        XCTAssertNil(flow.continueFromConfirm(latest: latest(.mgdl(105), ageMinutes: 3), sensorState: activeSensor, now: t0))
        XCTAssertEqual(flow.step, .largeDifference(value: 155, takenAt: t0, difference: .large(sensorMgdl: 105, difference: 50, limit: 21)))
        let request = flow.confirmLargeDifference()
        XCTAssertEqual(request?.mgdl, 155)
        flow.startOver()
        XCTAssertEqual(flow.step, .entry)
        XCTAssertEqual(flow.confirmText, "")
    }

    func test_flowRefusesInvalidEntry() {
        var flow = CalibrationFlow(step: .entry, entryText: "30")
        flow.continueFromEntry(acceptedRange: range, now: t0)
        XCTAssertEqual(flow.step, .entry)
        XCTAssertNil(flow.confirmLargeDifference(), "not reachable from entry")
    }

    /// Review m4: while retyping, the first value is not on screen; it appears only once both match.
    func test_retypeStepNeverShowsTheFirstValue() {
        var flow = CalibrationFlow(step: .entry, entryText: "155")
        flow.continueFromEntry(acceptedRange: range, now: t0)
        for partial in ["", "1", "15", "55", "515", "156"] {
            flow.confirmText = partial
            XCTAssertFalse(flow.showsValueForReview, "'\(partial)' must not reveal the first value")
        }
        flow.confirmText = "155"
        XCTAssertTrue(flow.showsValueForReview)
        for text in [CalibrationRules.retypePrompt, CalibrationRules.mismatchMessage] {
            XCTAssertNil(text.rangeOfCharacter(from: .decimalDigits), "no digits that could be copied: \(text)")
        }
    }

    func test_outcomeText() {
        XCTAssertEqual(CalibrationRules.outcomeText(.status(.queued)).title, "Waiting for sensor")
        XCTAssertTrue(CalibrationRules.outcomeText(.status(.queued)).detail.contains("5 minutes"))
        XCTAssertEqual(CalibrationRules.outcomeText(.status(.accepted)).title, "Accepted")
        XCTAssertEqual(CalibrationRules.outcomeText(.status(.rejected(code: 3, reason: "Glucose changing too fast"))).detail, "Glucose changing too fast. Readings are unchanged.")
        XCTAssertEqual(CalibrationRules.outcomeText(.status(.unknown(description: "No answer"))).title, "Outcome unknown")
        XCTAssertEqual(CalibrationRules.outcomeText(.refused(.valueOutOfRange(accepted: 40...400))).detail, "The sensor accepts 40–400 mg/dL.")
    }
}
