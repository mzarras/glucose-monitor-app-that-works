import GlucoseCore
import XCTest
@testable import WidgetCore

final class WidgetTimelineTests: XCTestCase {
    private func snapshot(_ latest: LatestReading?, state: SensorState = Fixture.activeSensor, recent: [ChartPoint]? = nil) -> WidgetSnapshot {
        WidgetSnapshot(
            writtenAt: Fixture.now,
            latest: latest,
            sensorState: state,
            recent: recent ?? latest.map { [ChartPoint(date: $0.date, value: $0.value)] } ?? [],
            accent: .forest
        )
    }

    private func displays(_ snapshot: WidgetSnapshot?) -> [GlucoseDisplayState] {
        WidgetTimeline.entries(snapshot: snapshot, now: Fixture.now).map(\.display)
    }

    // MARK: fresh / stale / no data

    func test_freshReadingDimsAt10AndDisappearsAt20() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 3)
        let entries = WidgetTimeline.entries(snapshot: snapshot(reading), now: Fixture.now)
        XCTAssertEqual(entries.map(\.date), [Fixture.now, Fixture.minutesAgo(-7), Fixture.minutesAgo(-17)])
        XCTAssertEqual(entries.map(\.display), [.current(reading), .stale(reading), .noData(last: reading)])
    }

    func test_staleSnapshotStartsStale() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 12)
        XCTAssertEqual(displays(snapshot(reading)), [.stale(reading), .noData(last: reading)])
    }

    func test_noDataSnapshot() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 45)
        XCTAssertEqual(displays(snapshot(reading)), [.noData(last: reading)])
        XCTAssertEqual(displays(nil), [.noData(last: nil)], "no snapshot file yet")
    }

    func test_S5_timelineAlwaysEndsWithoutAStaleNumberOnScreen() {
        // Whatever the snapshot, the last entry never shows a number older than 20 minutes.
        for minutes in stride(from: 0.0, through: 60, by: 2.5) {
            let reading = Fixture.latest(.mgdl(105), minutesAgo: minutes)
            let entries = WidgetTimeline.entries(snapshot: snapshot(reading), now: Fixture.now)
            XCTAssertNotNil(entries.last)
            XCTAssertNil(entries.last?.display.displayedReading, "age \(minutes) min: timeline must end in no-data")
            for entry in entries {
                if let shown = entry.display.displayedReading {
                    XCTAssertLessThan(entry.date.timeIntervalSince(shown.date), Freshness.noDataAfter)
                }
                if case .current(let shown) = entry.display {
                    XCTAssertLessThan(entry.date.timeIntervalSince(shown.date), Freshness.staleAfter)
                }
            }
        }
    }

    // MARK: LOW / HIGH

    func test_lowAndHighFlagsAreShownAsFlags() {
        for flag in [GlucoseValue.belowRange, .aboveRange] {
            let reading = Fixture.latest(flag, minutesAgo: 1, trend: .notComputable)
            let entries = WidgetTimeline.entries(snapshot: snapshot(reading), now: Fixture.now)
            XCTAssertEqual(entries.first?.display, .current(reading))
            XCTAssertEqual(entries.first?.display.displayedReading?.value, flag, "S4: the flag itself, not 40/400")
            XCTAssertEqual(entries.map(\.display), [.current(reading), .stale(reading), .noData(last: reading)])
        }
    }

    // MARK: warm-up / expired

    func test_warmUpShowsCountdownThenStopsClaimingWarmUp() {
        let end = Fixture.now.addingTimeInterval(45 * 60)
        let entries = WidgetTimeline.entries(snapshot: snapshot(nil, state: .warmingUp(endsAt: end)), now: Fixture.now)
        XCTAssertEqual(entries.map(\.date), [Fixture.now, end])
        XCTAssertEqual(entries.map(\.display), [.warmingUp(endsAt: end), .noData(last: nil)])
    }

    func test_expiredSensor() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 2)
        XCTAssertEqual(displays(snapshot(reading, state: .expired)), [.sensorExpired(last: reading), .sensorExpired(last: reading), .sensorExpired(last: reading)])
    }

    func test_gracePeriodEndTurnsIntoExpired() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 2)
        let graceEnd = Fixture.now.addingTimeInterval(5 * 60)
        let entries = WidgetTimeline.entries(snapshot: snapshot(reading, state: .gracePeriod(endsAt: graceEnd)), now: Fixture.now)
        XCTAssertEqual(entries.map(\.date), [Fixture.now, graceEnd, Fixture.minutesAgo(-8), Fixture.minutesAgo(-18)])
        XCTAssertEqual(entries.map(\.display), [.current(reading), .sensorExpired(last: reading), .sensorExpired(last: reading), .sensorExpired(last: reading)])
    }

    // MARK: S1

    func test_S1_widgetTimelineNeverSynthesizesAValue() {
        let recent = [
            Fixture.point(.mgdl(120), minutesAgo: 60),
            Fixture.point(.mgdl(110), minutesAgo: 30),
            Fixture.point(.belowRange, minutesAgo: 15),
            Fixture.point(.mgdl(95), minutesAgo: 4),
        ]
        let cases: [(LatestReading?, SensorState)] = [
            (Fixture.latest(.mgdl(95), minutesAgo: 4), Fixture.activeSensor),
            (Fixture.latest(.mgdl(95), minutesAgo: 14), .bluetoothUnavailable(.poweredOff)),
            (Fixture.latest(.belowRange, minutesAgo: 1), Fixture.activeSensor),
            (nil, .warmingUp(endsAt: Fixture.now.addingTimeInterval(600))),
            (Fixture.latest(.mgdl(95), minutesAgo: 4), .gracePeriod(endsAt: Fixture.now.addingTimeInterval(120))),
            (Fixture.latest(.aboveRange, minutesAgo: 9), .expired),
        ]
        for (latest, state) in cases {
            let snap = snapshot(latest, state: state, recent: recent)
            for entry in WidgetTimeline.entries(snapshot: snap, now: Fixture.now) {
                // The only number an entry can show is the snapshot's own latest reading, unchanged.
                if let shown = entry.display.displayedReading {
                    XCTAssertEqual(shown, latest, "\(state): entry at \(entry.date) shows something the app did not write")
                }
                // The chart history is passed through untouched.
                XCTAssertEqual(entry.recent, recent)
                XCTAssertEqual(entry.snapshotWrittenAt, Fixture.now)
            }
        }
    }

    // MARK: Reload policy

    func test_nextReloadFollowsTheLastScheduledChange() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 3)
        let entries = WidgetTimeline.entries(snapshot: snapshot(reading), now: Fixture.now)
        XCTAssertEqual(WidgetTimeline.nextReload(entries: entries, now: Fixture.now), Fixture.minutesAgo(-18))
        let idle = WidgetTimeline.entries(snapshot: nil, now: Fixture.now)
        XCTAssertEqual(WidgetTimeline.nextReload(entries: idle, now: Fixture.now), Fixture.now.addingTimeInterval(15 * 60))
    }

    func test_entriesAreAscendingAndStartNow() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 3)
        let entries = WidgetTimeline.entries(snapshot: snapshot(reading, state: .gracePeriod(endsAt: Fixture.now.addingTimeInterval(8 * 60))), now: Fixture.now)
        XCTAssertEqual(entries.first?.date, Fixture.now)
        XCTAssertEqual(entries.map(\.date), entries.map(\.date).sorted())
        XCTAssertEqual(Set(entries.map(\.date)).count, entries.count, "no duplicate dates")
    }

    func test_widgetStyleRules() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 3)
        XCTAssertEqual(WidgetStyle.numberOpacity(.current(reading)), 1)
        XCTAssertEqual(WidgetStyle.numberOpacity(.stale(reading)), WidgetStyle.staleOpacity)
        XCTAssertLessThan(WidgetStyle.chartOpacity(.noData(last: reading)), 1)
        XCTAssertEqual(WidgetStyle.title(.noData(last: nil)), "No data")
        XCTAssertEqual(WidgetStyle.title(.stale(reading)), "105")
        XCTAssertNil(WidgetStyle.heroStyle(.mgdl(105)), "in range uses ink")
        XCTAssertEqual(WidgetStyle.heroStyle(.belowRange)?.band, .veryLow)
        XCTAssertEqual(WidgetStyle.spokenValue(reading), "105 milligrams per deciliter, steady")
    }
}
