import XCTest
import GlucoseCore
@testable import AlertEngine

@MainActor
final class SensorAlertTests: XCTestCase {
    private var expiresIn8Days: SensorState {
        .active(sessionStart: Fixtures.session.start, expiresAt: Fixtures.session.expiresAt)
    }

    func test_S5_bluetoothUnavailableAlertsAndClears() {
        let h = EngineHarness()
        let off = h.send(.sensorState(.bluetoothUnavailable(.poweredOff)))
        XCTAssertEqual(off.fired, [.bluetoothUnavailable])
        XCTAssertEqual(off.firedNotice(.bluetoothUnavailable)?.body, "Bluetooth is off. No readings can arrive.")
        XCTAssertEqual(off.firedNotice(.bluetoothUnavailable)?.soundsOnSilent, true)
        XCTAssertEqual(h.send(.sensorState(.searching)).cancelled, [.bluetoothUnavailable])
        let unauthorized = h.send(.sensorState(.bluetoothUnavailable(.unauthorized)))
        XCTAssertEqual(unauthorized.firedNotice(.bluetoothUnavailable)?.body, "Bluetooth permission is off for this app. No readings can arrive.")
        h.send(.sensorState(.active(sessionStart: Fixtures.session.start, expiresAt: Fixtures.session.expiresAt)))
        XCTAssertEqual(h.send(.sensorState(.bluetoothUnavailable(.unsupported))).firedNotice(.bluetoothUnavailable)?.body,
                       "This phone cannot use Bluetooth LE. No readings can arrive.")
    }

    func test_bluetoothResettingWaitsForTheNextState() {
        let h = EngineHarness()
        XCTAssertEqual(h.send(.sensorState(.bluetoothUnavailable(.resetting))).fired, [])
        XCTAssertEqual(h.send(.sensorState(.bluetoothUnavailable(.poweredOff))).fired, [.bluetoothUnavailable])
        XCTAssertEqual(h.send(.sensorState(.bluetoothUnavailable(.resetting))).cancelled, [], "resetting neither fires nor clears")
    }

    func test_S5_sensorErrorAlertsAndTheConnectionCycleDoesNotClearIt() {
        let h = EngineHarness()
        let error = h.send(.sensorState(.error(code: 7, description: "signal loss")))
        XCTAssertEqual(error.fired, [.sensorError])
        XCTAssertEqual(error.firedNotice(.sensorError)?.body, "The sensor reported error 7: signal loss.")
        for transient: SensorState in [.searching, .connecting, .authenticating, .bluetoothUnavailable(.resetting)] {
            XCTAssertEqual(h.send(.sensorState(transient)).cancelled, [], "\(transient)")
        }
        XCTAssertEqual(h.send(.sensorState(expiresIn8Days)).cancelled, [.sensorError])
    }

    func test_S5_sensorFailedAlerts() {
        let h = EngineHarness()
        let failed = h.send(.sensorState(.failed(SensorFailure(kind: .sensorFailed, message: "The sensor has failed."))))
        XCTAssertEqual(failed.fired, [.sensorFailed])
        XCTAssertEqual(failed.firedNotice(.sensorFailed)?.title, "Replace the sensor")
        XCTAssertEqual(failed.firedNotice(.sensorFailed)?.body, "Readings have stopped. The sensor has failed.")
        XCTAssertEqual(h.send(.sensorState(.notPaired)).ignoringMissedReadings.cancelled, [.sensorFailed])
    }

    /// D36: only failures that need a new sensor or a new pairing raise the sensor alert.
    func test_S5_transientSensorFailuresDoNotRaiseTheSensorAlert() {
        let transient = SensorFailure.Kind.allCases.filter { !SensorFailure(kind: $0, message: "").raisesSensorAlert }
        XCTAssertEqual(Set(transient), [.bluetoothPairingIncomplete, .authenticationFailed, .rejectedAfterAuthentication,
                                        .otherAppRejected, .clockMismatch, .noGlucoseValue, .sessionLengthUnknown,
                                        .credentialsUnavailable, .other])
        for kind in transient {
            let h = EngineHarness()
            h.send(.sensorState(.active(sessionStart: Fixtures.session.start, expiresAt: Fixtures.session.expiresAt)))
            h.send(.sensorState(.error(code: 7, description: "x")))                 // an alert already firing
            let actions = h.send(.sensorState(.failed(SensorFailure(kind: kind, message: "transient"))))
            XCTAssertEqual(actions.fired, [], "\(kind)")
            XCTAssertEqual(actions.cancelled, [], "\(kind): does not clear other sensor alerts either")
            XCTAssertEqual(h.phase(.sensorError), .firing(since: Fixtures.t0), "\(kind)")
            XCTAssertEqual(h.phase(.sensorFailed), .armed, "\(kind)")
        }
    }

