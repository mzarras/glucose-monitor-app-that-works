// The grace-period countdown on the Now screen (PROGRESS D43): while the sensor is in its grace
// period and the app is open, a live countdown to the moment readings stop. Pure; unit-tested in
// GraceCountdownTests. When it reaches zero the Now screen's own clock (`NowRefreshSchedule`
// ticks at that instant) switches the hero to "Sensor expired".

import Foundation
import GlucoseCore

enum GraceCountdown {
    /// When the countdown is shown: the sensor is in its grace period and its end is still ahead.
    /// Nil otherwise (before grace, after its end — then the expired state shows instead).
    static func end(sensorState: SensorState, now: Date) -> Date? {
        guard case .gracePeriod(let endsAt) = sensorState, now < endsAt else { return nil }
        return endsAt
    }

    /// Whole seconds left, rounded up, so "0:00:00" is shown only at the end itself. Never negative.
    static func secondsLeft(until end: Date, now: Date) -> Int {
        max(0, Int(end.timeIntervalSince(now).rounded(.up)))
    }

    /// "7:40:12", "0:05:09" — hours (grace is at most 12 h), minutes and seconds.
    static func clock(until end: Date, now: Date) -> String {
        let total = secondsLeft(until: end, now: now)
        return String(format: "%d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60)
    }

    /// VoiceOver, to the minute (a label that changed every second would be read over and over):
    /// "Grace period, 7 hours 40 minutes left", "Grace period, 1 hour left",
    /// "Grace period, less than a minute left".
    static func spoken(until end: Date, now: Date) -> String {
        let minutes = secondsLeft(until: end, now: now) / 60
        guard minutes > 0 else { return "Grace period, less than a minute left" }
        let hours = minutes / 60
        let rest = minutes % 60
        var parts: [String] = []
        if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
        if rest > 0 { parts.append(rest == 1 ? "1 minute" : "\(rest) minutes") }
        return "Grace period, \(parts.joined(separator: " ")) left"
    }
}
