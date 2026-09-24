import XCTest
import GlucoseCore
@testable import AlertEngine

/// Missed readings (S5): pre-scheduled from every valid reading, due at reading + window.
@MainActor
final class MissedReadingsTests: XCTestCase {
    private func slots(from start: Date, every m: Double) -> [Date] {
        (0..<12).map { start.addingTimeInterval(Double($0) * minutes(m)) }
    }

    func test_everyValidReadingReschedulesFromTheReadingsOwnTime() {
        let h = EngineHarness()
        XCTAssertEqual(h.mgdl(120).scheduled(.missedReadings), slots(from: h.now.addingTimeInterval(minutes(15)), every: 15))
        h.clock.advance(minutes: 5)
        XCTAssertEqual(h.mgdl(118).scheduled(.missedReadings), slots(from: h.now.addingTimeInterval(minutes(15)), every: 15))
        h.clock.advance(minutes: 5)
        let late = h.reading(.mgdl(117), secondsAgo: 120)
        XCTAssertEqual(late.scheduled(.missedReadings)?.first, h.now.addingTimeInterval(minutes(13)), "measured 2 minutes ago: due in 13")
    }

    func test_S5_missedReadingsAfter15MinutesWithoutAValidReading() {
        let h = EngineHarness()
        h.mgdl(120)
        XCTAssertEqual(h.advance(minutes: 14).due, [])
        XCTAssertEqual(h.phase(.missedReadings), .armed)
        let due = h.advance(minutes: 1)
        XCTAssertEqual(due.due, [.missedReadings], "the notification was pending; the awake app adds the sound")
        XCTAssertEqual(due.dueNotice(.missedReadings)?.body, "No valid reading since 12:00 PM.")
        XCTAssertEqual(h.phase(.missedReadings), .firing(since: Fixtures.t0.addingTimeInterval(minutes(15))))
    }

    func test_S5_missedReadingsFiresEvenIfNoReadingEverArrived() {
        let h = EngineHarness()
        XCTAssertEqual(h.tick().scheduled(.missedReadings), slots(from: Fixtures.t0.addingTimeInterval(minutes(15)), every: 15))
        let due = h.advance(minutes: 15)
        XCTAssertEqual(due.due, [.missedReadings])
        XCTAssertEqual(due.dueNotice(.missedReadings)?.body, "No valid reading in the last 15 min.")
    }

    func test_postsImmediatelyIfItsNotificationWasNeverScheduled() {
        // e.g. restored from a snapshot that predates scheduling.
        let snapshot = AlertEngineSnapshot(start: Fixtures.t0)   // no pending series recorded
        var engine = AlertEngine(settings: .defaults, configuration: Fixtures.configuration, restoring: snapshot, now: Fixtures.t0)
        let actions = engine.handle(.tick, at: Fixtures.t0.addingTimeInterval(minutes(20)))
        XCTAssertEqual(actions.fired, [.missedReadings])
    }

    func test_repeatsEveryWindowWhileNoReadingArrives() {
        let h = EngineHarness()
        h.mgdl(120)
        h.advance(minutes: 15)
        XCTAssertEqual(h.advance(minutes: 10).due, [])
        let second = h.advance(minutes: 5)
        XCTAssertEqual(second.due, [.missedReadings])
        XCTAssertEqual(h.pendingDates(.missedReadings).first, Fixtures.t0.addingTimeInterval(minutes(45)))
        XCTAssertEqual(h.pendingDates(.missedReadings).count, 12)
        XCTAssertEqual(h.advance(minutes: 1).ignoringMissedReadings.due, [])
    }

    func test_aReadingClearsMissedReadingsAndReschedules() {
        let h = EngineHarness()
        h.mgdl(120)
        h.advance(minutes: 20)
        let back = h.mgdl(118)
        XCTAssertEqual(back.cancelled, [.missedReadings], "removes the delivered and pending notifications")
        XCTAssertEqual(back.scheduled(.missedReadings)?.first, h.now.addingTimeInterval(minutes(15)))
        XCTAssertEqual(h.phase(.missedReadings), .armed)
    }

    func test_aBackfilledReadingAlsoClearsMissedReadings() {
        let h = EngineHarness()
        h.mgdl(120)
        h.advance(minutes: 20)
        let backfill = h.reading(.mgdl(50), secondsAgo: 120, backfill: true)
        XCTAssertEqual(backfill.cancelled, [.missedReadings])
        XCTAssertEqual(backfill.fired, [], "…but never fires a glucose alert (S1)")
    }

