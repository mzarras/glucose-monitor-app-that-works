import GlucoseCore
import XCTest
@testable import WidgetCore

/// Review m2 (D61): skipping a reload is safe only if the timeline the widget already has shows the
/// same as the one the new snapshot would give. For every pair of snapshots A (the last one a reload
/// was requested for) and B (written later) for which `reloadReason` says "no reload", the timeline
/// built from A when it was written renders the same as the one built from B, at a spread of times
/// from B's write onwards: display state, day label, accent, replay flag and marker, the earlier-
/// sensor flag, and (for a chart anchored at the last reading) the points it draws.
final class WidgetReloadPropertyTests: XCTestCase {
    private struct Rendered: Equatable {
        let display: GlucoseDisplayState
        let day: ReadingDay?
        let accent: AccentChoice
        let isReplay: Bool
        let replayMarker: Bool
        let hidesEarlierSensorReading: Bool
        let anchoredPoints: [ChartPoint]?
    }

    private let t0 = Fixture.now
    private func minutes(_ value: Double) -> TimeInterval { value * 60 }

    private func render(_ snapshot: WidgetSnapshot, at time: Date) -> Rendered? {
        let timeline = WidgetTimeline.entries(snapshot: snapshot, now: snapshot.writtenAt, calendar: Fixture.utc)
        guard let entry = timeline.last(where: { $0.date <= time }) else { return nil }
        let anchored = entry.chartEndsAtReading ? entry.recent.filter { entry.chartDomain.contains($0.date) } : nil
        return Rendered(display: entry.display, day: entry.readingDay, accent: entry.accent, isReplay: entry.isReplay,
                        replayMarker: entry.showsReplayMarker, hidesEarlierSensorReading: entry.hidesEarlierSensorReading,
                        anchoredPoints: anchored)
    }

    private func points(ending end: Date, count: Int) -> [ChartPoint] {
        (0..<count).map { ChartPoint(date: end.addingTimeInterval(-minutes(Double($0) * 5)), value: .mgdl(100 + $0)) }.reversed()
    }

    func test_S5_noReloadOnlyWhenTheWidgetWouldShowTheSame() {
        let latests: [LatestReading?] = [
            nil,
            LatestReading(date: t0 - minutes(2), value: .mgdl(105), trend: .flat, delta: GlucoseDelta(mgdl: 2, minutes: 5)),
            LatestReading(date: t0 - minutes(15), value: .mgdl(105), trend: .singleUp, delta: nil),
            LatestReading(date: t0 - minutes(45), value: .belowRange, trend: .notComputable, delta: nil),
            LatestReading(date: t0 - minutes(60 * 72), value: .mgdl(150), trend: .flat, delta: nil),
            LatestReading(date: t0 + minutes(5), value: .mgdl(99), trend: .flat, delta: nil),
        ]
        let states: [SensorState] = [
            .notPaired, .searching, .connecting, .authenticating, .warmingUp(endsAt: t0 + minutes(25)), .warmingUp(endsAt: t0 - minutes(1)),
            .active(sessionStart: t0 - 86_400, expiresAt: t0 + 86_400), .gracePeriod(endsAt: t0 + minutes(30)), .gracePeriod(endsAt: t0 - minutes(1)),
            .expired, .failed(SensorFailure(kind: .sensorFailed, message: "a")), .failed(SensorFailure(kind: .authenticationFailed, message: "b")),
            .failed(SensorFailure(kind: .other, message: "c")), .error(code: 3, description: "x"), .calibrationNeeded(code: 1),
            .calibrationNeeded(code: 2), .calibrationError(code: 1), .bluetoothUnavailable(.poweredOff),
        ]
        let sensors: [WidgetCurrentSensor?] = [
            nil,
            WidgetCurrentSensor(serial: "A", sessionStart: t0 - 5 * 86_400, warmUpEndsAt: t0 - 5 * 86_400 + minutes(27)),
            WidgetCurrentSensor(serial: "B", sessionStart: t0 - minutes(10), warmUpEndsAt: t0 + minutes(17)),
            WidgetCurrentSensor(serial: nil, sessionStart: nil, warmUpEndsAt: nil),
        ]
        let writeOffsets: [TimeInterval] = [0, 40, minutes(5), minutes(120), minutes(60 * 30)]
        let renderOffsets: [TimeInterval] = [0, minutes(1), minutes(9), minutes(11), minutes(19), minutes(21), minutes(60), 86_400, 3 * 86_400]

        var compared = 0
        var failures = 0
        for latest in latests {
            for sensor in sensors {
                // One bucket per latest reading and current sensor: across buckets the key differs.
                var bucket: [(WidgetSnapshot, WidgetReloadKey)] = []
                for state in states {
                    for offset in writeOffsets {
                        for variant in 0..<3 {
                            let writtenAt = t0 + offset
                            let base: [ChartPoint]
                            switch variant {
                            case 0: base = []
                            case 1: base = points(ending: latest?.date ?? writtenAt, count: 40)
                            default: base = points(ending: writtenAt, count: 40) + points(ending: latest?.date ?? writtenAt, count: 10)
                            }
                            // As `make` selects them: inside the chart windows, not after the write.
                            let windows = WidgetSnapshot.chartWindows(latestLive: latest?.date, now: writtenAt)
                            let recent = Array(Set(base)).filter { point in point.date <= writtenAt && windows.contains { $0.contains(point.date) } }
                                .sorted { $0.date < $1.date }
                            let snapshot = WidgetSnapshot(writtenAt: writtenAt, latest: latest, sensorState: state, recent: recent, accent: .forest,
                                                          currentSensor: sensor, latestSensorSerial: latest == nil ? nil : "A")
                            bucket.append((snapshot, WidgetReloadKey(snapshot, timeZoneID: "UTC", localeID: "en_US")))
                        }
                    }
                }
                for (a, keyA) in bucket {
                    for (b, keyB) in bucket where a.writtenAt <= b.writtenAt && a != b {
                        guard WidgetReloadKey.reloadReason(previous: keyA, current: keyB) == nil else { continue }
                        compared += 1
                        for offset in renderOffsets {
                            let time = b.writtenAt + offset
                            let shownA = render(a, at: time), shownB = render(b, at: time)
                            if shownA != shownB {
                                failures += 1
                                if failures <= 5 {
                                    XCTFail("no reload, but A (\(a.sensorState), written \(a.writtenAt)) and B (\(b.sensorState), written \(b.writtenAt)) "
                                            + "differ at +\(offset / 60) min: \(String(describing: shownA)) vs \(String(describing: shownB))")
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(failures, 0)
        XCTAssertGreaterThan(compared, 10_000, "the property was checked on many skipped reloads")
    }

    /// Negative control: a key with only the latest reading would skip reloads that change the
    /// display (e.g. state churn into "expired"), so the property test above can fail.
    func test_aLatestOnlyKeyWouldMissChanges() {
        let latest = LatestReading(date: t0 - minutes(2), value: .mgdl(105), trend: .flat, delta: nil)
        let a = WidgetSnapshot(writtenAt: t0, latest: latest, sensorState: .searching, recent: [], accent: .forest)
        let b = WidgetSnapshot(writtenAt: t0 + 40, latest: latest, sensorState: .expired, recent: [], accent: .forest)
        XCTAssertNotEqual(render(a, at: b.writtenAt), render(b, at: b.writtenAt))
        XCTAssertEqual(WidgetReloadKey.reloadReason(previous: WidgetReloadKey(a), current: WidgetReloadKey(b)), .sensorState(.expired))
    }
}
