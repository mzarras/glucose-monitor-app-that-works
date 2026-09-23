// Shared test fixtures. Every calendar has an explicit time zone so no test depends on the host's
// zone, and every date is fixed so no test depends on the current date.

import Foundation
import GlucoseCore
@testable import GlucoseStats

enum Fixture {
    static let utc = calendar("UTC")
    static let newYork = calendar("America/New_York")
    /// Chile springs forward at midnight: on 2026-09-06 the day starts at 01:00.
    static let santiago = calendar("America/Santiago")

    static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// 2026-01-05 00:00:00 UTC (a Monday). Unix time 1 767 571 200.
    static let day0 = Date(timeIntervalSince1970: 1_767_571_200)
    /// 2026-03-08 00:00 EST = 05:00 UTC. New York springs forward at 02:00 EST that day: a 23-hour day.
    static let springForwardDayStart = Date(timeIntervalSince1970: 1_772_946_000)
    /// 2026-11-01 00:00 EDT = 04:00 UTC. New York falls back at 02:00 EDT that day: a 25-hour day.
    static let fallBackDayStart = Date(timeIntervalSince1970: 1_793_505_600)
    /// 2026-09-05 00:00 −04 (Santiago) = 04:00 UTC.
    static let santiagoSep5 = Date(timeIntervalSince1970: 1_788_580_800)
    /// 2026-09-06 01:00 −03 = 04:00 UTC: the first instant of Sep 6 in Santiago (00:00 → 01:00 at midnight).
    static let santiagoSep6 = Date(timeIntervalSince1970: 1_788_667_200)
    /// 2026-09-07 00:00 −03 = 03:00 UTC. Sep 6 lasted 23 h.
    static let santiagoSep7 = Date(timeIntervalSince1970: 1_788_750_000)
    /// 2026-09-08 00:00 −03.
    static let santiagoSep8 = Date(timeIntervalSince1970: 1_788_836_400)

    static let minute: TimeInterval = 60
    static let hour: TimeInterval = 3_600
    static let day: TimeInterval = 86_400

    /// `base + minutes`.
    static func at(_ minutes: Double, after base: Date = day0) -> Date {
        base.addingTimeInterval(minutes * minute)
    }

    /// `[start, start + minutes)`.
    static func interval(from start: Date = day0, minutes: Double) -> DateInterval {
        DateInterval(start: start, duration: minutes * minute)
    }

    static func reading(
        _ date: Date,
        _ value: GlucoseValue,
        source: ReadingSource = .sensor,
        isBackfill: Bool = false,
        serial: String = "SN1"
    ) -> GlucoseReading {
        let id: String
        switch source {
        case .imported(let origin):
            id = GlucoseReading.importedID(origin: origin, date: date)
        default:
            // Any fixed session start works; ids only need to be stable and distinct per instant.
            let sessionStart = Date(timeIntervalSince1970: 1_700_000_000)
            id = GlucoseReading.sensorID(serial: serial, sensorTimestamp: UInt32(date.timeIntervalSince(sessionStart)))
        }
        return GlucoseReading(
            id: id, date: date, value: value, trendRate: nil,
            isBackfill: isBackfill, source: source, sensorSerial: serial
        )
    }

    /// One reading per value, every `spacingMinutes` minutes starting at `start`.
    static func series(
        from start: Date = day0,
        spacingMinutes: Double = 5,
        _ values: [GlucoseValue],
        source: ReadingSource = .sensor
    ) -> [GlucoseReading] {
        values.enumerated().map { index, value in
            reading(at(Double(index) * spacingMinutes, after: start), value, source: source)
        }
    }

    /// Numeric values as `GlucoseValue`s.
    static func mg(_ values: Int...) -> [GlucoseValue] {
        values.map { .mgdl($0) }
    }

    static func period(
        _ readings: [GlucoseReading],
        _ interval: DateInterval,
        calendar: Calendar = utc
    ) -> PeriodReadings {
        PeriodReadings(readings: readings, interval: interval, calendar: calendar)
    }

    static let utcOptions = StatisticsOptions(calendar: utc)
    static let newYorkOptions = StatisticsOptions(calendar: newYork)

    /// 90 days of 5-minute readings from `start`: 90 × 288 = 25 920 readings. Deterministic.
    /// A daily sine wave (mean 140, amplitude 70) plus pseudo-random noise, with regular LOW and
    /// HIGH flags and a short sub-54 dip every night, so every metric has work to do.
    static func ninetyDays(from start: Date = day0) -> [GlucoseReading] {
        var generator = LinearCongruentialGenerator(seed: 42)
        var readings: [GlucoseReading] = []
        readings.reserveCapacity(25_920)
        for index in 0..<25_920 {
            let date = start.addingTimeInterval(Double(index) * 300)
            let slotOfDay = index % 288
            let value: GlucoseValue
            if index % 997 == 0 {
                value = .belowRange
            } else if index % 1_009 == 0 {
                value = .aboveRange
            } else if (36..<40).contains(slotOfDay) {
                value = .mgdl(50) // 03:00–03:15 every night: a 20-minute level 2 low
            } else {
                let wave = 140 + 70 * sin(2 * Double.pi * Double(slotOfDay) / 288)
                let noise = Double(generator.next() % 41) - 20
                value = .mgdl(Int(wave + noise))
            }
            readings.append(reading(date, value))
        }
        return readings
    }
}

/// Numerical Recipes LCG. Deterministic across platforms, unlike `SystemRandomNumberGenerator`.
struct LinearCongruentialGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }
}