    func test_S5_endedSensorAndLostPairingRaiseTheSensorAlert() {
        let cases: [(SensorFailure.Kind, String)] = [
            (.sensorFailed, "Replace the sensor"), (.sessionStopped, "Replace the sensor"), (.unsupportedSensor, "Replace the sensor"),
            (.pairingRejected, "Pair the sensor again"), (.pairingCodeNeeded, "Pair the sensor again"), (.bondRemoved, "Pair the sensor again"),
        ]
        for (kind, title) in cases {
            let h = EngineHarness()
            let message = "Message for \(kind.rawValue)."
            let actions = h.send(.sensorState(.failed(SensorFailure(kind: kind, message: message))))
            XCTAssertEqual(actions.fired, [.sensorFailed], "\(kind)")
            XCTAssertEqual(actions.firedNotice(.sensorFailed)?.title, title, "\(kind)")
            XCTAssertEqual(actions.firedNotice(.sensorFailed)?.body, "Readings have stopped. \(message)", "\(kind)")
            XCTAssertEqual(actions.firedNotice(.sensorFailed)?.soundsOnSilent, true)
            XCTAssertEqual(h.send(.sensorState(.searching)).cancelled, [], "\(kind): the connection cycle does not clear it")
            XCTAssertEqual(h.send(.sensorState(.failed(SensorFailure(kind: .clockMismatch, message: "")))).cancelled, [], "nor does a transient failure")
            XCTAssertEqual(h.send(.sensorState(.warmingUp(endsAt: h.now.addingTimeInterval(1800)))).ignoringMissedReadings.cancelled,
                           [.sensorFailed], "\(kind): a new sensor clears it")
        }
    }

    func test_calibrationNeededAlertsAndClearsWhenActiveAgain() {
        let h = EngineHarness()
        h.send(.sensorState(.active(sessionStart: Fixtures.session.start, expiresAt: Fixtures.session.expiresAt)))
        let needed = h.send(.sensorState(.calibrationNeeded(code: 3)))
        XCTAssertEqual(needed.fired, [.calibrationNeeded])
        XCTAssertEqual(needed.firedNotice(.calibrationNeeded)?.title, "Calibration needed")
        XCTAssertEqual(needed.firedNotice(.calibrationNeeded)?.body, "The sensor needs a calibration (state 3). No readings until it is calibrated.")
        XCTAssertEqual(needed.firedNotice(.calibrationNeeded)?.soundsOnSilent, true)
        for transient: SensorState in [.searching, .connecting, .authenticating, .failed(SensorFailure(kind: .noGlucoseValue, message: ""))] {
            XCTAssertEqual(h.send(.sensorState(transient)).cancelled, [], "\(transient)")
        }
        let rejected = h.send(.sensorState(.calibrationError(code: 5)))
        XCTAssertEqual(rejected.cancelled, [], "still the same episode")
        XCTAssertEqual(h.advance(minutes: 30).firedNotice(.calibrationNeeded)?.body,
                       "The sensor could not use the calibration (state 5). No readings until it is calibrated again.",
                       "re-alerts every 30 minutes by default, with the current text")
        XCTAssertEqual(h.send(.sensorState(.active(sessionStart: Fixtures.session.start, expiresAt: Fixtures.session.expiresAt))).cancelled,
                       [.calibrationNeeded])
    }

    func test_calibrationErrorAlertsAndCanBeTurnedOff() {
        let h = EngineHarness()
        XCTAssertEqual(h.send(.sensorState(.calibrationError(code: 1))).fired, [.calibrationNeeded])
        XCTAssertEqual(h.settings { $0.calibrationNeeded.isEnabled = false }.cancelled, [.calibrationNeeded])
        XCTAssertEqual(h.phase(.calibrationNeeded), .off)
    }

    func test_S5_sensorExpiredAlertsUntilANewSensor() {
        let h = EngineHarness()
        XCTAssertEqual(h.send(.sensorState(.expired)).fired, [.sensorExpired])
        XCTAssertEqual(h.send(.sensorState(.searching)).cancelled, [])
        XCTAssertEqual(h.send(.sensorState(.warmingUp(endsAt: h.now.addingTimeInterval(1800)))).ignoringMissedReadings.cancelled, [.sensorExpired])
    }