    func test_S6_importedReadingDoesNotResetMissedReadings() {
        let h = EngineHarness()
        h.mgdl(120)
        h.advance(minutes: 20)
        XCTAssertEqual(h.reading(.mgdl(120), source: .imported(.nightscout)).rejected, [.notLiveSensor(.imported(.nightscout))])
        XCTAssertEqual(h.phase(.missedReadings), .firing(since: Fixtures.t0.addingTimeInterval(minutes(15))))
    }

    func test_warmUpSuppressesMissedReadingsUntilItEndsAndKeepsThemPendingFromTheEnd() {
        let h = EngineHarness()
        h.tick()
        let end = h.now.addingTimeInterval(minutes(30))
        let warm = h.send(.sensorState(.warmingUp(endsAt: end)))
        XCTAssertEqual(h.pendingDates(.missedReadings).first, end.addingTimeInterval(minutes(15)),
                       "pending from the end of warm-up, so a suspended app still gets them")
        XCTAssertTrue(warm.contains { if case .cancelSlots(.missedReadings, _) = $0 { true } else { false } },
                      "the ones due during warm-up are removed")
        XCTAssertEqual(h.advance(minutes: 29).due, [])
        XCTAssertEqual(h.phase(.missedReadings), .armed)
        let active = h.send(.sensorState(.active(sessionStart: Fixtures.t0, expiresAt: Fixtures.t0.addingTimeInterval(10 * 86_400))))
        XCTAssertEqual(active.scheduled(.missedReadings)?.first, h.now.addingTimeInterval(minutes(15)),
                       "the sensor finished a minute early: the window starts now")
        XCTAssertEqual(h.advance(minutes: 15).due, [.missedReadings])
    }

    func test_S5_missedReadingsFiresAfterWarmUpEndsWithoutReadings() {
        // The phone is out of range when warm-up ends: no further state, no reading, nothing at all.
        let h = EngineHarness()
        let end = h.now.addingTimeInterval(minutes(30))
        h.send(.sensorState(.warmingUp(endsAt: end)))
        XCTAssertEqual(h.pendingDates(.missedReadings).first, end.addingTimeInterval(minutes(15)), "pending during warm-up")
        XCTAssertEqual(h.advance(minutes: 44).due, [])
        XCTAssertEqual(h.advance(minutes: 1).due, [.missedReadings], "due at the end of warm-up + 15 min")
        XCTAssertEqual(h.phase(.missedReadings), .firing(since: end.addingTimeInterval(minutes(15))))
    }

    func test_S5_transientFailureAfterWarmUpIsNotSilent() {
        let transient = SensorFailure.Kind.allCases.filter { !SensorFailure(kind: $0, message: "").raisesSensorAlert }
        XCTAssertEqual(transient.count, 8)
        for kind in transient {
            let h = EngineHarness()
            let end = h.now.addingTimeInterval(minutes(30))
            h.send(.sensorState(.warmingUp(endsAt: end)))
            h.clock.advance(minutes: 30)
            // From the end of warm-up the source reports only this transient failure, every 5 minutes.
            var due: [AlertKind] = []
            for _ in 0..<4 {
                due += h.send(.sensorState(.failed(SensorFailure(kind: kind, message: "transient")))).due
                h.clock.advance(minutes: 5)
            }
            XCTAssertEqual(due, [.missedReadings], "\(kind): missed readings fires at the end of warm-up + 15 min")
            XCTAssertEqual(h.phase(.missedReadings), .firing(since: end.addingTimeInterval(minutes(15))), "\(kind)")
        }
    }

    func test_S5_failureBeforeFirstStateStartsMissedReadings() {
        // Not paired, then the source reports only a transient failure: a pairing exists after all.
        let h = EngineHarness()
        h.send(.sensorState(.notPaired))
        h.clock.advance(minutes: 60)
        let start = h.now
        var due: [AlertKind] = []
        for _ in 0..<5 {
            due += h.send(.sensorState(.failed(SensorFailure(kind: .authenticationFailed, message: "")))).due
            h.clock.advance(minutes: 5)
        }
        XCTAssertEqual(due, [.missedReadings], "repeated failures do not keep restarting the window")
        XCTAssertEqual(h.phase(.missedReadings), .firing(since: start.addingTimeInterval(minutes(15))))
    }

