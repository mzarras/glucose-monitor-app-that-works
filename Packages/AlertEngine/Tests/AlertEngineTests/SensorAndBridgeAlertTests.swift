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
        let failed = h.send(.sensorState(.failed(reason: "sensor failure")))
        XCTAssertEqual(failed.fired, [.sensorFailed])
        XCTAssertEqual(failed.firedNotice(.sensorFailed)?.body, "Readings have stopped. The sensor reported: sensor failure.")
        XCTAssertEqual(h.send(.sensorState(.notPaired)).ignoringMissedReadings.cancelled, [.sensorFailed])
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

    func test_announcementMemoryStaysSmall() {
        let h = EngineHarness()
        for day in 0..<40 {
            h.send(.sensorState(.gracePeriod(endsAt: Fixtures.t0.addingTimeInterval(Double(day) * 86_400 + 3600))))
        }
        XCTAssertEqual(h.engine.snapshot.announcedEvents.count, AlertEngineSnapshot.announcedEventsLimit)
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

        // A snooze stamped in the future (clock moved backwards) is capped at 30 minutes from now.
        var future = AlertEngineSnapshot(start: Fixtures.t0)
        future.episodes[AlertKind.urgentLow.rawValue] = .snoozed(AlertSnooze(
            snoozedAt: Fixtures.t0.addingTimeInterval(7200), until: Fixtures.t0.addingTimeInterval(9000)))
        let skewed = AlertEngine(settings: .defaults, restoring: future, now: Fixtures.t0)
        XCTAssertEqual(skewed.phase(of: .urgentLow), .snoozed(until: Fixtures.t0.addingTimeInterval(minutes(30))))
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
