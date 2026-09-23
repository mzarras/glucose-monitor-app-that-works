// CGM hypoglycaemia events. Definition: Battelino T et al., "Continuous glucose monitoring and
// metrics for clinical trials: an international consensus statement", Lancet Diabetes Endocrinol
// 2023;11:42–57, Table 4 (p. 50) — the owner's choice, refining HANDOFF §6:
//
//   Level 1: starts with ≥ 15 consecutive minutes < 70 mg/dL; ends after ≥ 15 consecutive min ≥ 70.
//   Level 2: starts with ≥ 15 consecutive minutes < 54 mg/dL; ends after ≥ 15 consecutive min ≥ 54.
//
// Minutes are measured with the `Continuity` rules: a reading covers up to 5 minutes, and a gap of
// more than 15 minutes ends runs and events. Detection runs over the period plus 24 hours of
// context on each side (`PeriodReadings.contextDuration`); each event belongs to the period that
// contains its start, so a low crossing midnight is counted once, in the day it began.

import Foundation
import GlucoseCore

public enum HypoLevel: String, Sendable, Equatable, Hashable, CaseIterable {
    case level1
    case level2

    /// A run of readings below this for ≥ 15 min starts an event: 70 (level 1) or 54 (level 2) mg/dL.
    public var entryThresholdMgdl: Int {
        switch self {
        case .level1: return GlucoseThresholds.lowBelow
        case .level2: return GlucoseThresholds.veryLowBelow
        }
    }

    /// A run of readings at or above this for ≥ 15 min ends an event: 70 (level 1) or 54 (level 2)
    /// mg/dL (Battelino et al. 2023, Table 4). Readings below it continue the event.
    public var exitThresholdMgdl: Int {
        switch self {
        case .level1: return GlucoseThresholds.lowBelow
        case .level2: return GlucoseThresholds.veryLowBelow
        }
    }
}

/// Why an event ended.
public enum HypoEventEnd: String, Sendable, Equatable, Hashable {
    /// ≥ 15 consecutive minutes at or above the level's exit threshold.
    case recovery
    /// A gap of more than 15 minutes without readings. What happened in the gap is unknown, so the
    /// event is not extended across it; a low after the gap is a new event.
    case gap
    /// The readings ran out (within the 24 h look-ahead) before a recovery. For "today so far" this
    /// means the low is still going on.
    case noMoreReadings
}

public struct HypoEvent: Sendable, Equatable {
    public let level: HypoLevel
    /// Timestamp of the first reading of the qualifying run. Always inside the period the event is
    /// reported for.
    public let start: Date
    /// Coverage end of the event's last reading below the level's exit threshold (70 for level 1,
    /// 54 for level 2). May lie after the period end: the event is followed into the look-ahead.
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

/// The events of one level that start in a period.
public struct HypoEventSummary: Sendable, Equatable {
    /// A run below the entry threshold must last this long (seconds) to start an event.
    public static let minimumDuration: TimeInterval = 15 * 60
    /// A run at or above the exit threshold must last this long (seconds) to end an event.
    public static let recoveryDuration: TimeInterval = 15 * 60

    public let level: HypoLevel
    /// Events starting inside the period, ascending by start.
    public let events: [HypoEvent]
    /// Mean of `duration`, seconds; `nil` without events.
    public let meanDuration: TimeInterval?
    /// 24 counts: events by local hour of their start.
    public let startHourHistogram: [Int]

    public var count: Int { events.count }

    init(level: HypoLevel, period: PeriodReadings) {
        let interval = period.interval
        let events = Self.detect(level, in: period).filter { interval.start <= $0.start && $0.start < interval.end }
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

    /// Every event in the look-back, the period and the look-ahead, in one pass with two states.
    /// The caller keeps the ones that start inside the period.
    ///
    /// Outside an event: track the current run of readings below the entry threshold; when it
    /// lasts ≥ 15 min, an event starts at the run's first reading.
    /// Inside an event: a reading below the exit threshold extends the event (and resets any
    /// recovery run); a reading at or above it extends the recovery run; when that lasts ≥ 15 min
    /// the event ends. A gap > 15 min ends the event and any run; so does running out of readings.
    static func detect(_ level: HypoLevel, in period: PeriodReadings) -> [HypoEvent] {
        let readings = period.lookBackReadings + period.readings + period.lookAheadReadings
        let coverageLimit = period.interval.end.addingTimeInterval(PeriodReadings.contextDuration)
        let entryThreshold = level.entryThresholdMgdl
        let exitThreshold = level.exitThresholdMgdl

        var events: [HypoEvent] = []
        var lowRunStart: Int?       // outside an event: first reading of the current low run
        var eventStart: Int?        // inside an event: the event's first reading
        var lastBelowExit = 0       // inside an event: latest reading below the exit threshold
        var recoveryRunStart: Int?  // inside an event: first reading of the current recovery run

        func runDuration(from first: Int, to last: Int) -> TimeInterval {
            Continuity.coverageEnd(ofReadingAt: last, in: readings, notAfter: coverageLimit)
                .timeIntervalSince(readings[first].date)
        }

        func endEvent(_ reason: HypoEventEnd) {
            guard let first = eventStart else { return }
            events.append(HypoEvent(
                level: level,
                start: readings[first].date,
                end: Continuity.coverageEnd(ofReadingAt: lastBelowExit, in: readings, notAfter: coverageLimit),
                endedBy: reason,
                startHourOfDay: readings[first].secondOfDay / 3_600
            ))
            eventStart = nil
            recoveryRunStart = nil
        }

        forEachCountedReading(in: readings) { index, reading in
            if reading.startsAfterGap {
                endEvent(.gap)
                lowRunStart = nil
            }
            if eventStart != nil {
                if isBelow(reading.value, exitThreshold) {
                    lastBelowExit = index
                    recoveryRunStart = nil
                } else {
                    let first = recoveryRunStart ?? index
                    recoveryRunStart = first
                    if runDuration(from: first, to: index) >= recoveryDuration {
                        endEvent(.recovery)
                    }
                }
            } else if isBelow(reading.value, entryThreshold) {
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

/// Level 1 and level 2 events that start in a period. "Today so far → lows" on the Now screen is
/// `level1.count`. Every run below 54 lasting 15 min also lies below 70, so every level 2 event
/// starts or falls inside a level 1 event: one long level 1 low can hold several level 2 events,
/// and a level 2 event today can sit inside a level 1 event that began (and is counted) yesterday.
public struct HypoEvents: Sendable, Equatable {
    public let level1: HypoEventSummary
    public let level2: HypoEventSummary

    public init(_ period: PeriodReadings) {
        level1 = HypoEventSummary(level: .level1, period: period)
        level2 = HypoEventSummary(level: .level2, period: period)
    }
}
