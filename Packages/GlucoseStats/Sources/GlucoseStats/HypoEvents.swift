// CGM hypoglycaemia events, as HANDOFF §6 defines them. Battelino et al. (Diabetes Care 2019;42:1593,
// Table 1) lists "Episodes (hypoglycemia and hyperglycemia) 15 min" as a core metric; the begin/end
// rules below are HANDOFF §6's.
//
//   Level 1: starts with ≥ 15 consecutive minutes < 70 mg/dL.
//   Level 2: starts with ≥ 15 consecutive minutes < 54 mg/dL.
//   Either ends after ≥ 15 consecutive minutes ≥ 70 mg/dL (one rule for both levels, as HANDOFF §6
//   states it; some later texts end a level 2 event at ≥ 54 — see docs/statistics.md).
//
// Minutes are measured with the `Continuity` rules: a reading covers up to 5 minutes, gaps of more
// than 15 minutes end runs and events, and nothing is counted past the end of the period.

import Foundation
import GlucoseCore

public enum HypoLevel: String, Sendable, Equatable, Hashable, CaseIterable {
    case level1
    case level2

    /// A run of readings below this starts an event: 70 (level 1) or 54 (level 2) mg/dL.
    public var entryThresholdMgdl: Int {
        switch self {
        case .level1: return GlucoseThresholds.lowBelow
        case .level2: return GlucoseThresholds.veryLowBelow
        }
    }

    /// A run of readings at or above this ends an event, for both levels (HANDOFF §6).
    public static let exitThresholdMgdl = GlucoseThresholds.lowBelow
}

/// Why an event ended.
public enum HypoEventEnd: String, Sendable, Equatable, Hashable {
    /// ≥ 15 consecutive minutes at or above 70 mg/dL.
    case recovery
    /// A gap of more than 15 minutes without readings. What happened in the gap is unknown, so the
    /// event is not extended across it; a low after the gap is a new event.
    case gap
    /// The period's readings ran out before a recovery (for "today so far": the low is ongoing).
    case noMoreReadings
}

public struct HypoEvent: Sendable, Equatable {
    public let level: HypoLevel
    /// Timestamp of the first reading of the qualifying run.
    public let start: Date
    /// Coverage end of the event's last reading below 70 mg/dL.
    public let end: Date
    public let endedBy: HypoEventEnd
    /// Local wall-clock hour (0–23) of `start`.
    public let startHourOfDay: Int

    /// Seconds.
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// A span of hours of the day, possibly wrapping past midnight.
public struct HourWindow: Sendable, Equatable {
    public let startHour: Int
    public let hourCount: Int
    public let eventCount: Int
    /// Exclusive end hour, 0–23: a 3-hour window starting at 23 ends at 2.
    public var endHour: Int { (startHour + hourCount) % 24 }
}

/// The events of one level in a period.
public struct HypoEventSummary: Sendable, Equatable {
    /// A run must last this long (seconds) to start an event.
    public static let minimumDuration: TimeInterval = 15 * 60
    /// A run at or above 70 must last this long (seconds) to end an event.
    public static let recoveryDuration: TimeInterval = 15 * 60

    public let level: HypoLevel
    /// Ascending by start.
    public let events: [HypoEvent]
    /// Mean of `duration`, seconds; `nil` without events.
    public let meanDuration: TimeInterval?
    /// 24 counts: events by local hour of their start.
    public let startHourHistogram: [Int]

    public var count: Int { events.count }

    init(level: HypoLevel, period: PeriodReadings) {
        let events = Self.detect(level, in: period)
        var histogram = Array(repeating: 0, count: 24)
        var totalDuration: TimeInterval = 0
        for event in events {
            histogram[event.startHourOfDay] += 1
            totalDuration += event.duration
        }
        self.level = level
        self.events = events
        self.meanDuration = events.isEmpty ? nil : totalDuration / Double(events.count)
        self.startHourHistogram = histogram
    }

