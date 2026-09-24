import XCTest
import GlucoseCore
@testable import AlertEngine

/// The per-alert state machine on glucose alerts: fire, repeat, acknowledge, snooze, snooze
/// expiry, re-fire, clear, delay, supersession — all by advancing the test clock.
@MainActor
final class GlucoseAlertTests: XCTestCase {
    // MARK: Urgent low lifecycle

    func test_urgentLowFiresOnceAndSchedulesTwelveRepeats() {
        let h = EngineHarness()
        let actions = h.mgdl(52)
        XCTAssertEqual(actions.fired, [.urgentLow])
        XCTAssertEqual(actions.scheduled(.urgentLow), (1...12).map { h.now.addingTimeInterval(Double($0) * minutes(5)) })
        XCTAssertEqual(h.phase(.urgentLow), .firing(since: h.now))
        XCTAssertEqual(h.engine.activeAlerts, [.urgentLow])

        h.clock.advance(minutes: 1)
        XCTAssertEqual(h.mgdl(51).ignoringMissedReadings, [], "still low a minute later: nothing new")
    }

    func test_urgentLowRepeatsEveryFiveMinutesUntilAcknowledged() {
        let h = EngineHarness()
        let start = h.now
        h.mgdl(52)
        h.clock.advance(minutes: 3.5)
        XCTAssertEqual(h.mgdl(50).due, [])
        h.clock.advance(minutes: 1.5)
        let repeat1 = h.mgdl(49)
        XCTAssertEqual(repeat1.due, [.urgentLow], "the 5-minute repeat plays the in-app sound")
        XCTAssertEqual(repeat1.scheduled(.urgentLow), [start.addingTimeInterval(minutes(65))], "only the tail is added; nothing else is touched")
        XCTAssertEqual(h.pendingDates(.urgentLow).first, start.addingTimeInterval(minutes(10)), "pending repeats roll forward")
        XCTAssertEqual(repeat1.dueNotice(.urgentLow)?.body, "Not acknowledged. Last reading 49 mg/dL at 12:05 PM.")
        h.clock.advance(minutes: 5)
        XCTAssertEqual(h.mgdl(49).due, [.urgentLow])

        let ack = h.user(.acknowledge(.urgentLow))
        XCTAssertEqual(ack, [.cancel(.urgentLow)], "acknowledge removes notifications, pending repeats and the sound")
        XCTAssertEqual(h.phase(.urgentLow), .snoozed(until: h.now.addingTimeInterval(minutes(30))))
        h.clock.advance(minutes: 5)
        XCTAssertEqual(h.mgdl(48).ignoringMissedReadings, [], "acknowledged: no more repeats")
    }

    func test_unacknowledgedUrgentLowKeepsRepeatingWhenReadingsStop() {
        let h = EngineHarness()
        h.mgdl(52)
        XCTAssertEqual(h.advance(minutes: 5).due, [.urgentLow])
        XCTAssertNil(h.engine.currentReading(at: h.now.addingTimeInterval(minutes(2))), "value is stale from here on")
        XCTAssertEqual(h.advance(minutes: 5).due, [.urgentLow], "raised on a real reading and never acknowledged")
        XCTAssertEqual(h.advance(minutes: 3).due, [])
        XCTAssertEqual(h.advance(minutes: 2).due.first, .urgentLow)
    }

    func test_repeatCatchesUpToTheLatestSlotAfterALongSleep() {
        let h = EngineHarness()
        let start = h.now
        h.mgdl(52)
        let late = h.advance(minutes: 17)
        XCTAssertEqual(late.due.filter { $0 == .urgentLow }, [.urgentLow], "one sound, not three")
        XCTAssertEqual(h.pendingDates(.urgentLow).first, start.addingTimeInterval(minutes(20)))
        XCTAssertEqual(h.pendingDates(.urgentLow).last, start.addingTimeInterval(minutes(75)), "60 minutes ahead again")
    }