    func test_statusAlertsReAlertAtTheirSnoozeInterval() {
        let h = EngineHarness()
        h.send(.sensorState(.error(code: 1, description: "x")))
        XCTAssertEqual(h.advance(minutes: 119).fired, [])
        XCTAssertEqual(h.advance(minutes: 1).fired, [.sensorError], "120-minute default")
    }

    func test_statusAlertsCanBeTurnedOff() {
        let h = EngineHarness()
        h.settings { $0.sensorError.isEnabled = false }
        XCTAssertEqual(h.send(.sensorState(.error(code: 1, description: "x"))).fired, [])
        XCTAssertEqual(h.phase(.sensorError), .off)
    }

    func test_warmUpCompleteIsAnnouncedOnce() {
        let h = EngineHarness()
        let end = h.now.addingTimeInterval(minutes(30))
        XCTAssertEqual(h.send(.sensorState(.warmingUp(endsAt: end))).fired, [])
        h.send(.sensorState(.searching))
        h.clock.advance(minutes: 30)
        let ready = h.send(.sensorState(.active(sessionStart: Fixtures.t0, expiresAt: Fixtures.t0.addingTimeInterval(10 * 86_400))))
        XCTAssertEqual(ready.fired, [.sensorWarmUpComplete])
        XCTAssertNil(ready.firedNotice(.sensorWarmUpComplete)?.snoozeMinutes, "announcements have no Snooze action")
        h.send(.sensorState(.searching))
        XCTAssertEqual(h.send(.sensorState(.active(sessionStart: Fixtures.t0, expiresAt: Fixtures.t0.addingTimeInterval(10 * 86_400)))).fired, [])
    }

    func test_expiringIn24HoursThenIn2Hours() {
        let h = EngineHarness()
        let expiresAt = h.now.addingTimeInterval(30 * 3600)
        XCTAssertEqual(h.send(.sensorState(.active(sessionStart: Fixtures.t0, expiresAt: expiresAt))).fired, [])
        XCTAssertEqual(h.advance(minutes: 6 * 60).fired.filter(\.isEventAlert), [.sensorExpiringIn24Hours])
        let notice = h.engine.handle(.tick, at: h.now) // nothing more
        XCTAssertEqual(notice.fired.filter(\.isEventAlert), [])
        XCTAssertEqual(h.advance(minutes: 21 * 60).fired.filter(\.isEventAlert), [])
        XCTAssertEqual(h.advance(minutes: 60).fired.filter(\.isEventAlert), [.sensorExpiringIn2Hours])
        XCTAssertEqual(h.advance(minutes: 60).fired.filter(\.isEventAlert), [])
        XCTAssertEqual(h.advance(minutes: 120).fired.filter(\.isEventAlert), [], "after expiry: nothing")
    }

    func test_onlyThe2HourNoticeWhenBothAreDueAtOnce() {
        let h = EngineHarness()
        let expiresAt = h.now.addingTimeInterval(3600)
        let actions = h.send(.sensorState(.active(sessionStart: Fixtures.t0, expiresAt: expiresAt)))
        XCTAssertEqual(actions.fired, [.sensorExpiringIn2Hours])
        XCTAssertEqual(actions.firedNotice(.sensorExpiringIn2Hours)?.body, "The session ends Sep 23, 2026 at 1:00 PM. Plan a sensor change.")
        XCTAssertEqual(h.tick().fired, [])
    }

    func test_gracePeriodIsAnnouncedOnce() {
        let h = EngineHarness()
        let ends = h.now.addingTimeInterval(12 * 3600)
        let grace = h.send(.sensorState(.gracePeriod(endsAt: ends)))
        XCTAssertEqual(grace.fired, [.sensorGracePeriod])
        XCTAssertEqual(grace.firedNotice(.sensorGracePeriod)?.body, "Readings stop Sep 24, 2026 at 12:00 AM. Change the sensor soon.")
        XCTAssertEqual(h.send(.sensorState(.gracePeriod(endsAt: ends))).fired, [])
    }

    func test_aDisabledAnnouncementIsDeliveredIfTurnedOnLaterInTheWindow() {
        let h = EngineHarness()
        h.settings { $0.sensorExpiringIn24Hours.isEnabled = false }
        XCTAssertEqual(h.send(.sensorState(.active(sessionStart: Fixtures.t0, expiresAt: h.now.addingTimeInterval(20 * 3600)))).fired, [])
        XCTAssertEqual(h.settings { $0.sensorExpiringIn24Hours.isEnabled = true }.fired, [.sensorExpiringIn24Hours])
    }

