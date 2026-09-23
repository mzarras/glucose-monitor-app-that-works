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
    /// The previous counted reading is more than 15 minutes earlier (`Continuity.isGap`). False for
    /// the first reading of the period.
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
public struct PeriodReadings: Sendable, Equatable {
    public let interval: DateInterval
    /// Ascending by date, one per instant.
    public let readings: [CountedReading]
    /// Input readings outside `interval`, ignored.
    public let outsideIntervalCount: Int
    /// Input readings dropped because another reading had the same instant.
    public let duplicateCount: Int
    /// True when any counted reading is imported history (drives the Trends footnote, HANDOFF §4.5).
    public let containsImportedReadings: Bool

    /// - Parameter calendar: its time zone defines local time of day.
    public init(readings input: [GlucoseReading], interval: DateInterval, calendar: Calendar) {
        var inside: [GlucoseReading] = []
        inside.reserveCapacity(input.count)
        var isStrictlyAscending = true
        var previousInsideDate: Date?
        for reading in input where interval.start <= reading.date && reading.date < interval.end {
            if let previousInsideDate, reading.date <= previousInsideDate { isStrictlyAscending = false }
            previousInsideDate = reading.date
            inside.append(reading)
        }
        // The store returns readings ascending and unique by date; sort only when that is not so.
        if !isStrictlyAscending {
            inside.sort(by: Self.isCountedBefore)
        }

        let timeZone = calendar.timeZone
        var counted: [CountedReading] = []
        counted.reserveCapacity(inside.count)
        var containsImported = false
        var previousCountedDate: Date?
        for reading in inside {
            var startsAfterGap = false
            if let previousCountedDate {
                // After sorting, the preferred reading of an instant comes first; skip the rest.
                if reading.date == previousCountedDate { continue }
                startsAfterGap = Continuity.isGap(between: previousCountedDate, and: reading.date)
            }
            if case .imported = reading.source { containsImported = true }
            counted.append(CountedReading(
                date: reading.date,
                value: reading.value,
                band: reading.value.band,
                source: reading.source,
                secondOfDay: LocalTimeOfDay.secondOfDay(for: reading.date, in: timeZone),
                startsAfterGap: startsAfterGap
            ))
            previousCountedDate = reading.date
        }

        self.interval = interval
        self.readings = counted
        self.outsideIntervalCount = input.count - inside.count
        self.duplicateCount = inside.count - counted.count
        self.containsImportedReadings = containsImported
    }

    /// Calls `body` with each counted reading and its index, in ascending order.
    ///
    /// Every metric iterates through this one plain index loop rather than `for … in`: in the
    /// unoptimised builds that `swift test` and the test gate time, `for … in` costs about 4× more
    /// per element (see docs/statistics.md, Performance). Optimised builds are unaffected.
    public func forEachReading(_ body: (_ index: Int, _ reading: CountedReading) -> Void) {
        var index = 0
        while index < readings.count {
            body(index, readings[index])
            index += 1
        }
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