    func test_acknowledgedUrgentLowFiresAgainAfterItsSnoozeIfStillLow() {
        let h = EngineHarness()
        h.mgdl(52)
        h.user(.acknowledge(.urgentLow))
        h.clock.advance(minutes: 29)
        XCTAssertEqual(h.mgdl(50).fired, [])
        h.clock.advance(minutes: 1)
        let refire = h.mgdl(50)
        XCTAssertEqual(refire.fired, [.urgentLow])
        XCTAssertNotNil(refire.scheduled(.urgentLow), "a new sounding schedules new repeats")
    }

    func test_S1_snoozeExpiryNeverRefiresOnAStaleValue() {
        let h = EngineHarness()
        h.mgdl(52)
        h.user(.acknowledge(.urgentLow))
        let expired = h.advance(minutes: 31)
        XCTAssertEqual(expired.fired, [], "the 52 is 31 minutes old: not evaluated")
        XCTAssertEqual(h.phase(.urgentLow), .snoozed(until: Fixtures.t0.addingTimeInterval(minutes(30))))
        XCTAssertEqual(h.phase(.missedReadings), .firing(since: Fixtures.t0.addingTimeInterval(minutes(15))), "S5 covers the gap")
        XCTAssertEqual(h.mgdl(50).fired, [.urgentLow], "a fresh low reading fires at once")
    }

    func test_hysteresisBandHoldsAndRecoveryClears() {
        let h = EngineHarness()
        h.mgdl(52)
        h.clock.advance(minutes: 5)
        let band = h.mgdl(58)
        XCTAssertEqual(band.cancelled, [], "58 is inside threshold + 5: not recovered")
        XCTAssertEqual(band.due, [.urgentLow], "and still unacknowledged, so it repeats")
        h.clock.advance(minutes: 5)
        let recovered = h.mgdl(61)
        XCTAssertEqual(recovered.cancelled, [.urgentLow], "cleared: notifications and repeats removed")
        XCTAssertEqual(recovered.fired, [.low], "61 is still low: low takes over")
        XCTAssertEqual(h.phase(.urgentLow), .armed)
        h.clock.advance(minutes: 5)
        let again = h.mgdl(50)
        XCTAssertEqual(again.fired, [.urgentLow], "re-armed: a new episode fires")
        XCTAssertEqual(again.cancelled, [.low], "urgent low supersedes low")
    }

    func test_valuesHoveringAtTheThresholdDoNotFlap() {
        let h = EngineHarness()
        var fires = 0
        for value in [55, 56, 55, 57, 55, 58, 54] {
            fires += h.mgdl(value).fired.filter { $0 == .urgentLow }.count
            h.clock.advance(minutes: 1)
        }
        XCTAssertEqual(fires, 1)
    }

    func test_thresholdIsConfigurable() {
        let h = EngineHarness()
        h.settings { $0.urgentLow.thresholdMgdl = 60 }
        XCTAssertEqual(h.mgdl(60).fired, [.urgentLow])
    }

    func test_repeatIntervalIsConfigurableAndChangingItReschedules() {
        let h = EngineHarness()
        h.mgdl(52)
        let change = h.settings { $0.urgentLow.repeatMinutes = 2 }
        XCTAssertEqual(change.scheduled(.urgentLow)?.first, h.now.addingTimeInterval(minutes(2)))
        XCTAssertEqual(h.advance(minutes: 2).due, [.urgentLow])
    }

    // MARK: Low / high

    func test_lowReAlertsAtItsSnoozeIntervalWhileStillLow() {
        let h = EngineHarness()
        XCTAssertEqual(h.mgdl(65).fired, [.low])
        for _ in 1...5 {
            h.clock.advance(minutes: 5)
            XCTAssertEqual(h.mgdl(65).fired, [])
        }
        h.clock.advance(minutes: 5)
        XCTAssertEqual(h.mgdl(64).fired, [.low], "30 minutes later, still low: again")
    }

    func test_snoozedLowStaysQuietThenRefires() {
        let h = EngineHarness()
        h.mgdl(65)
        XCTAssertEqual(h.user(.snooze(.low, minutes: 60)), [.cancel(.low)])
        h.clock.advance(minutes: 55)
        XCTAssertEqual(h.mgdl(66).fired, [])
        h.clock.advance(minutes: 5)
        XCTAssertEqual(h.mgdl(66).fired, [.low])
    }

