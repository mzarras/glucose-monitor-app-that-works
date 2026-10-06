// Which readings count toward a period's statistics. Every metric reads its input from here, so
// the interval, ordering, duplicate and gap rules live in exactly one place.

import Foundation
import GlucoseCore

/// A reading that counts toward a period, reduced to what the metrics use. Only `PeriodReadings`
/// creates these, and only from a real `GlucoseReading` (S1).
public struct CountedReading: Sendable, Equatable {
    public let date: Date
    /// Exactly as reported: LOW and HIGH stay flags (S4).
    public let value: GlucoseValue
    /// `value.band`, computed once (LOW → `.veryLow`, HIGH → `.veryHigh`).
    public let band: GlucoseBand
    public let source: ReadingSource
    /// Local wall-clock seconds since midnight, `0..<86_400` (see `LocalTimeOfDay`).
    public let secondOfDay: Int
    /// The previous counted reading, including look-back context, is more than 15 minutes earlier
    /// (`Continuity.isGap`). False for the first reading of the whole window.
    public let startsAfterGap: Bool
}

/// The readings that count toward one period.
///
/// Rules:
/// 1. **Interval.** A reading counts when `interval.start <= date < interval.end` (half-open, as
///    `GlucoseReadingRepository.readings(from:to:)`). Everything else is ignored.
/// 2. **One reading per instant.** Readings with an identical `date` count once. The one kept is
///    chosen by, in order: source (`.sensor`, then `.imported`, then the DEBUG-only replay and mock
///    sources), live before backfill, then the smallest `id`. So a Nightscout copy never outweighs
///    the sensor's own reading, and the choice does not depend on input order. Readings at
///    different instants are never merged here: the store already removes imported readings
///    within ±150 s of another reading (`GlucoseReadingRepository.insert`).
/// 3. **Order.** Ascending by date.
/// 4. **Context.** Readings up to `contextDuration` (24 h) before and after the interval are kept,
///    with the same rules, in `lookBackReadings` and `lookAheadReadings`. Only hypo-event
///    detection uses them (a low that crosses the period boundary must not vanish); every other
///    metric reads `readings` alone. Callers should fetch readings for
///    `[start − 24 h, end + 24 h)`; with less context, a low crossing the boundary may be missed.
public struct PeriodReadings: Sendable, Equatable {
    /// How far before and after the interval readings are kept as context for hypo events.
    public static let contextDuration: TimeInterval = 24 * 60 * 60

    public let interval: DateInterval
    /// The readings inside `interval`: ascending by date, one per instant.
    public let readings: [CountedReading]
    /// Context: counted readings in `[interval.start − 24 h, interval.start)`, ascending.
    public let lookBackReadings: [CountedReading]
    /// Context: counted readings in `[interval.end, interval.end + 24 h)`, ascending.
    public let lookAheadReadings: [CountedReading]
    /// Input readings outside `interval` (the context ones included): not used by interval metrics.
    public let outsideIntervalCount: Int
    /// Input readings inside `interval` dropped because another reading had the same instant.
    public let duplicateCount: Int
    /// True when any counted reading inside `interval` is imported history (drives the Trends
    /// footnote, HANDOFF §4.5).
    public let containsImportedReadings: Bool

    /// - Parameter calendar: its time zone defines local time of day.
    public init(readings input: [GlucoseReading], interval: DateInterval, calendar: Calendar) {
        let windowStart = interval.start.addingTimeInterval(-Self.contextDuration)
        let windowEnd = interval.end.addingTimeInterval(Self.contextDuration)
        func isInsideInterval(_ date: Date) -> Bool { interval.start <= date && date < interval.end }

        var window: [GlucoseReading] = []
        window.reserveCapacity(input.count)
        var insideIntervalCount = 0
        var isStrictlyAscending = true
        var previousWindowDate: Date?
        for reading in input where windowStart <= reading.date && reading.date < windowEnd {
            if let previousWindowDate, reading.date <= previousWindowDate { isStrictlyAscending = false }
            previousWindowDate = reading.date
            if isInsideInterval(reading.date) { insideIntervalCount += 1 }
            window.append(reading)
        }
        // The store returns readings ascending and unique by date; sort only when that is not so.
        if !isStrictlyAscending {
            window.sort(by: Self.isCountedBefore)
        }

        let timeZone = calendar.timeZone
        var lookBack: [CountedReading] = []
        var inside: [CountedReading] = []
        var lookAhead: [CountedReading] = []
        inside.reserveCapacity(insideIntervalCount)
        var duplicates = 0
        var containsImported = false
        var previousCountedDate: Date?
        for reading in window {
            var startsAfterGap = false
            if let previousCountedDate {
                // After sorting, the preferred reading of an instant comes first; skip the rest.
                if reading.date == previousCountedDate {
                    if isInsideInterval(reading.date) { duplicates += 1 }
                    continue
                }
                startsAfterGap = Continuity.isGap(between: previousCountedDate, and: reading.date)
            }
            previousCountedDate = reading.date
            let counted = CountedReading(
                date: reading.date,
                value: reading.value,
                band: reading.value.band,
                source: reading.source,
                secondOfDay: LocalTimeOfDay.secondOfDay(for: reading.date, in: timeZone),
                startsAfterGap: startsAfterGap
            )
            if reading.date < interval.start {
                lookBack.append(counted)
            } else if reading.date < interval.end {
                inside.append(counted)
                if case .imported = reading.source { containsImported = true }
            } else {
                lookAhead.append(counted)
            }
        }

        self.interval = interval
        self.readings = inside
        self.lookBackReadings = lookBack
        self.lookAheadReadings = lookAhead
        self.outsideIntervalCount = input.count - insideIntervalCount
        self.duplicateCount = duplicates
        self.containsImportedReadings = containsImported
    }

    /// Calls `body` with each reading inside the interval and its index in `readings`, in order.
    public func forEachReading(_ body: (_ index: Int, _ reading: CountedReading) -> Void) {
        forEachCountedReading(in: readings, body)
    }

    /// Ascending date; at the same instant the preferred reading first (rule 2 above).
    static func isCountedBefore(_ a: GlucoseReading, _ b: GlucoseReading) -> Bool {
        if a.date != b.date { return a.date < b.date }
        let preferenceA = sourcePreference(a.source)
        let preferenceB = sourcePreference(b.source)
        if preferenceA != preferenceB { return preferenceA < preferenceB }
        if a.isBackfill != b.isBackfill { return !a.isBackfill }
        return a.id < b.id
    }

    /// Lower is preferred: the live sensor, then real history, then DEBUG test sources.
    static func sourcePreference(_ source: ReadingSource) -> Int {
        switch source {
        case .sensor: return 0
        case .imported: return 1
        case .replay: return 2
        case .mock: return 3
        }
    }
}

/// Calls `body` with each element of `readings` and its index, in order.
///
/// Every metric iterates through this one plain index loop rather than `for … in`: in the
/// unoptimised builds that `swift test` and the test gate time, `for … in` costs about 4× more per
/// element (see docs/statistics.md, Performance). Optimised builds are unaffected.
func forEachCountedReading(in readings: [CountedReading], _ body: (_ index: Int, _ reading: CountedReading) -> Void) {
    var index = 0
    while index < readings.count {
        body(index, readings[index])
        index += 1
    }
}
