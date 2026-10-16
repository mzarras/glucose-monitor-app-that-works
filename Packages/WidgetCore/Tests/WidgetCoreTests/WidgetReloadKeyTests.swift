import GlucoseCore
import XCTest
@testable import WidgetCore

/// D61: the app asks WidgetKit to reload only when what the widget displays changes.
final class WidgetReloadKeyTests: XCTestCase {
    private let reading = Fixture.latest(.mgdl(105), minutesAgo: 3, trend: .flat, delta: GlucoseDelta(mgdl: -3, minutes: 5))
    private let history = [Fixture.point(.mgdl(110), minutesAgo: 8), Fixture.point(.mgdl(105), minutesAgo: 3)]

    private func snapshot(
        latest: LatestReading?? = nil, state: SensorState = Fixture.activeSensor, recent: [ChartPoint]? = nil,
        accent: AccentChoice = .forest, isReplay: Bool = false, writtenAt: Date = Fixture.now
    ) -> WidgetSnapshot {
        WidgetSnapshot(writtenAt: writtenAt, latest: latest ?? reading, sensorState: state, recent: recent ?? history, accent: accent, isReplay: isReplay)
    }

    private func reason(_ before: WidgetSnapshot, _ after: WidgetSnapshot) -> WidgetReloadReason? {
        WidgetReloadKey.reloadReason(previous: WidgetReloadKey(before, timeZoneID: "UTC", localeID: "en_US"),
                                     current: WidgetReloadKey(after, timeZoneID: "UTC", localeID: "en_US"))
    }

    func test_S5_firstPublishReloads() {
        XCTAssertEqual(WidgetReloadKey.reloadReason(previous: nil, current: WidgetReloadKey(snapshot())), .noEarlierReload)
    }

    /// The churn of one 5-minute wake: searching → connecting → authenticating → active, a
    /// transient failure, Bluetooth off — and each write's newer `writtenAt`. None of it reloads.
    func test_sensorStateChurnAndRewritesDoNotReload() {
        let churn: [SensorState] = [
            .searching, .connecting, .authenticating, Fixture.activeSensor,
            .active(sessionStart: Fixture.now, expiresAt: Fixture.now.addingTimeInterval(86_400)),
            .failed(SensorFailure(kind: .authenticationFailed, message: "Try again")),
            .failed(SensorFailure(kind: .clockMismatch, message: "Clock")),
            .bluetoothUnavailable(.poweredOff), .bluetoothUnavailable(.unauthorized),
        ]
        let base = snapshot()
        for (index, state) in churn.enumerated() {
            let later = snapshot(state: state, writtenAt: Fixture.now.addingTimeInterval(Double(index + 1) * 40))
            XCTAssertNil(reason(base, later), "\(state)")
        }
    }

    func test_S5_newReadingReloads() {
        let newer = Fixture.latest(.mgdl(108), minutesAgo: -2, trend: .flat, delta: GlucoseDelta(mgdl: 3, minutes: 5))
        let after = snapshot(latest: newer, recent: history + [ChartPoint(date: newer.date, value: newer.value)], writtenAt: newer.date)
        XCTAssertEqual(reason(snapshot(), after), .latestReading(newer.date))
        XCTAssertEqual(reason(snapshot(), snapshot(latest: .some(nil))), .latestReading(nil), "the reading is gone (data deleted)")
        // Same date, other trend or delta: also a change (the sensor re-reported it).
        let reTrended = LatestReading(date: reading.date, value: reading.value, trend: .singleUp, delta: reading.delta)
        XCTAssertEqual(reason(snapshot(), snapshot(latest: reTrended)), .latestReading(reading.date))
    }