    /// The `hourCount`-hour window of the day holding the most event starts, for a note such as
    /// "4 of 6 between 2–5 AM". Only windows that start at an hour with an event are considered
    /// (any busiest window can be shifted to one without losing events); ties go to the earliest
    /// start hour. `nil` without events or for `hourCount` outside 1…24.
    public func busiestWindow(hourCount: Int) -> HourWindow? {
        guard (1...24).contains(hourCount) else { return nil }
        var best: HourWindow?
        for startHour in 0..<24 where startHourHistogram[startHour] > 0 {
            var eventCount = 0
            for offset in 0..<hourCount {
                eventCount += startHourHistogram[(startHour + offset) % 24]
            }
            if eventCount > (best?.eventCount ?? 0) {
                best = HourWindow(startHour: startHour, hourCount: hourCount, eventCount: eventCount)
            }
        }
        return best
    }

    /// One pass over the readings with two states.
    ///
    /// Outside an event: track the current run of readings below the entry threshold; when it
    /// lasts ≥ 15 min, an event starts at the run's first reading.
    /// Inside an event: a reading below 70 extends the event (and resets any recovery run); a
    /// reading at or above 70 extends the recovery run; when that lasts ≥ 15 min the event ends.
    /// A gap > 15 min ends the event and any run; so does running out of readings.
    static func detect(_ level: HypoLevel, in period: PeriodReadings) -> [HypoEvent] {
        let readings = period.readings
        var events: [HypoEvent] = []
        var lowRunStart: Int?       // outside an event: first reading of the current low run
        var eventStart: Int?        // inside an event: the event's first reading
        var lastBelowExit = 0       // inside an event: latest reading below 70
        var recoveryRunStart: Int?  // inside an event: first reading of the current ≥ 70 run

        func runDuration(from first: Int, to last: Int) -> TimeInterval {
            Continuity.coverageEnd(ofReadingAt: last, in: period).timeIntervalSince(readings[first].date)
        }

        func endEvent(_ reason: HypoEventEnd) {
            guard let first = eventStart else { return }
            events.append(HypoEvent(
                level: level,
                start: readings[first].date,
                end: Continuity.coverageEnd(ofReadingAt: lastBelowExit, in: period),
                endedBy: reason,
                startHourOfDay: readings[first].secondOfDay / 3_600
            ))
            eventStart = nil
            recoveryRunStart = nil
        }

        let entryThreshold = level.entryThresholdMgdl
        let exitThreshold = HypoLevel.exitThresholdMgdl
        period.forEachReading { index, reading in
            if reading.startsAfterGap {
                endEvent(.gap)
                lowRunStart = nil
            }
            let value = reading.value

            if eventStart != nil {
                if isBelow(value, exitThreshold) {
                    lastBelowExit = index
                    recoveryRunStart = nil
                } else {
                    let first = recoveryRunStart ?? index
                    recoveryRunStart = first
                    if runDuration(from: first, to: index) >= recoveryDuration {
                        endEvent(.recovery)
                    }
                }
            } else if isBelow(value, entryThreshold) {
                let first = lowRunStart ?? index
                lowRunStart = first
                if runDuration(from: first, to: index) >= minimumDuration {
                    eventStart = first
                    lastBelowExit = index
                    lowRunStart = nil
                }
            } else {
                lowRunStart = nil
            }
        }
        endEvent(.noMoreReadings)
        return events
    }

    /// LOW is below every threshold and HIGH above every threshold; numbers compare as numbers (S4).
    static func isBelow(_ value: GlucoseValue, _ thresholdMgdl: Int) -> Bool {
        switch value {
        case .belowRange: return true
        case .aboveRange: return false
        case .mgdl(let mgdl): return mgdl < thresholdMgdl
        }
    }
}

/// Level 1 and level 2 events of a period. "Today so far → lows" on the Now screen is
/// `level1.count` (every level 2 event also starts or extends a level 1 event).
public struct HypoEvents: Sendable, Equatable {
    public let level1: HypoEventSummary
    public let level2: HypoEventSummary

    public init(_ period: PeriodReadings) {
        level1 = HypoEventSummary(level: .level1, period: period)
        level2 = HypoEventSummary(level: .level2, period: period)
    }
}
