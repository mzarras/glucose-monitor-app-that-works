import GlucoseCore
import XCTest
@testable import WidgetCore

/// D61, owner decision on review m1: once a new sensor is being paired or followed, or a new session
/// is known, the widget never shows an earlier sensor's reading as a number; a relaunch during the
/// new sensor's warm-up keeps showing the warm-up; the same sensor's own last reading stays.
final class WidgetCurrentSensorTests: XCTestCase {
    private let oldSerial = "OLDSENSOR"
    private let newSerial = "NEWSENSOR"
    /// The new session started 20 min ago; its warm-up ends in 7 min.
    private let newStart = Fixture.minutesAgo(20)
    private let warmUpEnd = Fixture.minutesAgo(-7)

    private func snapshot(_ latest: LatestReading?, latestSerial: String?, state: SensorState, current: WidgetCurrentSensor?) -> WidgetSnapshot {
        WidgetSnapshot(writtenAt: Fixture.now, latest: latest, sensorState: state,
                       recent: latest.map { [ChartPoint(date: $0.date, value: $0.value)] } ?? [], accent: .forest,
                       currentSensor: current, latestSensorSerial: latest == nil ? nil : latestSerial)
    }

    private func entries(_ snapshot: WidgetSnapshot, now: Date = Fixture.now) -> [WidgetEntryContent] {
        WidgetTimeline.entries(snapshot: snapshot, now: now, calendar: Fixture.utc)
    }

    private var newSession: WidgetCurrentSensor {
        WidgetCurrentSensor(serial: newSerial, sessionStart: newStart, warmUpEndsAt: warmUpEnd)
    }

    func test_S5_earlierSensorReadingIsHiddenWhilePairingANewSensor() {
        let pairing = WidgetCurrentSensor(serial: nil, sessionStart: nil, warmUpEndsAt: nil)
        for minutes in [2.0, 15, 47, 600] {
            let old = Fixture.latest(.mgdl(105), minutesAgo: minutes)
            for state in [SensorState.searching, .connecting, .authenticating, .bluetoothUnavailable(.poweredOff)] {
                let timeline = entries(snapshot(old, latestSerial: oldSerial, state: state, current: pairing))
                for entry in timeline {
                    XCTAssertNil(entry.widgetReading, "\(minutes) min, \(state): the old sensor's number at \(entry.date)")
                    XCTAssertEqual(entry.display, .noData(last: nil))
                    XCTAssertTrue(entry.hidesEarlierSensorReading, "'No readings from the new sensor yet'")
                    XCTAssertFalse(entry.showsReplayMarker)
                }
            }
            // Forget sensor in pairing mode reports `.notPaired`: its own message.
            XCTAssertEqual(entries(snapshot(old, latestSerial: oldSerial, state: .notPaired, current: pairing)).map(\.display), [.notPaired])
        }
    }

    func test_S5_earlierSensorReadingIsHiddenDuringTheNewSensorsWarmUp() {
        let old = Fixture.latest(.mgdl(105), minutesAgo: 30)
        let timeline = entries(snapshot(old, latestSerial: oldSerial, state: .warmingUp(endsAt: warmUpEnd), current: newSession))
        XCTAssertEqual(timeline.first?.display, .warmingUp(endsAt: warmUpEnd))
        XCTAssertTrue(timeline.allSatisfy { $0.widgetReading == nil }, "never the old sensor's number, before or after the warm-up end")
        XCTAssertEqual(timeline.last?.display, .noData(last: nil), "after warm-up, until the new sensor's first reading")
        // A reading dated before the current session started is an earlier session's, whatever its serial.
        let beforeStart = Fixture.latest(.mgdl(105), minutesAgo: 25)
        let sameSerial = snapshot(beforeStart, latestSerial: newSerial, state: Fixture.activeSensor,
                                  current: WidgetCurrentSensor(serial: newSerial, sessionStart: newStart, warmUpEndsAt: newStart))
        XCTAssertTrue(sameSerial.latestIsFromAnEarlierSensor)
        XCTAssertTrue(entries(sameSerial).allSatisfy { $0.widgetReading == nil })
    }

    /// R2: relaunched during the new sensor's warm-up, the source reports transient states before the
    /// sensor reports warm-up again. The stored session's warm-up end keeps "Warming up" on screen.
    func test_S5_warmUpRelaunchWithTransientStatesKeepsShowingWarmUp() {
        let old = Fixture.latest(.mgdl(105), minutesAgo: 40)
        let transient: [SensorState] = [
            .searching, .connecting, .authenticating, .bluetoothUnavailable(.poweredOff),
            .failed(SensorFailure(kind: .authenticationFailed, message: "m")),
        ]
        for state in transient {
            for latest in [old, nil] {
                let timeline = entries(snapshot(latest, latestSerial: oldSerial, state: state, current: newSession))
                XCTAssertEqual(timeline.map(\.date), [Fixture.now, warmUpEnd], "\(state)")
                XCTAssertEqual(timeline.map(\.display), [.warmingUp(endsAt: warmUpEnd), .noData(last: nil)], "\(state)")
                XCTAssertTrue(timeline.allSatisfy { $0.widgetReading == nil })
            }
        }
        // The sensor's own messages still win (an expired or failed new sensor is not "warming up").
        XCTAssertEqual(entries(snapshot(old, latestSerial: oldSerial, state: .expired, current: newSession)).first?.display, .sensorExpired(last: nil))
    }