    func test_recoveryDuringSnoozeEndsTheEpisode() {
        let h = EngineHarness()
        h.mgdl(65)
        h.user(.snooze(.low, minutes: 120))
        h.clock.advance(minutes: 10)
        XCTAssertEqual(h.mgdl(90).cancelled, [.low])
        XCTAssertEqual(h.phase(.low), .armed)
        h.clock.advance(minutes: 10)
        XCTAssertEqual(h.mgdl(66).fired, [.low], "a new episode is not covered by the old snooze")
    }

    func test_highDelayFiresOnlyAfterNMinutesAbove() {
        let h = EngineHarness()
        h.settings { $0.high.delayMinutes = 30 }
        let start = h.now
        XCTAssertEqual(h.mgdl(260).fired, [])
        XCTAssertEqual(h.phase(.high), .pending(firesAt: start.addingTimeInterval(minutes(30))))
        for _ in 1...5 {
            h.clock.advance(minutes: 5)
            XCTAssertEqual(h.mgdl(270).fired, [])
        }
        h.clock.advance(minutes: 5)
        XCTAssertEqual(h.mgdl(265).fired, [.high])
    }

    func test_highDelayRestartsAfterRecovery() {
        let h = EngineHarness()
        h.settings { $0.high.delayMinutes = 30 }
        h.mgdl(260)
        h.clock.advance(minutes: 10)
        h.mgdl(240)
        XCTAssertEqual(h.phase(.high), .armed)
        h.clock.advance(minutes: 5)
        h.mgdl(260)
        h.clock.advance(minutes: 25)
        XCTAssertEqual(h.mgdl(260).fired, [], "only 25 minutes since it went back above")
        h.clock.advance(minutes: 5)
        XCTAssertEqual(h.mgdl(260).fired, [.high])
    }

    func test_turningAnAlertOffCancelsIt() {
        let h = EngineHarness()
        h.mgdl(65)
        let off = h.settings { $0.low.isEnabled = false }
        XCTAssertEqual(off.cancelled, [.low])
        XCTAssertEqual(h.phase(.low), .off)
        h.clock.advance(minutes: 40)
        XCTAssertEqual(h.mgdl(62).fired, [])
    }

    func test_rateAlerts() {
        let h = EngineHarness()
        h.settings {
            $0.fallingFast.isEnabled = true
            $0.risingFast.isEnabled = true
        }
        let falling = h.mgdl(150, rate: -3.5)
        XCTAssertEqual(falling.fired, [.fallingFast])
        XCTAssertEqual(falling.firedNotice(.fallingFast)?.body, "Falling 3.5 mg/dL/min. 150 mg/dL at 12:00 PM.")
        h.clock.advance(minutes: 5)
        let rising = h.mgdl(150, rate: 3.5)
        XCTAssertEqual(rising.cancelled, [.fallingFast])
        XCTAssertEqual(rising.fired, [.risingFast])
    }

    // MARK: S4

    func test_S4_lowFlagFiresUrgentLowWithoutBecomingANumber() {
        let h = EngineHarness()
        let actions = h.reading(.belowRange)
        XCTAssertEqual(actions.fired, [.urgentLow], "LOW counts as at or below every low threshold; low itself is superseded")
        let body = actions.firedNotice(.urgentLow)?.body ?? ""
        XCTAssertTrue(body.contains("LOW"), body)
        XCTAssertFalse(body.contains("40"), body)
    }

    func test_S4_highFlagFiresHighWithoutBecomingANumber() {
        let h = EngineHarness()
        h.settings { $0.high.thresholdMgdl = 400 }
        let actions = h.reading(.aboveRange)
        XCTAssertEqual(actions.fired, [.high], "HIGH counts as at or above even the top threshold")
        let body = actions.firedNotice(.high)?.body ?? ""
        XCTAssertTrue(body.contains("HIGH"), body)
        XCTAssertFalse(body.contains("400"), body)
    }

    // MARK: S1

