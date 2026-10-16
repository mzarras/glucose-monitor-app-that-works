// Builds the widget's timeline from the latest snapshot (HANDOFF §7.4, S1, S5).
//
// One entry now, plus one at each future moment the display must change without the app's help:
//   latest reading + 10 min → "stale": muted number, no arrow, no delta
//   latest reading + 20 min → "last reading": muted number with its time (D61), however old
//   local midnight(s)       → the last reading's day label ("Yesterday 11:02 PM", "Oct 14 …")
//   warm-up end             → stops claiming warm-up (age rules again; "no data" without a reading)
//   grace-period end        → "sensor expired"
// D61 (review m1): a reading from an earlier sensor than the snapshot's `currentSensor` is never
// shown ("No data · No readings from the new sensor yet"), and a transient state during the current
// session's warm-up shows that warm-up (`WidgetSnapshot.shownLatest`, `displaySensorState`).
// A clock mismatch (reading dated ahead of the phone, or inconsistent with the snapshot's write
// time) is latched for the whole timeline and across reloads (ClockMismatchLatch, review N1): no
// later entry shows that reading as a number (current, stale or last reading).
// Every entry shows the snapshot's own reading or none at all; entries never carry a value the
// snapshot does not contain (S1, asserted in WidgetTimelineTests).

import Foundation
import GlucoseCore

/// What one widget timeline entry displays.
public struct WidgetEntryContent: Sendable, Equatable {
    /// When WidgetKit should start showing this entry.
    public let date: Date
    public let display: GlucoseDisplayState
    /// The snapshot's 3-hour history, unchanged.
    public let recent: [ChartPoint]
    public let accent: AccentChoice
    /// When the app last wrote the snapshot; `nil` if it never has.
    public let snapshotWrittenAt: Date?
    /// The snapshot's `isReplay` (DEBUG, audit m9).
    public let isReplay: Bool
    /// For a last reading (≥ 20 min old, D61): which local day it was taken on, seen from `date`.
    /// `nil` in every other state.
    public let readingDay: ReadingDay?
    /// True for an entry scheduled only because the last reading's day label changes at a local
    /// midnight. `WidgetTimeline.nextReload` ignores these, so they never delay the next reload.
    public let isDayChangeOnly: Bool
    /// D61 (review m1): the snapshot's latest reading is from an earlier sensor and is not shown.
    public let hidesEarlierSensorReading: Bool

    public init(date: Date, display: GlucoseDisplayState, recent: [ChartPoint], accent: AccentChoice, snapshotWrittenAt: Date?,
                isReplay: Bool = false, calendar: Calendar = .autoupdatingCurrent, isDayChangeOnly: Bool = false,
                hidesEarlierSensorReading: Bool = false) {
        self.date = date
        self.display = display
        self.recent = recent
        self.accent = accent
        self.snapshotWrittenAt = snapshotWrittenAt
        self.isReplay = isReplay
        self.isDayChangeOnly = isDayChangeOnly
        self.hidesEarlierSensorReading = hidesEarlierSensorReading
        if let shown = display.widgetReading, shown.age == .last {
            readingDay = ReadingDay.of(shown.reading.date, at: date, calendar: calendar)
        } else {
            readingDay = nil
        }
    }

    /// The reading this entry shows as a number, and at which age (D61); `nil` for a message.
    public var widgetReading: WidgetReading? { display.widgetReading }

    /// DEBUG (audit m9): a displayed reading from a replay run carries a "REPLAY" label, so the
    /// widget can't pass a replayed value off as the sensor's. Always false in Release.
    public var showsReplayMarker: Bool {
        #if DEBUG
        return isReplay && widgetReading != nil
        #else
        return false
        #endif
    }

    /// The end of the 3-hour chart (D61). Normally the entry's date. For a last reading (≥ 20 min
    /// old) the reading's own date, so the chart keeps showing the last 3 hours of real data instead
    /// of scrolling empty. Not `snapshotWrittenAt`: the app rewrites the snapshot on every wake, so
    /// that date keeps moving even when no reading arrives.
    public var chartEnd: Date {
        if let shown = widgetReading, shown.age == .last { return shown.reading.date }
        return date
    }

