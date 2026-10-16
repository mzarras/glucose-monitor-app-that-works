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

    /// Entries with the UTC calendar, so local midnights are 00:00 UTC (`Fixture.nextMidnight`).
    private func entries(_ snapshot: WidgetSnapshot?, now: Date = Fixture.now, latchedFor: Date? = nil) -> [WidgetEntryContent] {
        WidgetTimeline.entries(snapshot: snapshot, now: now, latchedFor: latchedFor, calendar: Fixture.utc)
    }

    private func displays(_ snapshot: WidgetSnapshot?) -> [GlucoseDisplayState] {
        entries(snapshot).map(\.display)
    }

    private let secondMidnight = Fixture.nextMidnight.addingTimeInterval(86_400)

    // MARK: fresh / stale / last reading / no data

    /// D61 (changed): at 20 min the entry is a last reading (`.noData(last:)` shown muted with its
    /// time), and two more entries at the next local midnights keep its day label right.
    func test_freshReadingDimsAt10AndBecomesALastReadingAt20() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 3)
        let timeline = entries(snapshot(reading))
        XCTAssertEqual(timeline.map(\.date), [Fixture.now, Fixture.minutesAgo(-7), Fixture.minutesAgo(-17), Fixture.nextMidnight, secondMidnight])
        XCTAssertEqual(timeline.map(\.display), [.current(reading), .stale(reading), .noData(last: reading), .noData(last: reading), .noData(last: reading)])
        XCTAssertEqual(timeline.map(\.widgetReading?.age), [.current, .stale, .last, .last, .last])
        XCTAssertEqual(timeline.map(\.readingDay), [nil, nil, .sameDay, .yesterday, .earlier])
        XCTAssertEqual(timeline.map(\.isDayChangeOnly), [false, false, false, true, true])
    }

    func test_staleSnapshotStartsStale() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 12)
        XCTAssertEqual(displays(snapshot(reading)), [.stale(reading), .noData(last: reading), .noData(last: reading), .noData(last: reading)])
    }

    /// D61 (changed): a reading 45 min old is shown as the last reading, not as "No data".
    func test_oldSnapshotShowsTheLastReading() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 45)
        let timeline = entries(snapshot(reading))
        XCTAssertEqual(timeline.map(\.display), [.noData(last: reading), .noData(last: reading), .noData(last: reading)])
        XCTAssertEqual(timeline.first?.widgetReading, WidgetReading(reading: reading, age: .last))
        XCTAssertEqual(timeline.first?.readingDay, .sameDay)
    }

    func test_noSnapshotOrNoReadingIsNoDataWithoutANumber() {
        XCTAssertEqual(displays(nil), [.noData(last: nil)], "no snapshot file yet")
        XCTAssertNil(entries(nil).first?.widgetReading)
        let none = entries(snapshot(nil))
        XCTAssertEqual(none.map(\.display), [.noData(last: nil)], "a snapshot without any reading")
        XCTAssertNil(none.first?.widgetReading)
        XCTAssertNil(none.first?.readingDay)
    }

    /// D61. Every entry whose reading is 10 min old or older shows it only muted, without trend arrow
    /// or delta, with its STALE label (10–20 min) or its time and day (≥ 20 min, however old); an
    /// entry never shows a reading that old with the current styling. The number is always the
    /// snapshot's own reading (S1).
    func test_S5_oldReadingIsShownOnlyMutedWithItsAgeAndNeverAsCurrent() {
        let ages = Array(stride(from: 0.0, through: 60, by: 2.5)) + [90, 600, 1_439, 1_500, 3_000, 20_000]
        for minutes in ages {
            let reading = Fixture.latest(.mgdl(105), minutesAgo: minutes, trend: .singleUp, delta: GlucoseDelta(mgdl: 4, minutes: 5))
            let timeline = entries(snapshot(reading))
            XCTAssertEqual(timeline.last?.widgetReading?.age, .last, "age \(minutes) min: the timeline ends on the last reading")
            for entry in timeline {
                let age = entry.date.timeIntervalSince(reading.date)
                guard let shown = entry.widgetReading else {
                    XCTFail("age \(minutes) min, entry \(entry.date): an active sensor's reading is always shown")
                    continue
                }
                XCTAssertEqual(shown.reading, reading, "S1: only the snapshot's own reading")
                if age < Freshness.staleAfter {
                    XCTAssertEqual(shown.age, .current)
                    XCTAssertFalse(shown.isMuted)
                    XCTAssertEqual(shown.trend, .singleUp)
                    XCTAssertEqual(shown.delta, GlucoseDelta(mgdl: 4, minutes: 5))
                    XCTAssertEqual(WidgetStyle.chartOpacity(entry.display), 1)
                    continue
                }
                XCTAssertTrue(shown.isMuted, "age \(age / 60) min: muted")
                XCTAssertNil(shown.trend, "age \(age / 60) min: no arrow")
                XCTAssertNil(shown.delta, "age \(age / 60) min: no delta")
                XCTAssertNil(WidgetStyle.chartLatest(entry.display), "no 'latest' dot")
                XCTAssertEqual(WidgetStyle.chartOpacity(entry.display), Emphasis.dimmedChartOpacity)
                if age < Freshness.noDataAfter {
                    XCTAssertEqual(shown.age, .stale)
                    XCTAssertTrue(WidgetStyle.isStale(entry.display), "STALE label")
                    XCTAssertNil(entry.readingDay)
                } else {
                    XCTAssertEqual(shown.age, .last, "age \(age / 60) min: never current or stale")
                    XCTAssertNotNil(entry.readingDay, "age \(age / 60) min: labelled with its time")
                    XCTAssertEqual(entry.chartEnd, reading.date)
                }
            }
        }
    }

    // MARK: Day label (D61)

    func test_lastReadingDayLabelFollowsLocalMidnight() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-09-22 23:02 EDT = 2026-09-23 03:02 UTC (EDT is UTC−4) = 1_790_132_520.
        let reading = LatestReading(date: Date(timeIntervalSince1970: 1_790_132_520), value: .mgdl(112), trend: .flat, delta: nil)
        // Fixture.now, 2026-09-23 12:35 UTC, is 08:35 EDT: the next morning in New York.
        let morning = Fixture.now
        let snap = WidgetSnapshot(writtenAt: reading.date, latest: reading, sensorState: Fixture.activeSensor, recent: [], accent: .forest)
        let timeline = WidgetTimeline.entries(snapshot: snap, now: morning, calendar: newYork)
        // The first midnight (2026-09-23 00:00 EDT) is past; the second, 2026-09-24 00:00 EDT =
        // 04:00 UTC = 1_790_222_400, turns "Yesterday" into a date.
        XCTAssertEqual(timeline.map(\.date), [morning, Date(timeIntervalSince1970: 1_790_222_400)])
        XCTAssertEqual(timeline.map(\.readingDay), [.yesterday, .earlier])
        // In UTC the same reading was taken today.
        XCTAssertEqual(WidgetTimeline.entries(snapshot: snap, now: morning, calendar: Fixture.utc).first?.readingDay, .sameDay)
    }

    func test_readingDayAcrossADaylightSavingChange() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-10-31 22:00 EDT = 2026-11-01 02:00 UTC = 1_793_498_400; clocks go back on 1 Nov.
        let reading = Date(timeIntervalSince1970: 1_793_498_400)
        let midnights = ReadingDay.changeDates(after: reading, calendar: newYork)
        // 2026-11-01 00:00 EDT = 04:00 UTC = 1_793_505_600; 2026-11-02 00:00 EST = 05:00 UTC
        // = 1_793_595_600 (a 25-hour day).
        XCTAssertEqual(midnights, [Date(timeIntervalSince1970: 1_793_505_600), Date(timeIntervalSince1970: 1_793_595_600)])
        XCTAssertEqual(ReadingDay.of(reading, at: midnights[0].addingTimeInterval(-1), calendar: newYork), .sameDay)
        XCTAssertEqual(ReadingDay.of(reading, at: midnights[0], calendar: newYork), .yesterday)
        XCTAssertEqual(ReadingDay.of(reading, at: midnights[1].addingTimeInterval(-1), calendar: newYork), .yesterday)
        XCTAssertEqual(ReadingDay.of(reading, at: midnights[1], calendar: newYork), .earlier)
    }

    /// Midnight entries exist only to relabel a last reading: none for a message state, and they
    /// never push the next reload out (the idle reload still runs every 15 min).
    func test_midnightEntriesOnlyRelabelALastReadingAndDoNotDelayTheReload() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 45)
        let old = entries(snapshot(reading))
        XCTAssertEqual(old.map(\.date), [Fixture.now, Fixture.nextMidnight, secondMidnight])
        XCTAssertEqual(WidgetTimeline.nextReload(entries: old, now: Fixture.now), Fixture.now.addingTimeInterval(15 * 60))
        XCTAssertEqual(entries(snapshot(reading, state: .expired)).count, 1, "expired: no day label to change")
        XCTAssertEqual(entries(snapshot(reading, state: .notPaired)).count, 1)
    }

    // MARK: Chart window (D61)

    func test_chartEndsAtTheLastReadingOnceItIs20MinutesOld() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 3)
        let timeline = entries(snapshot(reading))
        let hours3: TimeInterval = 3 * 3_600
        // Current and stale: the 3 hours up to the entry's date.
        XCTAssertEqual(timeline[0].chartDomain, Fixture.now.addingTimeInterval(-hours3)...Fixture.now)
        XCTAssertFalse(timeline[0].chartEndsAtReading)
        XCTAssertEqual(timeline[1].chartDomain, timeline[1].date.addingTimeInterval(-hours3)...timeline[1].date)
        XCTAssertFalse(timeline[1].chartEndsAtReading)
        // Last reading: the 3 hours up to the reading, however late the entry.
        for entry in timeline.dropFirst(2) {
            XCTAssertEqual(entry.chartDomain, reading.date.addingTimeInterval(-hours3)...reading.date, "\(entry.date)")
            XCTAssertTrue(entry.chartEndsAtReading)
        }
        // A message state keeps the entry's own window.
        let expired = entries(snapshot(Fixture.latest(.mgdl(105), minutesAgo: 45), state: .expired))[0]
        XCTAssertEqual(expired.chartEnd, Fixture.now)
    }

    // MARK: LOW / HIGH

    func test_lowAndHighFlagsAreShownAsFlags() {
        for flag in [GlucoseValue.belowRange, .aboveRange] {
            let reading = Fixture.latest(flag, minutesAgo: 1, trend: .notComputable)
            let timeline = entries(snapshot(reading))
            XCTAssertEqual(timeline.first?.display, .current(reading))
            XCTAssertEqual(timeline.first?.widgetReading?.reading.value, flag, "S4: the flag itself, not 40/400")
            XCTAssertEqual(timeline.map(\.display), [.current(reading), .stale(reading), .noData(last: reading), .noData(last: reading), .noData(last: reading)])
        }
    }

    /// S4 in the last-reading state (D61): a LOW or HIGH an hour old is still the flag, muted.
    func test_S4_lastReadingKeepsLowAndHighFlags() {
        for (flag, text) in [(GlucoseValue.belowRange, "LOW"), (.aboveRange, "HIGH")] {
            let reading = Fixture.latest(flag, minutesAgo: 60, trend: .notComputable)
            let shown = entries(snapshot(reading)).first?.widgetReading
            XCTAssertEqual(shown?.age, .last)
            XCTAssertEqual(shown?.reading.value, flag)
            XCTAssertEqual(shown.map { GlucoseText.value($0.reading.value) }, text)
            XCTAssertEqual(shown?.isMuted, true)
            XCTAssertNil(shown?.reading.value.numericMgdl, "no number behind the flag")
        }
    }

    /// Reviews M1 + N1: a snapshot whose reading is dated ahead of the phone's clock never shows
    /// that reading as current or stale — not in any later entry of the timeline (after the clock
    /// "catches up" with the wrong date), and not in a timeline built later from the same snapshot.
    /// D61: nor as a last reading.
    func test_S5_futureDatedReadingIsNeverShownAsCurrent() {
        for minutesAhead in [5.0, 60, 600] {
            let reading = Fixture.latest(.mgdl(105), minutesAgo: -minutesAhead)
            let snap = snapshot(reading)
            let timeline = entries(snap)
            XCTAssertEqual(timeline.first?.display, .clockMismatch(latest: reading), "\(minutesAhead) min ahead")
            for entry in timeline {
                XCTAssertEqual(entry.display, .clockMismatch(latest: reading), "\(minutesAhead) min ahead: entry at \(entry.date)")
                XCTAssertNil(entry.display.displayedReading)
                XCTAssertNil(entry.widgetReading)
            }
            // Timelines built later (reloads), before and after the clock passes the reading's date,
            // with the persisted latch — and even without it, because the reading is dated ahead of
            // the snapshot's own write time.
            let latch = WidgetTimeline.clockMismatchLatch(snapshot: snap, now: Fixture.now, previous: nil)
            XCTAssertEqual(latch, reading.date)
            let laterTimes = [reading.date.addingTimeInterval(-120), reading.date, reading.date.addingTimeInterval(5 * 60),
                              reading.date.addingTimeInterval(15 * 60), reading.date.addingTimeInterval(3 * 3_600)]
            for later in laterTimes {
                for previous in [latch, nil] {
                    for entry in entries(snap, now: later, latchedFor: previous) {
                        XCTAssertNil(entry.widgetReading, "\(minutesAhead) min ahead, reload at \(later): number shown")
                        if case .current = entry.display { XCTFail("current after a clock mismatch") }
                    }
                }
            }
        }
    }

    /// Review N1: the phone clock moved back after the app wrote the snapshot.
    func test_S5_clockMovedBackAfterTheSnapshotIsAMismatch() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 3)
        let snap = snapshot(reading) // written at Fixture.now
        let earlier = Fixture.now.addingTimeInterval(-60 * 60)
        let timeline = entries(snap, now: earlier)
        XCTAssertTrue(timeline.allSatisfy { $0.display == .clockMismatch(latest: reading) })
        XCTAssertTrue(timeline.allSatisfy { $0.widgetReading == nil })
        // Within the 60 s tolerance it is not.
        XCTAssertEqual(entries(snap, now: Fixture.now.addingTimeInterval(-30)).first?.display, .current(reading))
    }

    /// A newer reading that is itself dated ahead of the phone's clock re-latches the mismatch for
    /// that reading; no entry shows it as current, before or after the clock passes its date.
    func test_S5_newerFutureDatedReadingReLatchesTheMismatch() {
        let first = Fixture.latest(.mgdl(105), minutesAgo: -600)
        let newer = Fixture.latest(.mgdl(120), minutesAgo: -590)
        let newSnapshot = snapshot(newer)
        let latch = WidgetTimeline.clockMismatchLatch(snapshot: newSnapshot, now: Fixture.now, previous: first.date)
        XCTAssertEqual(latch, newer.date, "re-latched for the newer reading")
        for now in [Fixture.now, newer.date, newer.date.addingTimeInterval(5 * 60)] {
            for entry in entries(newSnapshot, now: now, latchedFor: latch) {
                XCTAssertEqual(entry.display, .clockMismatch(latest: newer), "at \(now), entry \(entry.date)")
            }
        }
    }

    /// Review N1: a newer reading clears the latch.
    func test_newerReadingClearsTheMismatchLatch() {
        let old = Fixture.latest(.mgdl(105), minutesAgo: -600)
        let fresh = Fixture.latest(.mgdl(110), minutesAgo: 2)
        let newSnapshot = snapshot(fresh)
        let latch = WidgetTimeline.clockMismatchLatch(snapshot: newSnapshot, now: Fixture.now, previous: old.date)
        XCTAssertNil(latch)
        XCTAssertEqual(entries(newSnapshot, latchedFor: old.date).first?.display, .current(fresh))
    }

    // MARK: warm-up / expired / messages

    func test_warmUpShowsCountdownThenStopsClaimingWarmUp() {
        let end = Fixture.now.addingTimeInterval(45 * 60)
        let timeline = entries(snapshot(nil, state: .warmingUp(endsAt: end)))
        XCTAssertEqual(timeline.map(\.date), [Fixture.now, end])
        XCTAssertEqual(timeline.map(\.display), [.warmingUp(endsAt: end), .noData(last: nil)])
        XCTAssertTrue(timeline.allSatisfy { $0.widgetReading == nil })
    }

    func test_expiredSensor() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 2)
        XCTAssertEqual(displays(snapshot(reading, state: .expired)), [.sensorExpired(last: reading), .sensorExpired(last: reading), .sensorExpired(last: reading)])
    }

    func test_gracePeriodEndTurnsIntoExpired() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 2)
        let graceEnd = Fixture.now.addingTimeInterval(5 * 60)
        let timeline = entries(snapshot(reading, state: .gracePeriod(endsAt: graceEnd)))
        XCTAssertEqual(timeline.map(\.date), [Fixture.now, graceEnd, Fixture.minutesAgo(-8), Fixture.minutesAgo(-18)])
        XCTAssertEqual(timeline.map(\.display), [.current(reading), .sensorExpired(last: reading), .sensorExpired(last: reading), .sensorExpired(last: reading)])
    }

    /// Every message state shows its message and no number, whatever the reading's age (D61 left
    /// these unchanged): warm-up, expired (also at the grace period's end), error, an alerting
    /// failure, calibration needed / rejected, not paired.
    func test_S5_messageStatesShowNoNumber() {
        let states: [SensorState] = [
            .warmingUp(endsAt: Fixture.now.addingTimeInterval(3_600)), .expired, .gracePeriod(endsAt: Fixture.now.addingTimeInterval(-60)),
            .error(code: 7, description: "Sensor signal error"), .failed(SensorFailure(kind: .sensorFailed, message: "m")),
            .failed(SensorFailure(kind: .pairingRejected, message: "m")), .calibrationNeeded(code: 4), .calibrationError(code: 8), .notPaired,
        ]
        for state in states {
            for minutes in [2.0, 15, 45, 600] {
                for entry in entries(snapshot(Fixture.latest(.mgdl(105), minutesAgo: minutes), state: state)) {
                    // After warm-up the age rules apply again (an earlier sensor's reading is a last reading).
                    if case .warmingUp(let end) = state, entry.date >= end { continue }
                    XCTAssertNil(entry.widgetReading, "\(state), \(minutes) min: a number")
                    XCTAssertNil(entry.readingDay)
                    XCTAssertFalse(entry.showsReplayMarker)
                }
            }
        }
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
            (Fixture.latest(.mgdl(95), minutesAgo: 140), .searching),
            (Fixture.latest(.belowRange, minutesAgo: 1), Fixture.activeSensor),
            (nil, .warmingUp(endsAt: Fixture.now.addingTimeInterval(600))),
            (Fixture.latest(.mgdl(95), minutesAgo: 4), .gracePeriod(endsAt: Fixture.now.addingTimeInterval(120))),
            (Fixture.latest(.aboveRange, minutesAgo: 9), .expired),
        ]
        for (latest, state) in cases {
            let snap = snapshot(latest, state: state, recent: recent)
            for entry in entries(snap) {
                // The only number an entry can show is the snapshot's own latest reading, unchanged.
                if let shown = entry.display.displayedReading {
                    XCTAssertEqual(shown, latest, "\(state): entry at \(entry.date) shows something the app did not write")
                }
                if let shown = entry.widgetReading {
                    XCTAssertEqual(shown.reading, latest, "\(state): entry at \(entry.date) shows something the app did not write")
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
        let timeline = entries(snapshot(reading))
        XCTAssertEqual(WidgetTimeline.nextReload(entries: timeline, now: Fixture.now), Fixture.minutesAgo(-18), "midnight entries don't count")
        let idle = entries(nil)
        XCTAssertEqual(WidgetTimeline.nextReload(entries: idle, now: Fixture.now), Fixture.now.addingTimeInterval(15 * 60))
    }

    func test_entriesAreAscendingAndStartNow() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 3)
        let timeline = entries(snapshot(reading, state: .gracePeriod(endsAt: Fixture.now.addingTimeInterval(8 * 60))))
        XCTAssertEqual(timeline.first?.date, Fixture.now)
        XCTAssertEqual(timeline.map(\.date), timeline.map(\.date).sorted())
        XCTAssertEqual(Set(timeline.map(\.date)).count, timeline.count, "no duplicate dates")
        let old = entries(snapshot(Fixture.latest(.mgdl(105), minutesAgo: 3)))
        XCTAssertEqual(old.map(\.date), old.map(\.date).sorted())
        XCTAssertEqual(Set(old.map(\.date)).count, old.count, "no duplicate dates with midnight entries")
    }

    func test_widgetStyleRules() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 3)
        XCTAssertFalse(WidgetStyle.isStale(.current(reading)))
        XCTAssertTrue(WidgetStyle.isStale(.stale(reading)))
        XCTAssertEqual(WidgetStyle.chartOpacity(.current(reading)), 1)
        XCTAssertEqual(WidgetStyle.chartOpacity(.noData(last: reading)), Emphasis.dimmedChartOpacity)
        XCTAssertEqual(WidgetStyle.chartLatest(.current(reading)), ChartPoint(date: reading.date, value: reading.value))
        XCTAssertNil(WidgetStyle.chartLatest(.stale(reading)), "no 'latest' dot on a dimmed chart")
        XCTAssertNil(WidgetStyle.chartLatest(.noData(last: reading)))
        XCTAssertEqual(WidgetStyle.title(.noData(last: nil)), "No data")
        XCTAssertEqual(WidgetStyle.title(.stale(reading)), "105")
        XCTAssertNil(WidgetStyle.heroStyle(.mgdl(105)), "in range uses ink")
        XCTAssertEqual(WidgetStyle.heroStyle(.belowRange)?.band, .veryLow)
        XCTAssertEqual(WidgetStyle.spokenValue(WidgetReading(reading: reading, age: .current)), "105 milligrams per deciliter, steady")
        // Review m8: VoiceOver hears "stale" before the number. D61 (changed): no trend word once
        // the arrow is gone.
        XCTAssertEqual(WidgetStyle.spokenValue(WidgetReading(reading: reading, age: .stale)), "Stale: 105 milligrams per deciliter")
        XCTAssertEqual(WidgetStyle.spokenValue(WidgetReading(reading: reading, age: .last)), "Last reading 105 milligrams per deciliter")
        XCTAssertEqual(WidgetStyle.spokenValue(WidgetReading(reading: Fixture.latest(.belowRange, minutesAgo: 60), age: .last)),
                       "Last reading LOW, below the sensor's range")
        XCTAssertEqual(WidgetStyle.lastReadingLabel, "LAST READING")
    }

    func test_inlineValueHasAnArrowOnlyWhileCurrent() {
        let reading = Fixture.latest(.mgdl(105), minutesAgo: 3, trend: .singleUp)
        XCTAssertEqual(InlineAccessoryText.inlineValue(WidgetReading(reading: reading, age: .current)), "105 \(TrendText.glyph(.singleUp))")
        XCTAssertEqual(InlineAccessoryText.inlineValue(WidgetReading(reading: reading, age: .stale)), "105")
        XCTAssertEqual(InlineAccessoryText.inlineValue(WidgetReading(reading: reading, age: .last)), "105")
        XCTAssertEqual(InlineAccessoryText.inlineValue(WidgetReading(reading: Fixture.latest(.aboveRange, minutesAgo: 30, trend: .doubleUp), age: .last)), "HIGH")
    }
}