    /// D39: after a confirmed end of the session the sensor alert says so and stays; missed
    /// readings every window on top would only add alarms.
    func test_S5_missedReadingsSuppressedAfterConfirmedEndButSensorAlertStays() {
        let ends: [(SensorState, AlertKind)] = [
            (.expired, .sensorExpired),
            (.failed(SensorFailure(kind: .sensorFailed, message: "failed")), .sensorFailed),
            (.failed(SensorFailure(kind: .sessionStopped, message: "stopped")), .sensorFailed),
            (.failed(SensorFailure(kind: .unsupportedSensor, message: "unsupported")), .sensorFailed),
        ]
        for (state, sensorAlert) in ends {
            let h = EngineHarness()
            h.mgdl(120)
            XCTAssertFalse(h.pendingDates(.missedReadings).isEmpty)
            let end = h.send(.sensorState(state))
            XCTAssertEqual(end.fired, [sensorAlert], "\(state)")
            XCTAssertTrue(end.cancelled.contains(.missedReadings), "\(state): pending missed-readings notifications removed")
            XCTAssertTrue(h.pendingDates(.missedReadings).isEmpty)
            var due: [AlertKind] = []
            var fired: [AlertKind] = []
            for _ in 0..<(3 * 12) {
                let a = h.advance(minutes: 5)
                due += a.due
                fired += a.fired
            }
            XCTAssertEqual(due, [], "\(state): no missed-readings alarms for 3 hours")
            XCTAssertFalse(fired.contains(.missedReadings))
            XCTAssertTrue(fired.contains(sensorAlert), "\(state): the sensor alert keeps re-alerting")
            XCTAssertEqual(h.phase(sensorAlert), .firing(since: Fixtures.t0), "\(state): and stays until a new sensor")
        }
        // Missed readings that was already firing is cleared by the confirmed end, too.
        let h = EngineHarness()
        h.mgdl(120)
        h.advance(minutes: 20)
        XCTAssertEqual(h.phase(.missedReadings), .firing(since: Fixtures.t0.addingTimeInterval(minutes(15))))
        XCTAssertTrue(h.send(.sensorState(.expired)).cancelled.contains(.missedReadings))
        XCTAssertEqual(h.phase(.missedReadings), .armed)
    }

    func test_S5_missedReadingsStillFiresForTransientFailuresAndLostPairing() {
        let kinds = SensorFailure.Kind.allCases.filter { !SensorFailure(kind: $0, message: "").requiresSensorReplacement }
        XCTAssertTrue(kinds.contains(.credentialsUnavailable))
        XCTAssertTrue(kinds.contains(.bondRemoved))
        for kind in kinds {
            let h = EngineHarness()
            h.send(.sensorState(.active(sessionStart: Fixtures.session.start, expiresAt: Fixtures.session.expiresAt)))
            h.mgdl(120)
            var due: [AlertKind] = []
            for _ in 0..<4 {
                h.clock.advance(minutes: 5)
                due += h.send(.sensorState(.failed(SensorFailure(kind: kind, message: "x")))).due
            }
            XCTAssertEqual(due, [.missedReadings], "\(kind): the user is told readings are missing")
        }
    }

    func test_missedReadingsReArmsOnNewSensor() {
        // Expired, then a new sensor warms up: pending again from its warm-up end, and due then + 15.
        let h = EngineHarness()
        h.mgdl(120)
        h.send(.sensorState(.expired))
        h.advance(minutes: 60)
        XCTAssertTrue(h.pendingDates(.missedReadings).isEmpty)
        let end = h.now.addingTimeInterval(minutes(30))
        h.send(.sensorState(.warmingUp(endsAt: end)))
        XCTAssertEqual(h.pendingDates(.missedReadings).first, end.addingTimeInterval(minutes(15)))
        XCTAssertEqual(h.advance(minutes: 44).due, [])
        XCTAssertEqual(h.advance(minutes: 1).due, [.missedReadings])

        // Replace-the-sensor failure, then a new sensor reported straight as active: the window
        // starts at the new state, not at the old sensor's last reading.
        let other = EngineHarness()
        other.mgdl(120)
        other.send(.sensorState(.failed(SensorFailure(kind: .sensorFailed, message: ""))))
        other.clock.advance(minutes: 60)
        let active = other.send(.sensorState(.active(sessionStart: other.now, expiresAt: other.now.addingTimeInterval(10 * 86_400))))
        XCTAssertEqual(active.due, [])
        XCTAssertEqual(other.pendingDates(.missedReadings).first, other.now.addingTimeInterval(minutes(15)))
        XCTAssertEqual(other.advance(minutes: 15).due, [.missedReadings])
    }