    /// The time span the medium chart and the sparkline draw: 3 hours ending at `chartEnd`.
    public var chartDomain: ClosedRange<Date> {
        chartEnd.addingTimeInterval(-WidgetSnapshot.historyWindow)...chartEnd
    }

    /// True when the chart ends at the last reading rather than at the entry's date; the medium
    /// widget then labels the chart's right edge with that time, so it is not read as "now".
    public var chartEndsAtReading: Bool { chartEnd != date }
}

public enum WidgetTimeline {
    /// When nothing is scheduled to change, ask WidgetKit for a new timeline after this long, in
    /// case the app wrote a snapshot but its reload request was throttled.
    public static let idleRefreshInterval: TimeInterval = 15 * 60

    /// The clock-mismatch latch for this snapshot at `now` (persist it and pass it back next time).
    public static func clockMismatchLatch(snapshot: WidgetSnapshot?, now: Date, previous: Date?) -> Date? {
        guard let snapshot else { return nil }
        return ClockMismatchLatch.update(latchedFor: previous, latest: snapshot.shownLatest, now: now, snapshotWrittenAt: snapshot.writtenAt)
    }

    /// Timeline entries, ascending by date, starting at `now`.
    /// - Parameters:
    ///   - snapshot: the last snapshot the app wrote, or `nil` if none (or unreadable).
    ///   - latchedFor: the latch persisted from the previous timeline, if any.
    ///   - calendar: local days for the last reading's day label (the extension's current calendar).
    public static func entries(snapshot: WidgetSnapshot?, now: Date, latchedFor: Date? = nil,
                               calendar: Calendar = .autoupdatingCurrent) -> [WidgetEntryContent] {
        guard let snapshot else {
            return [WidgetEntryContent(date: now, display: .noData(last: nil), recent: [], accent: .default, snapshotWrittenAt: nil)]
        }
        let latch = clockMismatchLatch(snapshot: snapshot, now: now, previous: latchedFor)
        // D61 (review m1): an earlier sensor's reading is not shown; warm-up survives transient states.
        let latest = snapshot.shownLatest
        let sensorState = snapshot.displaySensorState
        let stateChanges = GlucoseDisplayState.transitionDates(latest: latest, sensorState: sensorState)
        // D61: the last reading's label names its day, which changes at local midnight.
        let dayChanges = latest.map { ReadingDay.changeDates(after: $0.date, calendar: calendar) } ?? []
        let future = (stateChanges + dayChanges).filter { $0 > now }.sorted()
        var dates: [Date] = [now]
        for date in future where date != dates.last { dates.append(date) }

        let entries = dates.map { date in
            WidgetEntryContent(
                date: date,
                display: ClockMismatchLatch.apply(
                    GlucoseDisplayState.classify(latest: latest, sensorState: sensorState, now: date),
                    latest: latest,
                    latchedFor: latch
                ),
                recent: snapshot.recent,
                accent: snapshot.accent,
                snapshotWrittenAt: snapshot.writtenAt,
                isReplay: snapshot.isReplay,
                calendar: calendar,
                isDayChangeOnly: date != now && dayChanges.contains(date) && !stateChanges.contains(date),
                hidesEarlierSensorReading: snapshot.latestIsFromAnEarlierSensor
            )
        }
        // A midnight entry matters only while it shows a last reading's day; otherwise it would
        // repeat the entry before it.
        return entries.filter { !$0.isDayChangeOnly || $0.readingDay != nil }
    }

    /// When WidgetKit should ask for the next timeline: just after the last scheduled state change,
    /// or `idleRefreshInterval` from now if none is scheduled. Midnight day-label entries don't
    /// count (D61): they can be two days away, and the idle reload is how the widget picks up a
    /// snapshot whose reload request iOS throttled.
    public static func nextReload(entries: [WidgetEntryContent], now: Date) -> Date {
        let last = entries.filter { !$0.isDayChangeOnly }.map(\.date).max() ?? now
        return last > now ? last.addingTimeInterval(60) : now.addingTimeInterval(idleRefreshInterval)
    }
}