    func test_S1_staleBackfillDoesNotFireGlucoseAlert() {
        let h = EngineHarness()
        h.mgdl(120)
        let old = Fixtures.reading(.mgdl(50), at: h.now.addingTimeInterval(-minutes(10)), backfill: true)
        let actions = h.send(.reading(old, session: h.session))
        XCTAssertEqual(actions.rejected, [], "a valid reading, accepted")
        XCTAssertEqual(actions.fired, [])
        XCTAssertEqual(h.phase(.urgentLow), .armed)
        // Stronger: a backfilled reading never drives glucose alerts, even if newer than the last live one.
        h.clock.advance(minutes: 5)
        let newer = Fixtures.reading(.mgdl(50), at: h.now, backfill: true)
        XCTAssertEqual(h.send(.reading(newer, session: h.session)).fired, [])
    }

    func test_S1_backfillNeverClearsAFiringUrgentLow() {
        // The G7 sequence Loop saw: live reading raises urgent low, backfill of the gap retracts it
        // a second later (LoopKit/Loop #2520).
        let h = EngineHarness()
        h.mgdl(50)
        h.clock.advance(seconds: 1)
        let backfill = Fixtures.reading(.mgdl(150), at: h.now.addingTimeInterval(-minutes(4)), backfill: true)
        XCTAssertEqual(h.send(.reading(backfill, session: h.session)).cancelled, [])
        XCTAssertEqual(h.phase(.urgentLow), .firing(since: Fixtures.t0))
    }

    func test_S1_olderLiveReadingIsIgnored() {
        let h = EngineHarness()
        h.mgdl(120)
        let outOfOrder = Fixtures.reading(.mgdl(50), at: h.now.addingTimeInterval(-minutes(3)))
        XCTAssertEqual(h.send(.reading(outOfOrder, session: h.session)).fired, [])
    }

    func test_S1_aValueIsNeverCarriedForward() {
        let h = EngineHarness()
        h.settings { $0.low.isEnabled = false }
        h.mgdl(65)
        h.advance(minutes: 7)
        XCTAssertNil(h.engine.currentReading(at: h.now))
        XCTAssertEqual(h.settings { $0.low.isEnabled = true }.fired, [], "a 7-minute-old 65 is not a current low")
        h.clock.advance(minutes: 1)
        XCTAssertEqual(h.mgdl(65).fired, [.low])
    }

    func test_S1_urgentLowSoonUsesOnlyTheReportedRate() {
        func harness() -> EngineHarness {
            let h = EngineHarness()
            h.settings { $0.urgentLowSoon.isEnabled = true }
            return h
        }
        let fires = harness().mgdl(80, rate: -1.5)
        XCTAssertEqual(fires.fired, [.urgentLowSoon], "80 − 1.5 × 20 = 50 ≤ 55")
        let body = fires.firedNotice(.urgentLowSoon)?.body ?? ""
        XCTAssertEqual(body, "80 mg/dL at 12:00 PM, falling 1.5 mg/dL/min. At that rate it reaches 55 mg/dL within 20 min.")
        XCTAssertFalse(body.contains("50 mg/dL"), "the projection is never shown as a value")
        XCTAssertEqual(harness().mgdl(80, rate: nil).fired, [], "no reported rate: no projection")
        XCTAssertEqual(harness().mgdl(80, rate: -0.5).fired, [], "80 − 10 = 70: not soon")
    }

    func test_S1_urgentLowSoonHoldsWhenTheRateDisappears() {
        let h = EngineHarness()
        h.settings { $0.urgentLowSoon.isEnabled = true }
        h.mgdl(80, rate: -1.5)
        h.clock.advance(minutes: 5)
        let noRate = h.mgdl(72, rate: nil)
        XCTAssertEqual(noRate.cancelled, [], "unknown is not recovered")
        XCTAssertEqual(noRate.fired, [])
        XCTAssertEqual(h.phase(.urgentLowSoon), .firing(since: Fixtures.t0))
    }

    func test_urgentLowSoonGivesWayToUrgentLow() {
        let h = EngineHarness()
        h.settings { $0.urgentLowSoon.isEnabled = true }
        h.mgdl(70, rate: -1)
        h.clock.advance(minutes: 5)
        let urgent = h.mgdl(54, rate: -1)
        XCTAssertEqual(urgent.fired, [.urgentLow])
        XCTAssertTrue(urgent.cancelled.contains(.urgentLowSoon))
    }