    func test_missedReadingsFiresDuringCalibrationStates() {
        for state: SensorState in [.calibrationNeeded(code: 1), .calibrationError(code: 2)] {
            let h = EngineHarness()
            h.mgdl(120)
            h.send(.sensorState(state))
            XCTAssertEqual(h.advance(minutes: 15).due, [.missedReadings], "\(state): readings withheld still count as missed")
        }
    }

    func test_noSensorPairedMeansNothingToMiss() {
        let h = EngineHarness()
        h.send(.sensorState(.notPaired))
        XCTAssertEqual(h.advance(minutes: 60).due, [])
        XCTAssertNil(h.tick().scheduled(.missedReadings))
    }

    func test_transientStatesDoNotChangeSuppression() {
        let h = EngineHarness()
        h.send(.sensorState(.warmingUp(endsAt: h.now.addingTimeInterval(minutes(30)))))
        h.send(.sensorState(.searching))
        h.send(.sensorState(.bluetoothUnavailable(.poweredOff)))
        XCTAssertEqual(h.advance(minutes: 20).due, [], "still warming up as far as missed readings are concerned")
    }

    func test_acknowledgeSnoozesThenRefiresIfStillNoReading() {
        let h = EngineHarness()
        h.mgdl(120)
        h.advance(minutes: 15)
        let ack = h.user(.acknowledge(.missedReadings))
        XCTAssertEqual(ack.first, .cancel(.missedReadings))
        XCTAssertEqual(ack.scheduled(.missedReadings)?.first, h.now.addingTimeInterval(minutes(30)), "pending again for when the snooze ends")
        XCTAssertEqual(h.phase(.missedReadings), .snoozed(until: h.now.addingTimeInterval(minutes(30))))
        XCTAssertEqual(h.advance(minutes: 29).due, [])
        XCTAssertEqual(h.advance(minutes: 1).due, [.missedReadings])
    }

    func test_readingDuringSnoozeEndsTheEpisode() {
        let h = EngineHarness()
        h.mgdl(120)
        h.advance(minutes: 15)
        h.user(.snooze(.missedReadings, minutes: 60))
        h.clock.advance(minutes: 5)
        XCTAssertEqual(h.mgdl(120).cancelled, [.missedReadings])
        XCTAssertEqual(h.phase(.missedReadings), .armed)
    }

    func test_turningMissedReadingsOffRemovesItsNotifications() {
        let h = EngineHarness()
        h.mgdl(120)
        let off = h.settings { $0.missedReadings.isEnabled = false }
        XCTAssertEqual(off, [.cancelSlots(.missedReadings, Array(0..<12))])
        XCTAssertEqual(h.advance(minutes: 30).due, [])
        XCTAssertEqual(h.phase(.missedReadings), .off)
        h.mgdl(120)
        h.advance(minutes: 1)
        let firingOff = EngineHarness()
        firingOff.mgdl(120)
        firingOff.advance(minutes: 20)
        XCTAssertTrue(firingOff.settings { $0.missedReadings.isEnabled = false }.cancelled.contains(.missedReadings))
    }

    func test_changingTheWindowReschedules() {
        let h = EngineHarness()
        h.mgdl(120)
        let change = h.settings { $0.missedReadings.windowMinutes = 30 }
        XCTAssertEqual(change.first, .cancelSlots(.missedReadings, Array(0..<12)))
        XCTAssertEqual(change.scheduled(.missedReadings), slots(from: Fixtures.t0.addingTimeInterval(minutes(30)), every: 30))
    }

    func test_changingSettingsWhileFiringKeepsRepeatsPending() {
        let h = EngineHarness()
        h.mgdl(120)
        h.advance(minutes: 16)
        let change = h.settings { $0.missedReadings.sound = .warble }
        XCTAssertEqual(change.scheduled(.missedReadings)?.first, Fixtures.t0.addingTimeInterval(minutes(30)))
        XCTAssertEqual(change.scheduledNotices(.missedReadings)?.first?.sound, .warble)
    }

    func test_quietHoursAreDecidedForEachPendingNotificationsOwnTime() {
        let h = EngineHarness()
        // Quiet 12:30–13:00 UTC; a reading at 12:01 → pending at 12:16, 12:31, 12:46, 13:01, …
        h.settings { $0.quietHours = QuietHours(isEnabled: true, startMinuteOfDay: 12 * 60 + 30, endMinuteOfDay: 13 * 60) }
        h.clock.advance(minutes: 1)
        let silenced = h.mgdl(120).scheduledNotices(.missedReadings)?.prefix(4).map(\.isSilenced)
        XCTAssertEqual(silenced, [false, true, true, false])
    }
}
