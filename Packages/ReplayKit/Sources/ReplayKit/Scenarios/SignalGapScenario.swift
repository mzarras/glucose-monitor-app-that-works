// Scenario "signalGapWithBackfill" (docs/replay.md). DEBUG only (S6): compiled out of Release.
#if DEBUG
import Foundation
import GlucoseCore

/// An active sensor (day 1). Live readings every 5 min until +30, then nothing is delivered for
/// 45 minutes. At +75 the sensor reconnects: the live +75 reading is delivered first, then the
/// eight missed readings (+35…+70) as one backfill batch, ascending, `isBackfill = true`, with
/// their original timestamps (S3). Live readings continue to +120. All values in range.
///
///     last live before gap +30     delivery resumes +75 (live 75, then backfill 35…70)
enum SignalGapScenario {
    static let serial = "REPLAY-GAP"

    /// (minute after origin, value mg/dL, reported trend in mg/dL/min).
    static let liveBeforeGap: [(minute: Int, value: Int, trend: Double)] = [
        (0, 140, 0.6), (5, 143, 0.6), (10, 146, 0.6), (15, 149, 0.6), (20, 152, 0.6), (25, 155, 0.6), (30, 158, 0.6),
    ]
    /// Recorded by the sensor during the gap; delivered at +75 as backfill.
    static let backfilled: [(minute: Int, value: Int, trend: Double)] = [
        (35, 161, 0.6), (40, 164, 0.6), (45, 167, 0.6), (50, 170, 0.6), (55, 172, 0.4), (60, 174, 0.4),
        (65, 176, 0.4), (70, 178, 0.4),
    ]
    static let liveAfterGap: [(minute: Int, value: Int, trend: Double)] = [
        (75, 180, 0.4), (80, 181, 0.2), (85, 182, 0.2), (90, 182, 0.0), (95, 181, -0.2), (100, 180, -0.2),
        (105, 178, -0.4), (110, 176, -0.4), (115, 174, -0.4), (120, 172, -0.4),
    ]
    static let reconnectMinute = 75

    static let milestones: [ScenarioMilestone: TimeInterval] = [
        .firstReading: 0,
        .lastReadingBeforeGap: 30 * 60,
        .liveReadingsResume: 75 * 60,
        .backfillDelivered: 75 * 60,
        .lastReading: 120 * 60,
    ]

    static func timeline(origin: Date) -> ReplayTimeline {
        // Session started 1 day before the origin.
        let session = G7ReplaySession.session(serial: serial, start: origin.addingTimeInterval(-86_400))
        let factory = ReplayReadingFactory(origin: origin, session: session)
        var events = [ReplayEvent(offset: 0, kind: .state(.active(sessionStart: session.start, expiresAt: session.expiresAt)))]

        for row in liveBeforeGap {
            let reading = factory.reading(minute: row.minute, .mgdl(row.value), trend: row.trend)
            events.append(ReplayEvent(offset: TimeInterval(row.minute) * 60, kind: .reading(reading)))
        }

        let reconnect = TimeInterval(reconnectMinute) * 60
        let backfill = backfilled.map { row in
            factory.reading(minute: row.minute, .mgdl(row.value), trend: row.trend, isBackfill: true)
        }
        for row in liveAfterGap {
            let reading = factory.reading(minute: row.minute, .mgdl(row.value), trend: row.trend)
            events.append(ReplayEvent(offset: TimeInterval(row.minute) * 60, kind: .reading(reading)))
            if row.minute == reconnectMinute {
                // Same delivery time, after the live reading: the order a G7 connection delivers.
                events.append(ReplayEvent(offset: reconnect, kind: .backfill(backfill)))
            }
        }
        return ReplayTimeline(name: "signalGapWithBackfill", origin: origin, session: session, initialState: .searching, events: events)
    }
}
#endif
