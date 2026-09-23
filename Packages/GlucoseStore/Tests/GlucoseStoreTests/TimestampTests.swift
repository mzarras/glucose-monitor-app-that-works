import GlucoseCore
import GRDB
import XCTest
@testable import GlucoseStore

/// Storage holds UTC instants only: no time zone, no local wall-clock time, so DST transitions
/// cannot duplicate, drop or reorder readings.
final class TimestampTests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func localDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// 13 readings every 5 min starting at `start`.
    private func readings(startingAt start: Date) -> [GlucoseReading] {
        (0..<13).map { index in
            GlucoseReading(
                id: GlucoseReading.sensorID(serial: testSerial, sensorTimestamp: UInt32(index * 300)),
                date: start.addingTimeInterval(TimeInterval(index) * 300),
                value: .mgdl(100 + index), trendRate: nil, isBackfill: false, source: .sensor, sensorSerial: testSerial
            )
        }
    }

    func test_springForwardDayKeepsEveryReadingInOrder() async throws {
        // 2026-03-08 02:00 EST → 03:00 EDT (07:00 UTC). 01:30 EST = 06:30 UTC; one real hour later
        // the wall clock reads 03:30 EDT.
        let start = Date(timeIntervalSince1970: 1_772_951_400) // 2026-03-08T06:30:00Z
        XCTAssertEqual(start, localDate(2026, 3, 8, 1, 30))
        let store = try GlucoseStore.productionInMemory()
        let expected = readings(startingAt: start)
        _ = try await store.insert(expected)

        // The local calendar day is 23 hours long; the query takes whatever instants it is given.
        let stored = try await store.readings(from: localDate(2026, 3, 8, 0), to: localDate(2026, 3, 9, 0))

        XCTAssertEqual(stored, expected)
        XCTAssertEqual(zip(stored, stored.dropFirst()).map { $1.date.timeIntervalSince($0.date) }, Array(repeating: 300, count: 12))
    }

    func test_fallBackDayKeepsTheRepeatedHourDistinct() async throws {
        // 2026-11-01 02:00 EDT → 01:00 EST (06:00 UTC). 01:30 EDT = 05:30 UTC and 01:30 EST =
        // 06:30 UTC are different instants with the same wall-clock time.
        let start = Date(timeIntervalSince1970: 1_793_511_000) // 2026-11-01T05:30:00Z = 01:30 EDT
        let store = try GlucoseStore.productionInMemory()
        let expected = readings(startingAt: start)
        _ = try await store.insert(expected)

        let stored = try await store.readings(from: localDate(2026, 11, 1, 0), to: localDate(2026, 11, 2, 0))

        XCTAssertEqual(stored, expected)
        XCTAssertEqual(Set(stored.map(\.date)).count, 13, "the repeated local hour does not collapse readings")
        let csv = stored.map { CSVExport.utcTimestamp($0.date) }
        XCTAssertEqual(csv.first, "2026-11-01T05:30:00.000Z")
        XCTAssertEqual(csv.last, "2026-11-01T06:30:00.000Z")
    }

    func test_storedDateIsSecondsSinceReferenceDateInUTC() async throws {
        let store = try GlucoseStore.productionInMemory()
        _ = try await store.insert([sensorReading(at: 0)])
        let raw = try await store.writer.read { db in
            try Double.fetchOne(db, sql: "SELECT date FROM reading")
        }
        XCTAssertEqual(raw, 790_171_200) // 2026-01-15T12:00:00Z − 2001-01-01T00:00:00Z
        let readable = try await store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT datetime(date + 978307200, 'unixepoch') FROM reading")
        }
        XCTAssertEqual(readable, "2026-01-15 12:00:00", "the documented SQL for a readable date works")
    }
}
