// Scenario "sensorExpiry" (docs/replay.md). DEBUG only (S6): compiled out of Release.
#if DEBUG
import Foundation
import GlucoseCore

/// A sensor 30 minutes before the end of its 10-day life. It enters the 12-hour grace period at
/// +30 min, keeps reading (including a meal spike through 250 to three HIGH flags), delivers its
/// last reading at +745 min and expires at +750 min (= grace period end). No reading after that.
///
///     grace period +30     first ≥ 250 at +105 (254)     HIGH flags +160, +165, +170
///     back < 250 at +240 (240)     last reading +745     expired +750
///
/// Values (150 readings, every 5 min from +0 to +745):
///     +0…+55     125, trend 0.0
///     +60        128, +0.6
///     +65…+155   142 + 14·k (k = 0…18: 142 … 394), +2.8
///     +160…+170  HIGH flag, no rate (S4)
///     +175…+285  396 − 12·k (k = 0…22: 396 … 132), −2.4
///     +290       130, −0.4
///     +295…+745  130, 0.0
/// No rate reaches 3 mg/dL/min, so rate alerts must not fire.
enum SensorExpiryScenario {
    static let serial = "REPLAY-EXPIRY"

    static let milestones: [ScenarioMilestone: TimeInterval] = [
        .firstReading: 0,
        .gracePeriodStarts: 30 * 60,
        .firstAtOrAbove250: 105 * 60,
        .firstHighFlag: 160 * 60,
        .backBelow250: 240 * 60,
        .lastReading: 745 * 60,
        .expired: 750 * 60,
    ]

    /// The value table above, as (minute, value, trend).
    static var script: [(minute: Int, value: GlucoseValue, trend: Double?)] {
        var rows: [(minute: Int, value: GlucoseValue, trend: Double?)] = []
        for minute in stride(from: 0, through: 55, by: 5) { rows.append((minute, .mgdl(125), 0.0)) }
        rows.append((60, .mgdl(128), 0.6))
        for k in 0...18 { rows.append((65 + 5 * k, .mgdl(142 + 14 * k), 2.8)) }
        for minute in [160, 165, 170] { rows.append((minute, .aboveRange, nil)) }
        for k in 0...22 { rows.append((175 + 5 * k, .mgdl(396 - 12 * k), -2.4)) }
        rows.append((290, .mgdl(130), -0.4))
        for minute in stride(from: 295, through: 745, by: 5) { rows.append((minute, .mgdl(130), 0.0)) }
        return rows
    }

    /// The rated life ends 30 min after the origin; the grace period 12 h later (+750 min).
    static let graceStartsMinute = 30
    static let expiresMinute = graceStartsMinute + Int(G7ReplaySession.gracePeriod / 60)

    static func timeline(origin: Date) -> ReplayTimeline {
        // Session started 10 days − 30 min before the origin.
        let start = origin.addingTimeInterval(-(G7ReplaySession.ratedLife - TimeInterval(graceStartsMinute) * 60))
        let session = G7ReplaySession.session(serial: serial, start: start)
        let factory = ReplayReadingFactory(origin: origin, session: session)

        var events = [ReplayEvent(offset: 0, kind: .state(.active(sessionStart: session.start, expiresAt: session.expiresAt)))]
        for row in script {
            if row.minute == graceStartsMinute {
                events.append(ReplayEvent(
                    offset: TimeInterval(graceStartsMinute) * 60,
                    kind: .state(.gracePeriod(endsAt: session.gracePeriodEndsAt))
                ))
            }
            let reading = factory.reading(minute: row.minute, row.value, trend: row.trend)
            events.append(ReplayEvent(offset: TimeInterval(row.minute) * 60, kind: .reading(reading)))
        }
        events.append(ReplayEvent(offset: TimeInterval(expiresMinute) * 60, kind: .state(.expired)))
        return ReplayTimeline(name: "sensorExpiry", origin: origin, session: session, initialState: .searching, events: events)
    }
}
#endif
