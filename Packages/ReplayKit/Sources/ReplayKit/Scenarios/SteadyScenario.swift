// Scenario "steady" (docs/replay.md). DEBUG only (S6): compiled out of Release.
#if DEBUG
import Foundation
import GlucoseCore

/// A new sensor: 30-minute warm-up with no readings (S2), then 25 in-range readings every 5 min.
///
///     +0 min     state .warmingUp(endsAt: +30 min)
///     +30 min    state .active; first reading
///     +30…+150   readings every 5 min cycling 112, 113, 114, 113 mg/dL (rates −0.2/+0.2)
enum SteadyScenario {
    static let serial = "REPLAY-STEADY"

    /// (value mg/dL, trend mg/dL/min), repeated in this order.
    static let cycle: [(value: Int, trend: Double)] = [(112, -0.2), (113, 0.2), (114, 0.2), (113, -0.2)]

    static let milestones: [ScenarioMilestone: TimeInterval] = [
        .warmUpEnds: 30 * 60,
        .firstReading: 30 * 60,
        .lastReading: 150 * 60,
    ]

    static func timeline(origin: Date) -> ReplayTimeline {
        // The sensor session starts at the origin.
        let session = G7ReplaySession.session(serial: serial, start: origin)
        let factory = ReplayReadingFactory(origin: origin, session: session)
        var events = [
            ReplayEvent(offset: 0, kind: .state(.warmingUp(endsAt: session.warmUpEndsAt))),
            ReplayEvent(offset: 30 * 60, kind: .state(.active(sessionStart: session.start, expiresAt: session.expiresAt))),
        ]
        for (index, minute) in stride(from: 30, through: 150, by: 5).enumerated() {
            let step = cycle[index % cycle.count]
            let reading = factory.reading(minute: minute, .mgdl(step.value), trend: step.trend)
            events.append(ReplayEvent(offset: TimeInterval(minute) * 60, kind: .reading(reading)))
        }
        return ReplayTimeline(name: "steady", origin: origin, session: session, initialState: .searching, events: events)
    }
}
#endif
