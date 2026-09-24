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
            .failed(SensorFailure(kind: .sensorFailed, message: "Sensor failed")),
            .failed(SensorFailure(kind: .pairingRejected, message: "Pair again")),
            .error(code: 7, description: "Sensor error"),
            .calibrationNeeded(code: 4),
            .calibrationError(code: 8),
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

    /// D36: transient failures keep a real fresh reading on screen (a banner explains; missed
    /// readings covers a failure that lasts); ending failures and lost pairings replace it.
    func test_S5_transientFailureKeepsARealReadingOnlyWhileFresh() {
        let fresh = Fixture.latest(.mgdl(105), minutesAgo: 2)
        let old = Fixture.latest(.mgdl(105), minutesAgo: 25)
        for kind in SensorFailure.Kind.allCases {
            let failure = SensorFailure(kind: kind, message: "m")
            if failure.raisesSensorAlert {
                XCTAssertEqual(classify(fresh, .failed(failure)), .sensorFailed(failure, last: fresh), "\(kind)")
            } else {
                XCTAssertEqual(classify(fresh, .failed(failure)), .current(fresh), "\(kind)")
                XCTAssertEqual(classify(old, .failed(failure)), .noData(last: old), "\(kind): age rules still apply")
            }
        }
    }

    /// D36: while the sensor asks for a calibration (or rejected one) no number is shown, however
    /// fresh the last reading.
    func test_S5_calibrationStatesNeverShowANumber() {
        let fresh = Fixture.latest(.mgdl(105), minutesAgo: 1)
        XCTAssertEqual(classify(fresh, .calibrationNeeded(code: 4)), .calibrationNeeded(last: fresh))
        XCTAssertEqual(classify(fresh, .calibrationError(code: 8)), .calibrationRejected(last: fresh))
        XCTAssertNil(classify(fresh, .calibrationNeeded(code: 4)).displayedReading)
        XCTAssertNil(classify(nil, .calibrationError(code: 8)).displayedReading)
        XCTAssertEqual(WidgetStyle.title(.calibrationNeeded(last: fresh)), "Calibrate sensor")
        XCTAssertEqual(WidgetStyle.title(.calibrationRejected(last: nil)), "Calibration not accepted")
        XCTAssertEqual(WidgetStyle.title(.sensorFailed(SensorFailure(kind: .pairingCodeNeeded, message: "m"), last: nil)), "Pair again")
        XCTAssertEqual(WidgetStyle.title(.sensorFailed(SensorFailure(kind: .sessionStopped, message: "m"), last: nil)), "Replace sensor")
        // The latch never hides a sensor message.
        XCTAssertEqual(ClockMismatchLatch.apply(.calibrationNeeded(last: fresh), latest: fresh, latchedFor: fresh.date), .calibrationNeeded(last: fresh))
    }

    func test_clockMismatchLatchRules() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: -10)
        // Seen ahead → latched; stays latched after the clock passes the reading's date.
        let latch = ClockMismatchLatch.update(latchedFor: nil, latest: reading, now: Fixture.now)
        XCTAssertEqual(latch, reading.date)
        XCTAssertEqual(ClockMismatchLatch.update(latchedFor: latch, latest: reading, now: Fixture.now.addingTimeInterval(3_600)), reading.date)
        // Never latched for an ordinary reading; cleared by a newer one; nothing without a reading.
        XCTAssertNil(ClockMismatchLatch.update(latchedFor: nil, latest: Fixture.latest(.mgdl(105), minutesAgo: 3), now: Fixture.now))
        XCTAssertNil(ClockMismatchLatch.update(latchedFor: latch, latest: Fixture.latest(.mgdl(99), minutesAgo: 1), now: Fixture.now))
        XCTAssertNil(ClockMismatchLatch.update(latchedFor: latch, latest: nil, now: Fixture.now))
        // Applying: a number or an age becomes the mismatch; sensor messages stay.
        XCTAssertEqual(ClockMismatchLatch.apply(.current(reading), latest: reading, latchedFor: latch), .clockMismatch(latest: reading))
        XCTAssertEqual(ClockMismatchLatch.apply(.stale(reading), latest: reading, latchedFor: latch), .clockMismatch(latest: reading))
        XCTAssertEqual(ClockMismatchLatch.apply(.noData(last: reading), latest: reading, latchedFor: latch), .clockMismatch(latest: reading))
        XCTAssertEqual(ClockMismatchLatch.apply(.sensorExpired(last: reading), latest: reading, latchedFor: latch), .sensorExpired(last: reading))
        XCTAssertEqual(ClockMismatchLatch.apply(.current(reading), latest: reading, latchedFor: nil), .current(reading))
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
        let ended = SensorFailure(kind: .sensorFailed, message: "The sensor has failed. Replace it.")
        XCTAssertEqual(classify(reading, .failed(ended)), .sensorFailed(ended, last: reading))
        let unpaired = SensorFailure(kind: .bondRemoved, message: "Pair the sensor again.")
        XCTAssertEqual(classify(reading, .failed(unpaired)), .sensorFailed(unpaired, last: reading))
        XCTAssertEqual(classify(reading, .error(code: 7, description: "Bad sensor")), .sensorError(message: "Bad sensor (code 7)", last: reading))
        for transient in [SensorState.searching, .connecting, .authenticating] {
            XCTAssertEqual(classify(reading, transient), .current(reading))
        }
    }

    /// Review M1: a reading dated ahead of the phone's clock (clock moved back) must never read
    /// as current, however far ahead it is.
    func test_S5_futureDatedReadingIsNeverShownAsCurrent() {
        for minutesAhead in [5.0, 60, 600] {
            let reading = Fixture.latest(.mgdl(105), minutesAgo: -minutesAhead)
            let state = classify(reading)
            XCTAssertEqual(state, .clockMismatch(latest: reading), "\(minutesAhead) min ahead")
            XCTAssertNil(state.displayedReading, "\(minutesAhead) min ahead: no number")
            XCTAssertEqual(WidgetStyle.title(state), "Check phone clock")
        }
        // Within the sensor-clock tolerance (LiveReadingGate.futureTolerance, 60 s) it is current.
        let justAhead = Fixture.latest(.mgdl(105), minutesAgo: -0.5)
        XCTAssertEqual(classify(justAhead), .current(justAhead))
        let atTolerance = Fixture.latest(.mgdl(105), minutesAgo: -1)
        XCTAssertEqual(classify(atTolerance), .current(atTolerance))
    }

    func test_transitionDates() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 3)
        XCTAssertEqual(
            GlucoseDisplayState.transitionDates(latest: reading, sensorState: Fixture.activeSensor),
            [Fixture.minutesAgo(4), Fixture.minutesAgo(-7), Fixture.minutesAgo(-17)]
        )
        let end = Fixture.now.addingTimeInterval(600)
        XCTAssertEqual(GlucoseDisplayState.transitionDates(latest: nil, sensorState: .warmingUp(endsAt: end)), [end])
    }
}
