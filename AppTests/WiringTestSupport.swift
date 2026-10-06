// Helpers for the Phase 2 wiring tests (view states built from `AppServices` values).

import Foundation
import GlucoseCore
@testable import Sensor

/// A Gregorian calendar in UTC, so day boundaries in tests don't depend on the host zone.
let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// A live sensor reading as the store would hold it.
func sensorReading(_ date: Date, _ value: GlucoseValue, rate: Double? = 0, serial: String = "TEST01", backfill: Bool = false) -> GlucoseReading {
    GlucoseReading(
        id: GlucoseReading.sensorID(serial: serial, sensorTimestamp: UInt32(max(0, date.timeIntervalSince1970 - 1_700_000_000))),
        date: date, value: value, trendRate: rate, isBackfill: backfill, source: .sensor, sensorSerial: serial)
}

/// An imported history reading (HANDOFF §4.5): charts and stats only (S6).
func importedReading(_ date: Date, _ value: GlucoseValue, origin: ImportOrigin = .nightscout) -> GlucoseReading {
    GlucoseReading(id: GlucoseReading.importedID(origin: origin, date: date), date: date, value: value, trendRate: nil,
                   isBackfill: false, source: .imported(origin), sensorSerial: "")
}

/// Readings every `step` seconds over `[start, end)`, value from `value(date)`.
func series(from start: Date, to end: Date, step: TimeInterval = 300, _ value: (Date) -> GlucoseValue) -> [GlucoseReading] {
    stride(from: start.timeIntervalSince1970, to: end.timeIntervalSince1970, by: step).map {
        let date = Date(timeIntervalSince1970: $0)
        return sensorReading(date, value(date))
    }
}