    func test_S5_sensorMessagesAndScheduledChangesReload() {
        let base = snapshot()
        let expected: [(SensorState, WidgetSensorKey)] = [
            (.expired, .expired),
            (.notPaired, .notPaired),
            (.warmingUp(endsAt: Fixture.now.addingTimeInterval(600)), .warmingUp(endsAt: Fixture.now.addingTimeInterval(600))),
            (.gracePeriod(endsAt: Fixture.now.addingTimeInterval(3_600)), .gracePeriod(endsAt: Fixture.now.addingTimeInterval(3_600))),
            (.error(code: 7, description: "Signal"), .error(code: 7, description: "Signal")),
            (.failed(SensorFailure(kind: .sensorFailed, message: "m")), .failed(SensorFailure(kind: .sensorFailed, message: "m"))),
            (.failed(SensorFailure(kind: .pairingRejected, message: "m")), .failed(SensorFailure(kind: .pairingRejected, message: "m"))),
            (.failed(SensorFailure(kind: .other, message: "m")), .failed(SensorFailure(kind: .other, message: "m"))),
            (.calibrationNeeded(code: 4), .calibrationNeeded),
            (.calibrationError(code: 8), .calibrationRejected),
        ]
        for (state, key) in expected {
            XCTAssertEqual(reason(base, snapshot(state: state)), .sensorState(key), "\(state)")
            XCTAssertEqual(reason(snapshot(state: state), base), .sensorState(.readingsByAge), "back from \(state)")
        }
        // Warm-up ending (warming up → active) and a different warm-up end both reload.
        let warming = snapshot(state: .warmingUp(endsAt: Fixture.now))
        XCTAssertEqual(reason(warming, snapshot(state: .warmingUp(endsAt: Fixture.now.addingTimeInterval(60)))),
                       .sensorState(.warmingUp(endsAt: Fixture.now.addingTimeInterval(60))))
        XCTAssertEqual(reason(warming, base), .sensorState(.readingsByAge))
        // Codes the widget doesn't show don't.
        XCTAssertNil(reason(snapshot(state: .calibrationNeeded(code: 4)), snapshot(state: .calibrationNeeded(code: 5))))
    }

    func test_S5_accentReplayAndChartChangesReload() {
        XCTAssertEqual(reason(snapshot(), snapshot(accent: .rust)), .accent(.rust))
        XCTAssertEqual(reason(snapshot(), snapshot(isReplay: true)), .replay)
        // A history import adds points inside the window: the chart changes.
        let imported = [Fixture.point(.mgdl(100), minutesAgo: 120)] + history
        XCTAssertEqual(reason(snapshot(), snapshot(recent: imported)), .chart)
    }

    /// Points that leave the snapshot's window while no reading arrives were not on any chart the
    /// widget can draw (3 h before the latest reading or later), so they don't reload.
    func test_pointsDroppingOutBelowTheChartFloorDoNotReload() {
        let old = Fixture.latest(.mgdl(105), minutesAgo: 60)
        let before = snapshot(latest: old, recent: [Fixture.point(.mgdl(99), minutesAgo: 245), Fixture.point(.mgdl(100), minutesAgo: 200),
                                                    Fixture.point(.mgdl(105), minutesAgo: 60)])
        let after = snapshot(latest: old, recent: [Fixture.point(.mgdl(100), minutesAgo: 200), Fixture.point(.mgdl(105), minutesAgo: 60)],
                             writtenAt: Fixture.now.addingTimeInterval(300))
        XCTAssertNil(reason(before, after))
        // One inside the window (200 min ago ≥ 60 + 180) does.
        let lost = snapshot(latest: old, recent: [Fixture.point(.mgdl(105), minutesAgo: 60)])
        XCTAssertEqual(reason(before, lost), .chart)
    }

    /// Review N1 support: a reading dated after its snapshot's write time (the clock moved back while
    /// the app ran) reloads, so the widget can latch "Check phone clock".
    func test_S5_clockMovedBackReloads() {
        let movedBack = snapshot(writtenAt: reading.date.addingTimeInterval(-3_600))
        XCTAssertEqual(reason(snapshot(), movedBack), .clockCheck)
        XCTAssertTrue(WidgetReloadKey(movedBack).readingAheadOfSnapshot)
        // Within the 60 s tolerance it is not.
        let withinTolerance = snapshot(writtenAt: reading.date.addingTimeInterval(-30))
        XCTAssertFalse(WidgetReloadKey(withinTolerance).readingAheadOfSnapshot)
        XCTAssertNotEqual(reason(snapshot(), withinTolerance), .clockCheck)
    }