    func test_acknowledgingOrSnoozingAnAnnouncementRemovesIt() {
        let h = EngineHarness()
        XCTAssertEqual(h.user(.acknowledge(.sensorGracePeriod)).first, .cancel(.sensorGracePeriod))
        XCTAssertEqual(h.user(.snooze(.sensorWarmUpComplete, minutes: 30)).first, .cancel(.sensorWarmUpComplete))
    }

    func test_silenceStopsOnlyTheSound() {
        let h = EngineHarness()
        h.mgdl(50)
        XCTAssertEqual(h.user(.silence(.urgentLow)).first, .stopSound(.urgentLow))
        XCTAssertEqual(h.phase(.urgentLow), .firing(since: Fixtures.t0), "repeats continue")
    }

    func test_acknowledgingSomethingThatIsNotActiveIsIgnored() {
        let h = EngineHarness()
        XCTAssertEqual(h.user(.acknowledge(.low)).ignoringMissedReadings, [.userActionIgnored(.acknowledge(.low))])
    }

    func test_announcementMemoryHoldsOneDatePerKind() {
        let h = EngineHarness()
        var fired = 0
        for day in 0..<40 {
            fired += h.send(.sensorState(.gracePeriod(endsAt: Fixtures.t0.addingTimeInterval(Double(day) * 86_400 + 3600)))).fired.count
        }
        XCTAssertEqual(fired, 40, "each session's grace period (a day apart) is announced once")
        XCTAssertEqual(h.engine.snapshot.announcedSessionDates.count, 1)
    }

    /// Safety review WS4 M1: session dates are derived from the phone clock at each connection, so
    /// they jitter by a second or so; that must not re-announce.
    func test_announcementsDoNotRepeatWhenDerivedDatesJitter() {
        let h = EngineHarness()
        let expires = h.now.addingTimeInterval(20 * 3600)
        var expiring = 0
        for i in 0..<12 {
            let jitter = TimeInterval(i % 3) - 1   // −1, 0, +1 s
            let state = SensorState.active(sessionStart: expires.addingTimeInterval(-10 * 86_400 + jitter), expiresAt: expires.addingTimeInterval(jitter))
            expiring += h.send(.sensorState(state)).fired.filter { $0 == .sensorExpiringIn24Hours }.count
            h.clock.advance(minutes: 5)
        }
        XCTAssertEqual(expiring, 1)
        var grace = 0
        for i in 0..<12 {
            grace += h.send(.sensorState(.gracePeriod(endsAt: h.now.addingTimeInterval(3600 + TimeInterval(i % 2))))).fired
                .filter { $0 == .sensorGracePeriod }.count
            h.clock.advance(minutes: 5)
        }
        XCTAssertEqual(grace, 1, "grace end jittering (and 'moving' with the clock by minutes) is one session")
        // A new sensor ten days later is announced again.
        let next = expires.addingTimeInterval(10 * 86_400)
        h.clock.set(next.addingTimeInterval(-20 * 3600))
        XCTAssertEqual(h.send(.sensorState(.active(sessionStart: next.addingTimeInterval(-10 * 86_400), expiresAt: next))).fired
            .filter { $0 == .sensorExpiringIn24Hours }, [.sensorExpiringIn24Hours])
    }
}

@MainActor
final class TrioBridgeAlertTests: XCTestCase {
    func test_S5_trioBridgeWriteFailureAlerts() {
        let h = EngineHarness()
        let failing = h.send(.trioBridge(.writeFailing(since: h.now, reason: "App Group container unavailable")))
        XCTAssertEqual(failing.fired, [.trioBridge])
        XCTAssertEqual(failing.firedNotice(.trioBridge)?.body, "Writing readings to Trio fails: App Group container unavailable.")
        XCTAssertEqual(failing.firedNotice(.trioBridge)?.soundsOnSilent, true)
        XCTAssertEqual(h.send(.trioBridge(.healthy)).cancelled, [.trioBridge])
    }

    func test_trioNotConsumingAlertsAfter15Minutes() {
        let h = EngineHarness()
        XCTAssertEqual(h.send(.trioBridge(.notConsumedSince(h.now))).fired, [])
        XCTAssertEqual(h.advance(minutes: 14).fired, [])
        let alert = h.advance(minutes: 1)
        XCTAssertEqual(alert.fired, [.trioBridge])
        XCTAssertEqual(alert.firedNotice(.trioBridge)?.body, "Trio has not read a new reading since 12:00 PM.")
    }

