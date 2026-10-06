// Scenario "slowFallToUrgentLow" (docs/replay.md). DEBUG only (S6): compiled out of Release.
#if DEBUG
import Foundation
import GlucoseCore

/// An active sensor (day 3). A gradual fall (≤ 1 mg/dL/min) through 70 to ≤ 55, two LOW flags,
/// then recovery. No rate reaches 3 mg/dL/min, so rate alerts must not fire.
///
///     first ≤ 70 at +65 min (70)     first ≤ 55 at +85 min (55)     LOW flags at +110, +115
///     back > 55 at +130 min (60)     back > 70 at +140 min (75)     last reading +150 min
enum SlowFallScenario {
    static let serial = "REPLAY-FALL"

    /// Every reading: (minute after origin, value, reported trend in mg/dL/min).
    static let script: [(minute: Int, value: GlucoseValue, trend: Double?)] = [
        (0, .mgdl(120), -0.2), (5, .mgdl(119), -0.2), (10, .mgdl(118), -0.2), (15, .mgdl(116), -0.4),
        (20, .mgdl(112), -0.8), (25, .mgdl(107), -1.0), (30, .mgdl(102), -1.0), (35, .mgdl(97), -1.0),
        (40, .mgdl(92), -1.0), (45, .mgdl(87), -1.0), (50, .mgdl(82), -1.0), (55, .mgdl(77), -1.0),
        (60, .mgdl(73), -0.8), (65, .mgdl(70), -0.6), (70, .mgdl(66), -0.8), (75, .mgdl(62), -0.8),
        (80, .mgdl(58), -0.8), (85, .mgdl(55), -0.6), (90, .mgdl(51), -0.8), (95, .mgdl(47), -0.8),
        (100, .mgdl(43), -0.8), (105, .mgdl(40), -0.6),
        // Below the sensor's reportable range: the LOW flag, no number and no rate (S4).
        (110, .belowRange, nil), (115, .belowRange, nil),
        (120, .mgdl(45), 1.0), (125, .mgdl(52), 1.4), (130, .mgdl(60), 1.6), (135, .mgdl(68), 1.6),
        (140, .mgdl(75), 1.4), (145, .mgdl(82), 1.4), (150, .mgdl(88), 1.2),
    ]

    static let milestones: [ScenarioMilestone: TimeInterval] = [
        .firstReading: 0,
        .firstAtOrBelow70: 65 * 60,
        .firstAtOrBelow55: 85 * 60,
        .firstLowFlag: 110 * 60,
        .backAbove55: 130 * 60,
        .backAbove70: 140 * 60,
        .lastReading: 150 * 60,
    ]

    static func timeline(origin: Date) -> ReplayTimeline {
        // Session started 3 days before the origin: active the whole time.
        let session = G7ReplaySession.session(serial: serial, start: origin.addingTimeInterval(-3 * 86_400))
        let factory = ReplayReadingFactory(origin: origin, session: session)
        var events = [ReplayEvent(offset: 0, kind: .state(.active(sessionStart: session.start, expiresAt: session.expiresAt)))]
        for row in script {
            let reading = factory.reading(minute: row.minute, row.value, trend: row.trend)
            events.append(ReplayEvent(offset: TimeInterval(row.minute) * 60, kind: .reading(reading)))
        }
        return ReplayTimeline(name: "slowFallToUrgentLow", origin: origin, session: session, initialState: .searching, events: events)
    }
}
#endif