    /// R3: the same sensor after a relaunch or a disconnect: its own last reading, as D61 shows it.
    func test_S5_sameSensorRelaunchStillShowsItsLastReading() {
        let own = Fixture.latest(.mgdl(112), minutesAgo: 47)
        let session = WidgetCurrentSensor(serial: oldSerial, sessionStart: Fixture.minutesAgo(5 * 1_440), warmUpEndsAt: Fixture.minutesAgo(5 * 1_440 - 27))
        let ended = WidgetCurrentSensor(serial: oldSerial, sessionStart: nil, warmUpEndsAt: nil) // session over, pairing kept
        for current in [session, ended] {
            for state in [SensorState.searching, .connecting, .authenticating, .bluetoothUnavailable(.poweredOff), Fixture.activeSensor] {
                let first = entries(snapshot(own, latestSerial: oldSerial, state: state, current: current)).first
                XCTAssertEqual(first?.widgetReading, WidgetReading(reading: own, age: .last), "\(state)")
                XCTAssertEqual(first?.readingDay, .sameDay)
                XCTAssertEqual(first?.hidesEarlierSensorReading, false)
            }
        }
        // A fresh reading of the same sensor is current, with its arrow.
        let fresh = Fixture.latest(.mgdl(112), minutesAgo: 2, trend: .singleUp)
        XCTAssertEqual(entries(snapshot(fresh, latestSerial: oldSerial, state: .searching, current: session)).first?.display, .current(fresh))
    }

    /// A snapshot written before the field existed has no `currentSensor`: shown as before.
    func test_S5_snapshotWithoutCurrentSensorIsShownAsBefore() throws {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 47)
        let written = snapshot(reading, latestSerial: oldSerial, state: .searching, current: newSession)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: WidgetSnapshotStore.encoder().encode(written)) as? [String: Any])
        object.removeValue(forKey: "currentSensor")
        object.removeValue(forKey: "latestSensorSerial")
        let old = try WidgetSnapshotStore.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.currentSensor)
        XCTAssertNil(old.latestSensorSerial)
        XCTAssertFalse(old.latestIsFromAnEarlierSensor)
        XCTAssertEqual(old.displaySensorState, .searching)
        XCTAssertEqual(entries(old).first?.widgetReading, WidgetReading(reading: reading, age: .last))
        // And the new fields round-trip.
        XCTAssertEqual(try WidgetSnapshotStore.decode(WidgetSnapshotStore.encoder().encode(written)), written)
    }

    /// Clock mismatch is judged on the reading that may be shown: an earlier sensor's future-dated
    /// reading is hidden, not latched.
    func test_S5_hiddenEarlierSensorReadingIsNotLatched() {
        let ahead = Fixture.latest(.mgdl(105), minutesAgo: -30)
        let snap = snapshot(ahead, latestSerial: oldSerial, state: .searching, current: WidgetCurrentSensor(serial: nil, sessionStart: nil, warmUpEndsAt: nil))
        XCTAssertNil(WidgetTimeline.clockMismatchLatch(snapshot: snap, now: Fixture.now, previous: nil))
        XCTAssertTrue(entries(snap).allSatisfy { $0.display == .noData(last: nil) })
    }

    func test_currentSensorComesFromTheSessionThenTheStoredPairing() {
        let session = SensorSession(serial: newSerial, start: newStart, warmUpEndsAt: warmUpEnd,
                                    expiresAt: Fixture.minutesAgo(-14_400), gracePeriodEndsAt: Fixture.minutesAgo(-15_120))
        XCTAssertEqual(WidgetCurrentSensor.make(session: session, storedPairing: .read(serial: oldSerial)), newSession, "the session wins")
        XCTAssertEqual(WidgetCurrentSensor.make(session: session, storedPairing: .notYetRead), newSession)
        XCTAssertEqual(WidgetCurrentSensor.make(session: nil, storedPairing: .read(serial: oldSerial)),
                       WidgetCurrentSensor(serial: oldSerial, sessionStart: nil, warmUpEndsAt: nil))
        XCTAssertEqual(WidgetCurrentSensor.make(session: nil, storedPairing: .read(serial: nil)),
                       WidgetCurrentSensor(serial: nil, sessionStart: nil, warmUpEndsAt: nil), "a new pairing or a forgotten sensor")
        XCTAssertNil(WidgetCurrentSensor.make(session: nil, storedPairing: .notYetRead), "nothing known: shown as before")
    }

    func test_makeRecordsTheLatestReadingsSerial() {
        let reading = Fixture.reading(.mgdl(105), minutesAgo: 3, serial: oldSerial)
        let snap = WidgetSnapshot.make(latestLive: reading, previousLive: nil, recent: [reading], sensorState: .searching, accent: .forest,
                                       now: Fixture.now, currentSensor: newSession)
        XCTAssertEqual(snap.latestSensorSerial, oldSerial)
        XCTAssertEqual(snap.currentSensor, newSession)
        XCTAssertTrue(snap.latestIsFromAnEarlierSensor)
    }
}
