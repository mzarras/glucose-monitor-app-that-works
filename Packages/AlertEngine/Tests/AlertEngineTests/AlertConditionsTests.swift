import XCTest
import GlucoseCore
@testable import AlertEngine

final class AlertConditionsTests: XCTestCase {
    private func r(_ value: GlucoseValue, rate: Double? = 0) -> LiveReadingSummary {
        LiveReadingSummary(id: "x", date: Fixtures.t0, value: value, trendRate: rate)
    }

    func test_atOrBelowWithHysteresis() {
        XCTAssertEqual(GlucoseConditions.atOrBelow(r(.mgdl(55)), threshold: 55), .met, "threshold is inclusive")
        XCTAssertEqual(GlucoseConditions.atOrBelow(r(.mgdl(56)), threshold: 55), .holding)
        XCTAssertEqual(GlucoseConditions.atOrBelow(r(.mgdl(60)), threshold: 55), .holding, "within the 5 mg/dL margin")
        XCTAssertEqual(GlucoseConditions.atOrBelow(r(.mgdl(61)), threshold: 55), .clear)
        XCTAssertEqual(GlucoseConditions.atOrBelow(nil, threshold: 55), .holding, "no current reading: unknown")
    }

    func test_atOrAboveWithHysteresis() {
        XCTAssertEqual(GlucoseConditions.atOrAbove(r(.mgdl(250)), threshold: 250), .met)
        XCTAssertEqual(GlucoseConditions.atOrAbove(r(.mgdl(245)), threshold: 250), .holding)
        XCTAssertEqual(GlucoseConditions.atOrAbove(r(.mgdl(244)), threshold: 250), .clear)
        XCTAssertEqual(GlucoseConditions.atOrAbove(nil, threshold: 250), .holding)
    }

    func test_S4_flagsCountAsBeyondEveryThresholdWithoutBecomingNumbers() {
        for threshold in [50, 55, 60, 70, 100] {
            XCTAssertEqual(GlucoseConditions.atOrBelow(r(.belowRange), threshold: threshold), .met)
            XCTAssertEqual(GlucoseConditions.atOrBelow(r(.aboveRange), threshold: threshold), .clear)
        }
        for threshold in [120, 250, 400] {
            XCTAssertEqual(GlucoseConditions.atOrAbove(r(.aboveRange), threshold: threshold), .met)
            XCTAssertEqual(GlucoseConditions.atOrAbove(r(.belowRange), threshold: threshold), .clear)
        }
        // 400 is the top of the sensor range: a numeric 400 meets a 400 threshold, and HIGH does too.
        XCTAssertEqual(GlucoseConditions.atOrAbove(r(.mgdl(400)), threshold: 400), .met)
    }

    func test_lowIsSupersededByActiveUrgentLow() {
        XCTAssertEqual(GlucoseConditions.low(r(.mgdl(50)), threshold: 70, urgentLowActive: true), .clear)
        XCTAssertEqual(GlucoseConditions.low(r(.mgdl(65)), threshold: 70, urgentLowActive: false), .met)
    }

    func test_S1_urgentLowSoonUsesOnlyTheReportedRate() {
        // 70 falling 1.0/min for 20 min reaches 50 ≤ 55: met.
        XCTAssertEqual(GlucoseConditions.urgentLowSoon(r(.mgdl(70), rate: -1.0), urgentLowThreshold: 55, urgentLowActive: false), .met)
        // 70 falling 0.75/min reaches exactly 55: met (inclusive).
        XCTAssertEqual(GlucoseConditions.urgentLowSoon(r(.mgdl(70), rate: -0.75), urgentLowThreshold: 55, urgentLowActive: false), .met)
        // 70 falling 0.5/min reaches 60: inside the margin, hold.
        XCTAssertEqual(GlucoseConditions.urgentLowSoon(r(.mgdl(70), rate: -0.5), urgentLowThreshold: 55, urgentLowActive: false), .holding)
        // 70 falling 0.2/min reaches 66: clear.
        XCTAssertEqual(GlucoseConditions.urgentLowSoon(r(.mgdl(70), rate: -0.2), urgentLowThreshold: 55, urgentLowActive: false), .clear)
        // Rising: clear.
        XCTAssertEqual(GlucoseConditions.urgentLowSoon(r(.mgdl(70), rate: 1.0), urgentLowThreshold: 55, urgentLowActive: false), .clear)
    }

    func test_S1_noExtrapolationWhenRateIsMissing() {
        // Even a value one point above the threshold is not projected without a reported rate.
        XCTAssertEqual(GlucoseConditions.urgentLowSoon(r(.mgdl(56), rate: nil), urgentLowThreshold: 55, urgentLowActive: false), .holding)
        XCTAssertEqual(GlucoseConditions.urgentLowSoon(r(.mgdl(90), rate: .nan), urgentLowThreshold: 55, urgentLowActive: false), .holding)
        XCTAssertEqual(GlucoseConditions.fallingFast(r(.mgdl(90), rate: nil), threshold: 3), .holding)
        XCTAssertEqual(GlucoseConditions.risingFast(r(.mgdl(90), rate: nil), threshold: 3), .holding)
        XCTAssertEqual(GlucoseConditions.urgentLowSoon(nil, urgentLowThreshold: 55, urgentLowActive: false), .holding)
    }