    // MARK: S6 / S2 (the gate)

    func test_S6_importedReadingNeverFiresAnAlert() {
        let h = EngineHarness()
        for origin in ImportOrigin.allCases {
            let actions = h.reading(.mgdl(45), source: .imported(origin))
            XCTAssertEqual(actions, [.readingRejected(readingID: Fixtures.reading(.mgdl(45), at: h.now).id, reason: .notLiveSensor(.imported(origin)))])
        }
        XCTAssertEqual(h.engine.activeAlerts, [])
        XCTAssertNil(h.engine.snapshot.latestLiveReading)
    }

    func test_S6_mockReadingNeverFiresAnAlert() {
        let h = EngineHarness()
        XCTAssertEqual(h.reading(.mgdl(45), source: .mock).rejected, [.notLiveSensor(.mock)])
        XCTAssertEqual(h.engine.activeAlerts, [])
    }

    func test_S6_nonSensorReadingsNeverClearAnAlert() {
        let h = EngineHarness()
        h.mgdl(50)
        h.clock.advance(minutes: 1)
        for source: ReadingSource in [.imported(.nightscout), .imported(.clarityCSV), .mock, .replay] {
            XCTAssertEqual(h.reading(.mgdl(150), source: source).cancelled, [])
        }
        XCTAssertEqual(h.phase(.urgentLow), .firing(since: Fixtures.t0))
    }

    #if DEBUG
    func test_S6_replayRefusedUnlessReplayModeIsOn() {
        let h = EngineHarness()
        XCTAssertEqual(h.reading(.mgdl(45), source: .replay).rejected, [.notLiveSensor(.replay)])
        XCTAssertEqual(h.engine.activeAlerts, [])
    }

    func test_S6_replayAcceptedInDebugOnlyWithReplayModeOn() {
        var configuration = Fixtures.configuration
        configuration.acceptsReplayReadings = true
        let h = EngineHarness(configuration: configuration)
        XCTAssertEqual(h.reading(.mgdl(45), source: .replay).fired, [.urgentLow])
        XCTAssertEqual(h.reading(.mgdl(150), source: .imported(.nightscout)).rejected, [.notLiveSensor(.imported(.nightscout))])
        XCTAssertEqual(h.reading(.mgdl(150), source: .mock).rejected, [.notLiveSensor(.mock)])
    }
    #else
    func test_S6_releaseBuildRefusesReplayReadings() {
        let h = EngineHarness()
        XCTAssertEqual(h.reading(.mgdl(45), source: .replay).rejected, [.notLiveSensor(.replay)])
    }
    #endif

    func test_S2_implausibleReadingsNeitherFireNorClear() {
        let h = EngineHarness()
        h.mgdl(50)
        h.clock.advance(minutes: 1)
        let reference = h.engine.snapshot.missedReadingsReference
        let now = h.now
        let malformed = SensorSession(serial: "", start: now, warmUpEndsAt: now, expiresAt: now, gracePeriodEndsAt: now)
        let refused: [(GlucoseReading, SensorSession?, LiveReadingGate.Rejection)] = [
            (Fixtures.reading(.mgdl(0), at: now), Fixtures.session, .implausibleValue(0)),
            (Fixtures.reading(.mgdl(39), at: now), Fixtures.session, .implausibleValue(39)),
            (Fixtures.reading(.mgdl(401), at: now), Fixtures.session, .implausibleValue(401)),
            (Fixtures.reading(.mgdl(150), at: now, rate: .nan), Fixtures.session, .nonFiniteTrendRate),
            (Fixtures.reading(.mgdl(150), at: now, rate: .infinity), Fixtures.session, .nonFiniteTrendRate),
            (Fixtures.reading(.mgdl(150), at: now), malformed, .malformedSession),
            (Fixtures.reading(.mgdl(150), at: now), nil, .noSession),
            (Fixtures.reading(.mgdl(150), at: now, serial: "OTHER"), Fixtures.session,
             .serialMismatch(readingSerial: "OTHER", sessionSerial: Fixtures.serial)),
            (Fixtures.reading(.mgdl(150), at: now.addingTimeInterval(minutes(5))), Fixtures.session, .inFuture),
        ]
        for (reading, session, reason) in refused {
            let actions = h.send(.reading(reading, session: session))
            XCTAssertEqual(actions, [.readingRejected(readingID: reading.id, reason: reason)], "\(reason)")
        }
        XCTAssertEqual(h.phase(.urgentLow), .firing(since: Fixtures.t0), "nothing cleared")
        XCTAssertEqual(h.engine.snapshot.missedReadingsReference, reference, "the missed-readings clock did not move")
        XCTAssertEqual(h.engine.snapshot.latestLiveReading?.value, .mgdl(50))
    }

