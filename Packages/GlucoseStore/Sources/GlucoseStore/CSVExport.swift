// "Export all data (CSV)" (HANDOFF §4.5 "Backup", §7.3 Settings). Format documented in
// docs/storage.md; the golden test in CSVExportTests pins it byte for byte.
//
//   date_utc,glucose_mgdl,trend_mgdl_per_min,is_backfill,source,import_origin,sensor_serial,id
//   2026-01-15T12:00:00.000Z,112,0.2,false,sensor,,3M1234,3M1234:1800
//
// - date_utc: ISO 8601, UTC ("Z"), millisecond precision (rounded to the nearest millisecond).
// - glucose_mgdl: the integer, or the text LOW / HIGH for the sensor flags (S4: never 40 / 400).
// - trend_mgdl_per_min: as reported, shortest decimal that round-trips; empty when not reported.
// - is_backfill: true / false.
// - source: sensor | imported | replay | mock.   import_origin: nightscout | clarityCSV | empty.
// - Rows ascending by date, then id. UTF-8, no BOM, LF line endings, RFC 4180 quoting where needed.

import Foundation
import GlucoseCore

enum CSVExport {
    static let header = "date_utc,glucose_mgdl,trend_mgdl_per_min,is_backfill,source,import_origin,sensor_serial,id"

    static func line(for reading: GlucoseReading) -> String {
        let glucose: String
        switch reading.value {
        case .mgdl(let value): glucose = String(value)
        case .belowRange: glucose = "LOW"
        case .aboveRange: glucose = "HIGH"
        }

        let source: String
        let importOrigin: String
        switch reading.source {
        case .sensor: (source, importOrigin) = ("sensor", "")
        case .imported(let origin): (source, importOrigin) = ("imported", origin.rawValue)
        case .replay: (source, importOrigin) = ("replay", "")
        case .mock: (source, importOrigin) = ("mock", "")
        }

        return [
            utcTimestamp(reading.date),
            glucose,
            reading.trendRate.map { String($0) } ?? "",
            reading.isBackfill ? "true" : "false",
            source,
            importOrigin,
            quoted(reading.sensorSerial),
            quoted(reading.id),
        ].joined(separator: ",")
    }

    /// `2026-01-15T12:00:00.123Z`. Built from integer milliseconds so the fraction is exact (a
    /// formatter given the Double could print .122 for .123 after binary rounding).
    static func utcTimestamp(_ date: Date) -> String {
        let milliseconds = GlucoseReading.epochMilliseconds(date)
        let (seconds, fraction) = floorDivision(milliseconds, 1000)
        let whole = Date(timeIntervalSince1970: TimeInterval(seconds))
        let base = whole.formatted(Date.ISO8601FormatStyle(timeZone: .gmt))
        // base is "yyyy-MM-ddTHH:mm:ssZ"; insert the milliseconds before the "Z".
        return String(base.dropLast()) + "." + String(format: "%03lld", fraction) + "Z"
    }

    /// RFC 4180: a field containing a comma, quote, CR or LF is wrapped in quotes, quotes doubled.
    static func quoted(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Division rounding toward negative infinity, so dates before 1970 format correctly too.
    private static func floorDivision(_ value: Int64, _ divisor: Int64) -> (quotient: Int64, remainder: Int64) {
        var quotient = value / divisor
        var remainder = value % divisor
        if remainder < 0 {
            quotient -= 1
            remainder += divisor
        }
        return (quotient, remainder)
    }
}