    func test_bridgeOffNeverAlerts() {
        let h = EngineHarness()
        h.send(.trioBridge(.off))
        XCTAssertEqual(h.advance(minutes: 60).fired, [])
    }

    func test_bridgeAlertCanBeTurnedOff() {
        let h = EngineHarness()
        h.send(.trioBridge(.writeFailing(since: h.now, reason: "x")))
        XCTAssertEqual(h.settings { $0.trioBridge.isEnabled = false }.cancelled, [.trioBridge])
    }
}

@MainActor
final class EngineSnapshotTests: XCTestCase {
    func test_restoredEngineRemembersAnAcknowledgement() throws {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.acknowledge(.urgentLow))
        let data = try XCTUnwrap(h.engine.snapshot.encoded())
        let restored = try XCTUnwrap(AlertEngineSnapshot.decode(data))
        XCTAssertEqual(restored, h.engine.snapshot)
        let later = h.now.addingTimeInterval(minutes(1))
        var engine = AlertEngine(settings: .defaults, configuration: Fixtures.configuration, restoring: restored, now: later)
        let actions = engine.handle(.reading(Fixtures.reading(.mgdl(50), at: later), session: Fixtures.session), at: later)
        XCTAssertEqual(actions.fired, [], "a relaunch does not re-sound an acknowledged alert")
        XCTAssertEqual(engine.phase(of: .urgentLow), .snoozed(until: Fixtures.t0.addingTimeInterval(minutes(30))))
    }

    func test_S7_restoredUrgentLowSnoozeIsClampedTo30Minutes() {
        var snapshot = AlertEngineSnapshot(start: Fixtures.t0)
        snapshot.episodes[AlertKind.urgentLow.rawValue] = .snoozed(AlertSnooze(snoozedAt: Fixtures.t0, until: Fixtures.t0.addingTimeInterval(3 * 3600)))
        let engine = AlertEngine(settings: .defaults, restoring: snapshot, now: Fixtures.t0.addingTimeInterval(60))
        XCTAssertEqual(engine.phase(of: .urgentLow), .snoozed(until: Fixtures.t0.addingTimeInterval(minutes(30))))

        // A snooze stamped in the future (the clock moved backwards) ends at once: how long it has
        // really lasted is unknowable (review B1; ClockFaultTests).
        var future = AlertEngineSnapshot(start: Fixtures.t0)
        future.episodes[AlertKind.urgentLow.rawValue] = .snoozed(AlertSnooze(
            snoozedAt: Fixtures.t0.addingTimeInterval(7200), until: Fixtures.t0.addingTimeInterval(9000)))
        let skewed = AlertEngine(settings: .defaults, restoring: future, now: Fixtures.t0)
        XCTAssertEqual(skewed.phase(of: .urgentLow), .snoozed(until: Fixtures.t0))
    }

    func test_S7_restoredSnoozeFromATamperedFileIsClamped() throws {
        var snapshot = AlertEngineSnapshot(start: Fixtures.t0)
        snapshot.episodes[AlertKind.urgentLow.rawValue] = .snoozed(AlertSnooze(snoozedAt: Fixtures.t0, until: .distantFuture))
        let decoded = try XCTUnwrap(AlertEngineSnapshot.decode(snapshot.encoded()))
        var engine = AlertEngine(settings: .defaults, configuration: Fixtures.configuration, restoring: decoded, now: Fixtures.t0)
        let at = Fixtures.t0.addingTimeInterval(minutes(30))
        XCTAssertEqual(engine.handle(.reading(Fixtures.reading(.mgdl(50), at: at), session: Fixtures.session), at: at).fired, [.urgentLow])
    }

    func test_unreadableSnapshotMeansStartFresh() {
        XCTAssertNil(AlertEngineSnapshot.decode(nil))
        XCTAssertNil(AlertEngineSnapshot.decode(Data("garbage".utf8)))
    }

    func test_unknownAlertKindsAreDroppedOnRestore() {
        var snapshot = AlertEngineSnapshot(start: Fixtures.t0)
        snapshot.episodes["retiredAlert"] = .firing(AlertFiring(since: Fixtures.t0, lastSoundedAt: Fixtures.t0))
        let engine = AlertEngine(settings: .defaults, restoring: snapshot, now: Fixtures.t0)
        XCTAssertNil(engine.snapshot.episodes["retiredAlert"])
    }
}