    /// Review n3: with no latest reading the 3-hour window moves with every write; imported points
    /// leaving it are off every chart the installed timeline can still draw, so no reload.
    func test_pointsLeavingTheMovingWindowWithoutAReadingDoNotReload() {
        let imported = [Fixture.point(.mgdl(100), minutesAgo: 178), Fixture.point(.mgdl(102), minutesAgo: 120)]
        let before = snapshot(latest: .some(nil), recent: imported)
        let later = Fixture.now.addingTimeInterval(5 * 60)
        let after = snapshot(latest: .some(nil), recent: [imported[1]], writtenAt: later)
        XCTAssertNil(reason(before, after))
        // A point that is still in the window and disappears (data deleted) does reload.
        XCTAssertEqual(reason(before, snapshot(latest: .some(nil), recent: [imported[0]], writtenAt: later)), .chart)
    }

    /// D61 (review m1): another current sensor, or a latest reading of another sensor, reloads.
    func test_S5_currentSensorChangeReloads() {
        let paired = WidgetCurrentSensor(serial: "A", sessionStart: Fixture.minutesAgo(600), warmUpEndsAt: Fixture.minutesAgo(573))
        let base = WidgetSnapshot(writtenAt: Fixture.now, latest: reading, sensorState: Fixture.activeSensor, recent: history, accent: .forest,
                                  currentSensor: paired, latestSensorSerial: "A")
        func with(_ current: WidgetCurrentSensor?, latestSerial: String? = "A") -> WidgetSnapshot {
            WidgetSnapshot(writtenAt: Fixture.now, latest: reading, sensorState: Fixture.activeSensor, recent: history, accent: .forest,
                           currentSensor: current, latestSensorSerial: latestSerial)
        }
        XCTAssertNil(reason(base, with(paired)))
        XCTAssertEqual(reason(base, with(WidgetCurrentSensor(serial: nil, sessionStart: nil, warmUpEndsAt: nil))), .currentSensor(nil), "pairing a new sensor")
        let next = WidgetCurrentSensor(serial: "B", sessionStart: Fixture.minutesAgo(5), warmUpEndsAt: Fixture.minutesAgo(-22))
        XCTAssertEqual(reason(base, with(next)), .currentSensor("B"), "the new sensor's session")
        XCTAssertEqual(reason(base, with(nil)), .currentSensor(nil), "no longer known")
        XCTAssertEqual(reason(base, with(paired, latestSerial: "B")), .currentSensor("A"))
    }

    /// Review m4: the day labels and midnight entries depend on the phone's time zone and locale.
    func test_S5_timeZoneOrLocaleChangeReloads() {
        let key = WidgetReloadKey(snapshot(), timeZoneID: "America/New_York", localeID: "en_US")
        XCTAssertNil(WidgetReloadKey.reloadReason(previous: key, current: WidgetReloadKey(snapshot(), timeZoneID: "America/New_York", localeID: "en_US")))
        XCTAssertEqual(WidgetReloadKey.reloadReason(previous: key, current: WidgetReloadKey(snapshot(), timeZoneID: "Europe/Paris", localeID: "en_US")),
                       .timeZoneOrLocale)
        XCTAssertEqual(WidgetReloadKey.reloadReason(previous: key, current: WidgetReloadKey(snapshot(), timeZoneID: "America/New_York", localeID: "en_GB")),
                       .timeZoneOrLocale)
    }

    func test_logTextIsOneShortLine() {
        XCTAssertEqual(WidgetReloadReason.latestReading(Fixture.now).logText, "new reading 2026-09-23T12:35:00Z")
        XCTAssertEqual(WidgetReloadReason.sensorState(.expired).logText, "sensor state expired")
        XCTAssertEqual(WidgetReloadReason.sensorState(.failed(SensorFailure(kind: .sensorFailed, message: "m"))).logText, "sensor state failed (sensorFailed)")
        XCTAssertEqual(WidgetReloadReason.accent(.navy).logText, "accent navy")
        XCTAssertEqual(WidgetReloadReason.noEarlierReload.logText, "first publish since launch or foreground")
        XCTAssertEqual(WidgetReloadReason.currentSensor("B").logText, "current sensor B")
        XCTAssertEqual(WidgetReloadReason.timeZoneOrLocale.logText, "time zone or locale changed")
    }
}
