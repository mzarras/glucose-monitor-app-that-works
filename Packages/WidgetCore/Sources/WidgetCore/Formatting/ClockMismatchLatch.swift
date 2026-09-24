// Review N1 (S5). A reading seen dated ahead of the phone's clock (the clock was moved back) stays
// a "clock mismatch" until a newer reading replaces it — even after the phone's clock catches up
// with its date. Without this, a reading that is really hours old would be classified "current"
// the moment the clock passed its (wrong) date. Pure; the app keeps the latch in NowViewState, the
// widget in its own defaults (keyed by the reading's date, so a new reading clears it).

import Foundation
import GlucoseCore

public enum ClockMismatchLatch {
    /// The reading date the latch is held for, or nil.
    ///
    /// - Parameters:
    ///   - latchedFor: the value returned last time (nil if none).
    ///   - latest: the latest live reading now.
    ///   - now: the phone's clock.
    ///   - snapshotWrittenAt: widget only — when the app wrote the snapshot. A reading dated ahead
    ///     of its own snapshot, or a clock now earlier than the write time, is also a mismatch.
    public static func update(latchedFor: Date?, latest: LatestReading?, now: Date, snapshotWrittenAt: Date? = nil) -> Date? {
        guard let latest else { return nil }
        if latchedFor == latest.date { return latchedFor }
        let tolerance = LiveReadingGate.futureTolerance
        if latest.date > now.addingTimeInterval(tolerance) { return latest.date }
        if let writtenAt = snapshotWrittenAt {
            if latest.date > writtenAt.addingTimeInterval(tolerance) { return latest.date }
            if now < writtenAt.addingTimeInterval(-tolerance) { return latest.date }
        }
        return nil
    }

    /// `display` with the latch applied: while latched for `latest`, a state that would show the
    /// reading (or its age) is a clock mismatch instead. Sensor messages (expired, error, …) and
    /// warm-up are kept.
    public static func apply(_ display: GlucoseDisplayState, latest: LatestReading?, latchedFor: Date?) -> GlucoseDisplayState {
        guard let latest, let latchedFor, latchedFor == latest.date else { return display }
        switch display {
        case .current, .stale, .noData, .clockMismatch:
            return .clockMismatch(latest: latest)
        case .warmingUp, .sensorExpired, .sensorError, .notPaired:
            return display
        }
    }
}