    // MARK: S7

    func test_S7_urgentLowCannotBeSnoozedBeforeItFires() {
        let h = EngineHarness()
        XCTAssertEqual(h.user(.snooze(.urgentLow, minutes: 30)).first, .userActionIgnored(.snooze(.urgentLow, minutes: 30)))
        XCTAssertEqual(h.user(.acknowledge(.urgentLow)).first, .userActionIgnored(.acknowledge(.urgentLow)))
        XCTAssertEqual(h.mgdl(50).fired, [.urgentLow])
    }

    func test_S7_snoozeLongerThan30MinutesIsClampedTo30() {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.snooze(.urgentLow, minutes: 240))
        XCTAssertEqual(h.phase(.urgentLow), .snoozed(until: h.now.addingTimeInterval(minutes(30))))
        h.clock.advance(minutes: 29)
        XCTAssertEqual(h.mgdl(50).fired, [])
        h.clock.advance(minutes: 1)
        XCTAssertEqual(h.mgdl(50).fired, [.urgentLow])
    }

    func test_S7_resnoozingCannotExtendPast30MinutesFromNow() {
        let h = EngineHarness()
        h.mgdl(50)
        h.user(.snooze(.urgentLow, minutes: 30))
        h.clock.advance(minutes: 10)
        h.user(.snooze(.urgentLow, minutes: 1000))
        XCTAssertEqual(h.phase(.urgentLow), .snoozed(until: h.now.addingTimeInterval(minutes(30))))
    }

    func test_S7_urgentLowSoundsDuringQuietHours() {
        let h = EngineHarness()
        // Quiet hours 11:00–13:00 UTC; t0 is 12:00 UTC.
        h.settings { $0.quietHours = QuietHours(isEnabled: true, startMinuteOfDay: 11 * 60, endMinuteOfDay: 13 * 60) }
        let urgent = h.mgdl(50)
        let notice = urgent.firedNotice(.urgentLow)
        XCTAssertEqual(notice?.isSilenced, false)
        XCTAssertEqual(notice?.soundsOnSilent, true)
        XCTAssertEqual(urgent.scheduledNotices(.urgentLow)?.allSatisfy { !$0.isSilenced }, true)

        let other = EngineHarness()
        other.settings { $0.quietHours = QuietHours(isEnabled: true, startMinuteOfDay: 11 * 60, endMinuteOfDay: 13 * 60) }
        XCTAssertEqual(other.mgdl(65).firedNotice(.low)?.isSilenced, true, "quiet hours silence everything else")
    }

    func test_S7_urgentLowFiresWithStoredSettingsThatTryToDisableIt() throws {
        let stored = Data(#"{"urgentLow": {"isEnabled": false, "snoozeMinutes": 600}, "low": {"isEnabled": false}}"#.utf8)
        let h = EngineHarness(settings: AlertSettings.decodeOrDefault(stored))
        XCTAssertEqual(h.mgdl(50).fired, [.urgentLow])
        h.user(.acknowledge(.urgentLow))
        XCTAssertEqual(h.phase(.urgentLow), .snoozed(until: h.now.addingTimeInterval(minutes(30))))
    }

    func test_S7_urgentLowFiresWithEveryOtherAlertOff() {
        var settings = AlertSettings.defaults
        for kind in AlertKind.allCases { settings.setEnabled(false, for: kind) }
        let h = EngineHarness(settings: settings)
        XCTAssertEqual(h.mgdl(50).fired, [.urgentLow])
        XCTAssertEqual(h.phase(.urgentLow), .firing(since: h.now))
    }
}
