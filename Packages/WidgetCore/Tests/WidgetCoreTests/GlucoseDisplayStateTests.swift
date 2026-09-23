import GlucoseCore
import XCTest
@testable import WidgetCore

final class GlucoseDisplayStateTests: XCTestCase {
    private func classify(_ latest: LatestReading?, _ state: SensorState = Fixture.activeSensor, now: Date = Fixture.now) -> GlucoseDisplayState {
        GlucoseDisplayState.classify(latest: latest, sensorState: state, now: now)
    }

    // MARK: S5 — staleness is explicit

    func test_S5_staleAt10MinutesAndNoDataAt20Minutes() {
        let at = { (minutes: Double) in Fixture.latest(.mgdl(105), minutesAgo: minutes) }
        XCTAssertEqual(classify(at(0)), .current(at(0)))
        XCTAssertEqual(classify(at(9.99)), .current(at(9.99)))
        XCTAssertEqual(classify(at(10)), .stale(at(10)), "stale at exactly 10 min")
        XCTAssertEqual(classify(at(19.99)), .stale(at(19.99)))
        XCTAssertEqual(classify(at(20)), .noData(last: at(20)), "no data at exactly 20 min")
        XCTAssertEqual(classify(at(240)), .noData(last: at(240)))
        XCTAssertEqual(classify(nil), .noData(last: nil))
    }

    func test_S5_noNumberIsDisplayedOnceDataIsMissingOrTheSensorIsUnusable() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 1)
        let unusable: [SensorState] = [
            .notPaired,
            .warmingUp(endsAt: Fixture.now.addingTimeInterval(600)),
            .expired,
            .gracePeriod(endsAt: Fixture.now.addingTimeInterval(-1)),
            .failed(reason: "Sensor failed"),
            .error(code: 7, description: "Sensor error"),
        ]
        for state in unusable {
            XCTAssertNil(classify(reading, state).displayedReading, "\(state) must not show a number")
        }
        XCTAssertNil(classify(Fixture.latest(.mgdl(105), minutesAgo: 20)).displayedReading)
    }

    func test_bluetoothOffDoesNotHideAFreshRealReading() {
        // The reading is real and fresh; the Bluetooth problem is reported as its own S5 banner.
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 2)
        XCTAssertEqual(classify(reading, .bluetoothUnavailable(.poweredOff)), .current(reading))
        XCTAssertEqual(classify(Fixture.latest(.mgdl(105), minutesAgo: 12), .bluetoothUnavailable(.unauthorized)), .stale(Fixture.latest(.mgdl(105), minutesAgo: 12)))
    }

    func test_sensorStates() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 1)
        let warmUpEnd = Fixture.now.addingTimeInterval(3_600)
        XCTAssertEqual(classify(nil, .notPaired), .notPaired)
        XCTAssertEqual(classify(nil, .warmingUp(endsAt: warmUpEnd)), .warmingUp(endsAt: warmUpEnd))
        XCTAssertEqual(classify(nil, .warmingUp(endsAt: Fixture.now)), .noData(last: nil), "warm-up over, waiting for a reading")
        XCTAssertEqual(classify(reading, .expired), .sensorExpired(last: reading))
        XCTAssertEqual(classify(reading, .gracePeriod(endsAt: Fixture.now.addingTimeInterval(60))), .current(reading))
        XCTAssertEqual(classify(reading, .gracePeriod(endsAt: Fixture.now)), .sensorExpired(last: reading))
        XCTAssertEqual(classify(reading, .failed(reason: "Sensor failed")), .sensorError(message: "Sensor failed", last: reading))
        XCTAssertEqual(classify(reading, .error(code: 7, description: "Bad sensor")), .sensorError(message: "Bad sensor (code 7)", last: reading))
        for transient in [SensorState.searching, .connecting, .authenticating] {
            XCTAssertEqual(classify(reading, transient), .current(reading))
        }
    }

    func test_futureDatedReadingCountsAsCurrent() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: -0.5)
        XCTAssertEqual(classify(reading), .current(reading))
    }

    func test_transitionDates() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 3)
        XCTAssertEqual(
            GlucoseDisplayState.transitionDates(latest: reading, sensorState: Fixture.activeSensor),
            [Fixture.minutesAgo(-7), Fixture.minutesAgo(-17)]
        )
        let end = Fixture.now.addingTimeInterval(600)
        XCTAssertEqual(GlucoseDisplayState.transitionDates(latest: nil, sensorState: .warmingUp(endsAt: end)), [end])
    }
}
