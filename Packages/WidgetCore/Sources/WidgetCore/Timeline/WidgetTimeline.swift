// Builds the widget's timeline from the latest snapshot (HANDOFF §7.4, S1, S5).
//
// One entry now, plus one at each future moment the display must change without the app's help:
//   latest reading + 10 min → dimmed "stale"
//   latest reading + 20 min → "no data" (the number disappears)
//   warm-up end             → stops claiming warm-up (shows "no data" until the app writes again)
//   grace-period end        → "sensor expired"
// A clock mismatch (reading dated ahead of the phone, or inconsistent with the snapshot's write
// time) is latched for the whole timeline and across reloads (ClockMismatchLatch, review N1): no
// later entry shows that reading as current or stale.
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

    public init(date: Date, display: GlucoseDisplayState, recent: [ChartPoint], accent: AccentChoice, snapshotWrittenAt: Date?) {
        self.date = date
        self.display = display
        self.recent = recent
        self.accent = accent
        self.snapshotWrittenAt = snapshotWrittenAt
    }
}

public enum WidgetTimeline {
    /// When nothing is scheduled to change, ask WidgetKit for a new timeline after this long, in
    /// case the app wrote a snapshot but its reload request was throttled.
    public static let idleRefreshInterval: TimeInterval = 15 * 60

    /// The clock-mismatch latch for this snapshot at `now` (persist it and pass it back next time).
    public static func clockMismatchLatch(snapshot: WidgetSnapshot?, now: Date, previous: Date?) -> Date? {
        guard let snapshot else { return nil }
        return ClockMismatchLatch.update(latchedFor: previous, latest: snapshot.latest, now: now, snapshotWrittenAt: snapshot.writtenAt)
    }

    /// Timeline entries, ascending by date, starting at `now`.
    /// - Parameters:
    ///   - snapshot: the last snapshot the app wrote, or `nil` if none (or unreadable).
    ///   - latchedFor: the latch persisted from the previous timeline, if any.
    public static func entries(snapshot: WidgetSnapshot?, now: Date, latchedFor: Date? = nil) -> [WidgetEntryContent] {
        guard let snapshot else {
            return [WidgetEntryContent(date: now, display: .noData(last: nil), recent: [], accent: .default, snapshotWrittenAt: nil)]
        }
        let latch = clockMismatchLatch(snapshot: snapshot, now: now, previous: latchedFor)
        let future = GlucoseDisplayState
            .transitionDates(latest: snapshot.latest, sensorState: snapshot.sensorState)
            .filter { $0 > now }
        var dates: [Date] = [now]
        for date in future where date != dates.last { dates.append(date) }

        return dates.map { date in
            WidgetEntryContent(
                date: date,
                display: ClockMismatchLatch.apply(
                    GlucoseDisplayState.classify(latest: snapshot.latest, sensorState: snapshot.sensorState, now: date),
                    latest: snapshot.latest,
                    latchedFor: latch
                ),
                recent: snapshot.recent,
                accent: snapshot.accent,
                snapshotWrittenAt: snapshot.writtenAt
            )
        }
    }

    /// When WidgetKit should ask for the next timeline: just after the last scheduled change, or
    /// `idleRefreshInterval` from now if nothing is scheduled.
    public static func nextReload(entries: [WidgetEntryContent], now: Date) -> Date {
        let last = entries.map(\.date).max() ?? now
        return last > now ? last.addingTimeInterval(60) : now.addingTimeInterval(idleRefreshInterval)
    }
}
