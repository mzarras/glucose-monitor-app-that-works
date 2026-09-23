// Dexcom Clarity CSV export → imported readings (HANDOFF §4.5 step 2).
//
// Layout of a real export (verified against public exports, e.g. GlucoseDAO/sugar-sugar
// data/example.csv and dhruv-aron/Glucose360 datasets/Clarity_Export_*.csv):
//   - optional UTF-8 BOM, CRLF line endings;
//   - header: Index, Timestamp (YYYY-MM-DDThh:mm:ss), Event Type, Event Subtype, Patient Info,
//     Device Info, Source Device ID, Glucose Value (mg/dL), Insulin Value (u), Carb Value (grams),
//     Duration (hh:mm:ss), Glucose Rate of Change (mg/dL/min), Transmitter Time (Long Integer),
//     Transmitter ID;
//   - metadata rows with an empty Timestamp: FirstName, LastName, DateOfBirth, Device, Alert (one
//     per alert setting);
//   - event rows: EGV (sensor glucose), Calibration, Insulin, Carbs, Exercise, Health, …;
//   - an EGV below/above the sensor's range has Event Subtype and Glucose Value "Low" / "High";
//   - timestamps are local wall-clock time with no offset.
// Columns are located by header name, not position. Only EGV rows become readings.
// mmol/L exports (header "Glucose Value (mmol/L)") are refused: v1 stores mg/dL only and a
// converted value would not be what the sensor reported.
//
// DST (timestamps have no offset, so the caller supplies the time zone they were recorded in):
//   - Spring forward: a local time inside the skipped hour never happened; the row is rejected and
//     counted (`rejectedNonexistentLocalTime`).
//   - Fall back: a local time inside the repeated hour happened twice. The row is placed only by
//     its transmitter time relative to a row whose instant is known (FallBackHourResolver.swift);
//     rows without that evidence are rejected (`rejectedAmbiguousLocalTime`). Two readings at the
//     same wall-clock time, one per pass, get two instants and two ids.

import Foundation
import GlucoseCore

public enum ClarityImportError: Error, Sendable, Equatable, CustomStringConvertible {
    case notUTF8
    case malformedCSV(line: Int, reason: String)
    /// The first row is not a Clarity header (no "Event Type" column).
    case notAClarityExport
    case missingColumn(String)
    /// The export uses a unit other than mg/dL.
    case unsupportedUnit(String)
    case repository(String)

    public var description: String {
        switch self {
        case .notUTF8: return "The file is not UTF-8 text"
        case .malformedCSV(let line, let reason): return "CSV error on line \(line): \(reason)"
        case .notAClarityExport: return "This is not a Dexcom Clarity CSV export"
        case .missingColumn(let name): return "The export has no \"\(name)\" column"
        case .unsupportedUnit(let header): return "Only mg/dL exports are supported (found \"\(header)\")"
        case .repository(let message): return "Could not store imported readings: \(message)"
        }
    }
}

/// What the parser found. Every row is accounted for in exactly one counter or in `readings`.
public struct ClarityParseResult: Sendable, Equatable {
    /// Readings in file order, one per distinct timestamp.
    public var readings: [GlucoseReading] = []
    public var egvRows = 0
    public var lowReadings = 0
    public var highReadings = 0
    /// Metadata and non-glucose events (FirstName, Device, Alert, Calibration, Insulin, Carbs, …).
    public var ignoredRows = 0
    /// EGV rows repeating a timestamp already seen (same instant → same reading id).
    public var duplicateRows = 0
    public var rejectedNonexistentLocalTime = 0
    public var rejectedAmbiguousLocalTime = 0
    public var rejectedInvalidTimestamp = 0
    public var rejectedInvalidValue = 0
    /// EGV rows dated later than the import's `now` + `LiveReadingGate.futureTolerance` (wrong time
    /// zone chosen, or a device clock fault). Stores reject such readings (PROGRESS D33).
    public var rejectedFutureDated = 0

    public init() {}
}

public enum ClarityExportParser {
    // Header names (see file comment for the full header).
    static let eventTypeColumn = "Event Type"
    static let timestampColumnPrefix = "Timestamp ("
    static let glucoseColumn = "Glucose Value (mg/dL)"
    static let glucoseColumnPrefix = "Glucose Value ("
    static let rateColumn = "Glucose Rate of Change (mg/dL/min)"
    static let transmitterTimeColumn = "Transmitter Time (Long Integer)"
    static let transmitterIDColumn = "Transmitter ID"
    static let egvEventType = "EGV"
    static let lowText = "Low"
    static let highText = "High"