    func test_urgentLowSoonStandsAsideForUrgentLowAndFlags() {
        XCTAssertEqual(GlucoseConditions.urgentLowSoon(r(.mgdl(70), rate: -3), urgentLowThreshold: 55, urgentLowActive: true), .clear)
        XCTAssertEqual(GlucoseConditions.urgentLowSoon(r(.mgdl(55), rate: -3), urgentLowThreshold: 55, urgentLowActive: false), .clear)
        XCTAssertEqual(GlucoseConditions.urgentLowSoon(r(.belowRange, rate: -3), urgentLowThreshold: 55, urgentLowActive: false), .clear)
        XCTAssertEqual(GlucoseConditions.urgentLowSoon(r(.aboveRange, rate: -3), urgentLowThreshold: 55, urgentLowActive: false), .clear)
    }

    func test_rateAlertsWithHysteresis() {
        XCTAssertEqual(GlucoseConditions.fallingFast(r(.mgdl(150), rate: -3), threshold: 3), .met)
        XCTAssertEqual(GlucoseConditions.fallingFast(r(.mgdl(150), rate: -2.5), threshold: 3), .holding)
        XCTAssertEqual(GlucoseConditions.fallingFast(r(.mgdl(150), rate: -1.9), threshold: 3), .clear)
        XCTAssertEqual(GlucoseConditions.fallingFast(r(.mgdl(150), rate: 4), threshold: 3), .clear)
        XCTAssertEqual(GlucoseConditions.risingFast(r(.mgdl(150), rate: 3.2), threshold: 3), .met)
        XCTAssertEqual(GlucoseConditions.risingFast(r(.mgdl(150), rate: 2.2), threshold: 3), .holding)
        XCTAssertEqual(GlucoseConditions.risingFast(r(.mgdl(150), rate: 1), threshold: 3), .clear)
        XCTAssertEqual(GlucoseConditions.risingFast(nil, threshold: 3), .holding)
    }

    func test_settledStates() {
        let settled: [SensorState] = [.notPaired, .warmingUp(endsAt: Fixtures.t0), .active(sessionStart: Fixtures.t0, expiresAt: Fixtures.t0),
                                      .gracePeriod(endsAt: Fixtures.t0), .expired, .failed(reason: "x"), .error(code: 1, description: "x")]
        let transient: [SensorState] = [.searching, .connecting, .authenticating, .bluetoothUnavailable(.poweredOff)]
        for s in settled { XCTAssertTrue(StatusConditions.isSettled(s), "\(s)") }
        for s in transient { XCTAssertFalse(StatusConditions.isSettled(s), "\(s)") }
    }

    func test_sensorConditions() {
        XCTAssertEqual(StatusConditions.sensorFailed(nil), .holding)
        XCTAssertEqual(StatusConditions.sensorFailed(.failed(reason: "x")), .met)
        XCTAssertEqual(StatusConditions.sensorFailed(.expired), .clear)
        XCTAssertEqual(StatusConditions.sensorError(nil), .holding)
        XCTAssertEqual(StatusConditions.sensorError(.error(code: 3, description: "x")), .met)
        XCTAssertEqual(StatusConditions.sensorError(.notPaired), .clear)
        XCTAssertEqual(StatusConditions.sensorExpired(nil), .holding)
        XCTAssertEqual(StatusConditions.sensorExpired(.expired), .met)
        XCTAssertEqual(StatusConditions.sensorExpired(.gracePeriod(endsAt: Fixtures.t0)), .clear)
        XCTAssertEqual(StatusConditions.bluetoothUnavailable(nil), .holding)
        XCTAssertEqual(StatusConditions.bluetoothUnavailable(.bluetoothUnavailable(.unauthorized)), .met)
        XCTAssertEqual(StatusConditions.bluetoothUnavailable(.bluetoothUnavailable(.resetting)), .holding)
        XCTAssertEqual(StatusConditions.bluetoothUnavailable(.searching), .clear)
        XCTAssertTrue(StatusConditions.suppressesMissedReadings(.notPaired))
        XCTAssertTrue(StatusConditions.suppressesMissedReadings(.warmingUp(endsAt: Fixtures.t0)))
        XCTAssertFalse(StatusConditions.suppressesMissedReadings(.expired))
        XCTAssertFalse(StatusConditions.suppressesMissedReadings(nil))
    }

    func test_bridgeConditions() {
        let now = Fixtures.t0
        XCTAssertEqual(StatusConditions.trioBridge(.off, now: now), .clear)
        XCTAssertEqual(StatusConditions.trioBridge(.healthy, now: now), .clear)
        XCTAssertEqual(StatusConditions.trioBridge(.writeFailing(since: now, reason: "x"), now: now), .met)
        XCTAssertEqual(StatusConditions.trioBridge(.notConsumedSince(now.addingTimeInterval(-14 * 60)), now: now), .holding)
        XCTAssertEqual(StatusConditions.trioBridge(.notConsumedSince(now.addingTimeInterval(-15 * 60)), now: now), .met)
    }

    func test_missedReadingsWindow() {
        let reference = Fixtures.t0
        XCTAssertEqual(StatusConditions.missedReadings(now: reference.addingTimeInterval(14 * 60 + 59), reference: reference, windowMinutes: 15), .clear)
        XCTAssertEqual(StatusConditions.missedReadings(now: reference.addingTimeInterval(15 * 60), reference: reference, windowMinutes: 15), .met)
    }
}
