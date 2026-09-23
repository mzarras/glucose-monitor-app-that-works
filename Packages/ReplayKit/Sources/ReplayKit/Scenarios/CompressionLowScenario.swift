// Scenario "compressionLowSpike" (docs/replay.md). DEBUG only (S6): compiled out of Release.
#if DEBUG
import Foundation
import GlucoseCore

/// An active sensor (day 5), steady around 130, then a compression low: a sudden drop to 51–53
/// for 15 minutes and a sudden return.
///
///     fall ≥ 3 mg/dL/min at +35 (98, −6.2)     first ≤ 70 at +40 (64)     first ≤ 55 at +45 (52)
///     back > 55 and > 70 at +60 (90, +7.4 — also the first rise ≥ 3)      last reading +120 min
enum CompressionLowScenario {
    static let serial = "REPLAY-COMPRESSION"

    /// Every reading: (minute after origin, value mg/dL, reported trend in mg/dL/min).
    static let script: [(minute: Int, value: Int, trend: Double)] = [
        (0, 130, 0.0), (5, 131, 0.2), (10, 130, -0.2), (15, 129, -0.2), (20, 130, 0.2), (25, 130, 0.0),
        (30, 129, -0.2),
        // The drop.
        (35, 98, -6.2), (40, 64, -6.8), (45, 52, -2.4), (50, 51, -0.2), (55, 53, 0.4),
        // The return.
        (60, 90, 7.4), (65, 124, 6.8), (70, 128, 0.8),
        (75, 129, 0.2), (80, 130, 0.2), (85, 130, 0.0), (90, 129, -0.2), (95, 130, 0.2), (100, 131, 0.2),
        (105, 130, -0.2), (110, 130, 0.0), (115, 129, -0.2), (120, 130, 0.2),
    ]

    static let milestones: [ScenarioMilestone: TimeInterval] = [
        .firstReading: 0,
        .firstFallRateAtLeast3: 35 * 60,
        .firstAtOrBelow70: 40 * 60,
        .firstAtOrBelow55: 45 * 60,
        .backAbove55: 60 * 60,
        .backAbove70: 60 * 60,
        .firstRiseRateAtLeast3: 60 * 60,
        .lastReading: 120 * 60,
    ]

    static func timeline(origin: Date) -> ReplayTimeline {
        // Session started 5 days before the origin.
        let session = G7ReplaySession.session(serial: serial, start: origin.addingTimeInterval(-5 * 86_400))
        let factory = ReplayReadingFactory(origin: origin, session: session)
        var events = [ReplayEvent(offset: 0, kind: .state(.active(sessionStart: session.start, expiresAt: session.expiresAt)))]
        for row in script {
            let reading = factory.reading(minute: row.minute, .mgdl(row.value), trend: row.trend)
            events.append(ReplayEvent(offset: TimeInterval(row.minute) * 60, kind: .reading(reading)))
        }
        return ReplayTimeline(name: "compressionLowSpike", origin: origin, session: session, initialState: .searching, events: events)
    }
}
#endif