    /// Parses a Clarity export. `timeZone` is where the data was recorded (HANDOFF §4.5 step 2:
    /// ask the user; default to the current zone). Rows dated after `now` +
    /// `LiveReadingGate.futureTolerance` are rejected and counted (D33).
    public static func parse(_ data: Data, timeZone: TimeZone = .current, now: Date) throws(ClarityImportError) -> ClarityParseResult {
        guard let text = String(data: data, encoding: .utf8) else { throw .notUTF8 }
        let rows: [[String]]
        do {
            rows = try CSVReader.rows(from: text)
        } catch {
            throw .malformedCSV(line: error.line, reason: error.reason)
        }
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces) }),
              let eventTypeIndex = header.firstIndex(of: eventTypeColumn) else {
            throw .notAClarityExport
        }
        guard let timestampIndex = header.firstIndex(where: { $0.hasPrefix(timestampColumnPrefix) }) else {
            throw .missingColumn("Timestamp (YYYY-MM-DDThh:mm:ss)")
        }
        guard let glucoseIndex = header.firstIndex(of: glucoseColumn) else {
            if let other = header.first(where: { $0.hasPrefix(glucoseColumnPrefix) }) { throw .unsupportedUnit(other) }
            throw .missingColumn(glucoseColumn)
        }
        let rateIndex = header.firstIndex(of: rateColumn)
        let transmitterTimeIndex = header.firstIndex(of: transmitterTimeColumn)
        let transmitterIDIndex = header.firstIndex(of: transmitterIDColumn)

        // Pass 1: EGV rows, their local times and transmitter clocks.
        struct EGVRow {
            let fields: [String]
            let time: FallBackHourResolver.Row.Time
            let invalidTimestamp: Bool
            let nonexistent: Bool
        }
        let resolver = LocalTimeResolver(timeZone: timeZone)
        var result = ClarityParseResult()
        var egvs: [EGVRow] = []
        var placementRows: [FallBackHourResolver.Row] = []
        for row in rows.dropFirst() {
            let fields = row.map { $0.trimmingCharacters(in: .whitespaces) }
            func field(_ index: Int?) -> String {
                guard let index, index < fields.count else { return "" }
                return fields[index]
            }
            guard field(eventTypeIndex) == egvEventType else {
                result.ignoredRows += 1
                continue
            }
            result.egvRows += 1
            var time = FallBackHourResolver.Row.Time.unplaceable
            var invalidTimestamp = false
            var nonexistent = false
            if let local = LocalDateTime(clarityTimestamp: field(timestampIndex)) {
                switch resolver.resolve(local) {
                case .unique(let instant): time = .known(instant)
                case .ambiguous(let earlier, let later): time = .ambiguous(earlier: earlier, later: later)
                case .nonexistent: nonexistent = true
                case .invalid: invalidTimestamp = true
                }
            } else {
                invalidTimestamp = true
            }
            let transmitterTime = Double(field(transmitterTimeIndex)).flatMap { $0.isFinite ? $0 : nil }
            let transmitterID = field(transmitterIDIndex)
            egvs.append(EGVRow(fields: fields, time: time, invalidTimestamp: invalidTimestamp, nonexistent: nonexistent))
            placementRows.append(FallBackHourResolver.Row(
                time: time, transmitterTime: transmitterTime, transmitterID: transmitterID.isEmpty ? nil : transmitterID
            ))
        }

        // Pass 2: instants (fall-back hour rules in FallBackHourResolver.swift).
        let placements = FallBackHourResolver.place(placementRows)

        // Pass 3: readings, in file order.
        var seenIDs: Set<String> = []
        for (egv, placement) in zip(egvs, placements) {
            let date: Date
            switch placement {
            case .placed(let instant):
                date = instant
            case .rejectedAmbiguous:
                result.rejectedAmbiguousLocalTime += 1
                continue
            case .unplaceable:
                if egv.nonexistent { result.rejectedNonexistentLocalTime += 1 } else { result.rejectedInvalidTimestamp += 1 }
                continue
            }
            func field(_ index: Int?) -> String {
                guard let index, index < egv.fields.count else { return "" }
                return egv.fields[index]
            }
            guard date <= now.addingTimeInterval(LiveReadingGate.futureTolerance) else {
                result.rejectedFutureDated += 1
                continue
            }
            guard let value = glucoseValue(field(glucoseIndex)) else {
                result.rejectedInvalidValue += 1
                continue
            }
            let id = GlucoseReading.importedID(origin: .clarityCSV, date: date)
            guard seenIDs.insert(id).inserted else {
                result.duplicateRows += 1
                continue
            }
            if value == .belowRange { result.lowReadings += 1 }
            if value == .aboveRange { result.highReadings += 1 }
            result.readings.append(GlucoseReading(
                id: id,
                date: date,
                value: value,
                // Clarity's own recorded rate when the export has one (usually empty for EGVs);
                // a non-numeric or non-finite rate becomes nil, never NaN/∞ (D33).
                trendRate: Double(field(rateIndex)).flatMap { $0.isFinite ? $0 : nil },
                isBackfill: false,
                source: .imported(.clarityCSV),
                // Unknown for imported history (GlucoseCore GlucoseReading.sensorSerial); also keeps
                // imported rows from ever matching a live session serial.
                sensorSerial: ""
            ))
        }
        return result
    }

    /// "Low" → `.belowRange`, "High" → `.aboveRange` (S4); a whole number 40...400 → `.mgdl`;
    /// anything else → `nil` (rejected, never clamped).
    static func glucoseValue(_ text: String) -> GlucoseValue? {
        if text.caseInsensitiveCompare(lowText) == .orderedSame { return .belowRange }
        if text.caseInsensitiveCompare(highText) == .orderedSame { return .aboveRange }
        guard let number = Double(text), number.isFinite, number == number.rounded(),
              number >= Double(GlucoseValue.sensorReportableRange.lowerBound),
              number <= Double(GlucoseValue.sensorReportableRange.upperBound) else { return nil }
        return .mgdl(Int(number))
    }
}
