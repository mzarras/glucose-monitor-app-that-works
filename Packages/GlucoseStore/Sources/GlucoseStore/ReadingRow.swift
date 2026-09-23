// The only place a GlucoseReading is turned into table columns and back (S3, S4, S6).
// Column meanings are documented next to the CREATE TABLE in StoreSchema.swift.

import Foundation
import GlucoseCore
import GRDB

/// One row of the `reading` table, as plain column values.
struct ReadingRow: Equatable, Sendable {
    var id: String
    /// `Date.timeIntervalSinceReferenceDate`, stored as REAL: bit-exact round trip.
    var date: Double
    var valueKind: String
    var mgdl: Int?
    var trendRate: Double?
    var isBackfill: Bool
    var sourceKind: String
    var importOrigin: String?
    var sensorSerial: String

    /// The column list shared by every SELECT, so decoding reads columns by name in a fixed order.
    static let selectColumns = "id, date, valueKind, mgdl, trendRate, isBackfill, sourceKind, importOrigin, sensorSerial"

    init(_ reading: GlucoseReading) {
        id = reading.id
        date = reading.date.timeIntervalSinceReferenceDate
        switch reading.value {
        case .mgdl(let value):
            valueKind = "mgdl"
            mgdl = value
        case .belowRange:
            valueKind = "belowRange"
            mgdl = nil
        case .aboveRange:
            valueKind = "aboveRange"
            mgdl = nil
        }
        // Stored exactly as reported. Non-finite rates never get here: `ReadingInsertion.validate`
        // rejects the whole batch first (D33), because SQLite would turn NaN into NULL.
        trendRate = reading.trendRate
        isBackfill = reading.isBackfill
        sourceKind = Self.sourceKind(of: reading.source)
        if case .imported(let origin) = reading.source {
            importOrigin = origin.rawValue
        } else {
            importOrigin = nil
        }
        sensorSerial = reading.sensorSerial
    }

    /// The `sourceKind` column value for a source.
    static func sourceKind(of source: ReadingSource) -> String {
        switch source {
        case .sensor: return "sensor"
        case .imported: return "imported"
        case .replay: return "replay"
        case .mock: return "mock"
        }
    }

    /// Reads a row selected with `selectColumns`.
    init(row: Row) {
        id = row["id"]
        date = row["date"]
        valueKind = row["valueKind"]
        mgdl = row["mgdl"]
        trendRate = row["trendRate"]
        isBackfill = row["isBackfill"]
        sourceKind = row["sourceKind"]
        importOrigin = row["importOrigin"]
        sensorSerial = row["sensorSerial"]
    }

    /// Arguments for `ReadingRow.insertSQL`, in column order.
    var insertArguments: StatementArguments {
        [id, date, valueKind, mgdl, trendRate, isBackfill, sourceKind, importOrigin, sensorSerial]
    }

    /// Decodes the row. Throws instead of guessing when a column holds something this version does
    /// not know (the CHECK constraints make that impossible for rows this code wrote).
    func reading() throws(GlucoseStoreError) -> GlucoseReading {
        let value: GlucoseValue
        switch (valueKind, mgdl) {
        case ("mgdl", .some(let number)): value = .mgdl(number)
        case ("belowRange", .none): value = .belowRange
        case ("aboveRange", .none): value = .aboveRange
        default: throw .unreadableRow(id: id, column: "valueKind/mgdl")
        }

        let source: ReadingSource
        switch (sourceKind, importOrigin) {
        case ("sensor", .none): source = .sensor
        case ("replay", .none): source = .replay
        case ("mock", .none): source = .mock
        case ("imported", .some(let raw)):
            guard let origin = ImportOrigin(rawValue: raw) else {
                throw .unreadableRow(id: id, column: "importOrigin")
            }
            source = .imported(origin)
        default: throw .unreadableRow(id: id, column: "sourceKind/importOrigin")
        }

        return GlucoseReading(
            id: id,
            date: Date(timeIntervalSinceReferenceDate: date),
            value: value,
            trendRate: trendRate,
            isBackfill: isBackfill,
            source: source,
            sensorSerial: sensorSerial
        )
    }

    /// True when `other` (a re-delivered copy with the same id) differs from this stored row only
    /// in `isBackfill` and/or by at most `maximumDateDifference` seconds in date. Value, trend
    /// rate, source, import origin and serial must be identical.
    func isBenignRedelivery(of other: ReadingRow, maximumDateDifference: TimeInterval) -> Bool {
        id == other.id
            && valueKind == other.valueKind
            && mgdl == other.mgdl
            && trendRate == other.trendRate
            && sourceKind == other.sourceKind
            && importOrigin == other.importOrigin
            && sensorSerial == other.sensorSerial
            && abs(date - other.date) <= maximumDateDifference
    }

    /// Names of the columns whose values differ, for the "same id, different content" diagnostic.
    func differingColumns(from other: ReadingRow) -> [String] {
        var names: [String] = []
        if date != other.date { names.append("date") }
        if valueKind != other.valueKind || mgdl != other.mgdl { names.append("value") }
        if trendRate != other.trendRate { names.append("trendRate") }
        if isBackfill != other.isBackfill { names.append("isBackfill") }
        if sourceKind != other.sourceKind || importOrigin != other.importOrigin { names.append("source") }
        if sensorSerial != other.sensorSerial { names.append("sensorSerial") }
        return names
    }
}
