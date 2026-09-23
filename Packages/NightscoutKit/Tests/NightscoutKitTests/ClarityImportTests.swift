import XCTest
import GlucoseCore
@testable import NightscoutKit

/// Dexcom Clarity CSV import (HANDOFF §4.5 steps 2–5). `clarity_export_synthetic.csv` follows the
/// real export layout (BOM, CRLF, 14-column header, metadata rows, Calibration/Insulin/Carbs
/// events, "Low"/"High" EGVs) with synthetic data recorded in America/New_York across the
/// 2025-11-02 fall-back.
final class ClarityImportTests: XCTestCase {
    static let newYork = TimeZone(identifier: "America/New_York")!

    private func parseFixture() throws -> ClarityParseResult {
        try ClarityExportParser.parse(Fixtures.data("clarity_export_synthetic.csv"), timeZone: Self.newYork)
    }

    /// Builds an export with the real header and the given EGV rows (timestamp, value, transmitter time).
    private func export(_ egvs: [(String, String, String)], header: String? = nil) -> Data {
        var lines = [header ?? "Index,Timestamp (YYYY-MM-DDThh:mm:ss),Event Type,Event Subtype,Patient Info,Device Info,Source Device ID,Glucose Value (mg/dL),Insulin Value (u),Carb Value (grams),Duration (hh:mm:ss),Glucose Rate of Change (mg/dL/min),Transmitter Time (Long Integer),Transmitter ID"]
        lines.append("1,,FirstName,,Synthetic,,,,,,,,,")
        for (index, egv) in egvs.enumerated() {
            lines.append("\(index + 2),\(egv.0),EGV,,,,iOS G7,\(egv.1),,,,,\(egv.2),SYNTH1")
        }
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    func test_parsesRealLayoutFixture() throws {
        let result = try parseFixture()
        XCTAssertEqual(result.egvRows, 12)
        XCTAssertEqual(result.readings.count, 12)
        XCTAssertEqual(result.ignoredRows, 12, "9 metadata rows + Calibration + Insulin + Carbs")
        XCTAssertEqual(result.lowReadings, 2)
        XCTAssertEqual(result.highReadings, 1)
        XCTAssertEqual(result.duplicateRows, 0)
        XCTAssertEqual(result.rejectedAmbiguousLocalTime + result.rejectedNonexistentLocalTime
            + result.rejectedInvalidTimestamp + result.rejectedInvalidValue, 0)

        // Hand-converted from America/New_York (EDT = UTC−4 until 02:00 EDT, then EST = UTC−5).
        let expected: [(String, GlucoseValue)] = [
            ("2025-11-02T04:50:00Z", .mgdl(118)),
            ("2025-11-02T04:55:00Z", .mgdl(117)),
            ("2025-11-02T05:25:00Z", .mgdl(110)),   // 01:25 EDT
            ("2025-11-02T05:30:00Z", .mgdl(108)),   // 01:30 EDT
            ("2025-11-02T05:55:00Z", .mgdl(104)),   // 01:55 EDT
            ("2025-11-02T06:00:00Z", .mgdl(103)),   // 01:00 EST (second pass)
            ("2025-11-02T06:30:00Z", .mgdl(99)),    // 01:30 EST (second pass)
            ("2025-11-02T07:00:00Z", .mgdl(96)),    // 02:00 EST
            ("2025-11-02T11:40:00Z", .belowRange),
            ("2025-11-02T11:45:00Z", .belowRange),
            ("2025-11-02T19:10:00Z", .aboveRange),
            ("2025-11-02T19:15:00Z", .mgdl(398)),
        ]
        XCTAssertEqual(result.readings.map(\.date), expected.map { Fixtures.date($0.0) })
        XCTAssertEqual(result.readings.map(\.value), expected.map(\.1))
        XCTAssertEqual(result.readings.last?.trendRate, -1.2, "Clarity's own rate column when present")
        XCTAssertNil(result.readings.first?.trendRate)
    }

    func test_S6_clarityImporterProducesOnlyImportedReadings() async throws {
        let repository = InMemoryGlucoseReadingRepository()
        _ = try await ClarityHistoryImporter(repository: repository).importExport(Fixtures.data("clarity_export_synthetic.csv"), timeZone: Self.newYork)
        let stored = await repository.stored
        XCTAssertEqual(stored.count, 12)
        for reading in stored {
            XCTAssertEqual(reading.source, .imported(.clarityCSV))
            XCTAssertEqual(reading.id, GlucoseReading.importedID(origin: .clarityCSV, date: reading.date))
            XCTAssertFalse(reading.isBackfill)
            XCTAssertEqual(reading.sensorSerial, "")
        }
    }

    func test_S4_clarityLowHighMapToFlags() throws {
        let result = try parseFixture()
        let low = result.readings.filter { $0.value == .belowRange }
        let high = result.readings.filter { $0.value == .aboveRange }
        XCTAssertEqual(low.map(\.date), [Fixtures.date("2025-11-02T11:40:00Z"), Fixtures.date("2025-11-02T11:45:00Z")])
        XCTAssertEqual(high.map(\.date), [Fixtures.date("2025-11-02T19:10:00Z")])
        XCTAssertFalse(result.readings.contains { $0.value == .mgdl(40) || $0.value == .mgdl(400) }, "never clamped")
        XCTAssertEqual(ClarityExportParser.glucoseValue("Low"), .belowRange)
        XCTAssertEqual(ClarityExportParser.glucoseValue("High"), .aboveRange)
        XCTAssertEqual(ClarityExportParser.glucoseValue("low"), .belowRange)
    }

    func test_S4_clarityNumbersOutsideSensorRangeAreRejectedNotClamped() throws {
        for text in ["39", "401", "0", "4095", "12.5", "abc", "", "-5", "1e308"] {
            XCTAssertNil(ClarityExportParser.glucoseValue(text), text)
        }
        XCTAssertEqual(ClarityExportParser.glucoseValue("40"), .mgdl(40))
        XCTAssertEqual(ClarityExportParser.glucoseValue("400"), .mgdl(400))
        XCTAssertEqual(ClarityExportParser.glucoseValue("120.0"), .mgdl(120))
        let result = try ClarityExportParser.parse(export([("2026-01-10T10:00:00", "39", ""), ("2026-01-10T10:05:00", "401", ""), ("2026-01-10T10:10:00", "120", "")]), timeZone: Self.newYork)
        XCTAssertEqual(result.rejectedInvalidValue, 2)
        XCTAssertEqual(result.readings.map(\.value), [.mgdl(120)])
    }

    func test_S3_clarityFallBackHourKeepsBothReadings() throws {
        // Coordinator requirement: two readings with the same local wall-clock time in the
        // repeated hour map to two instants, hence two ids.
        let result = try parseFixture()
        let atOneThirty = result.readings.filter { $0.value == .mgdl(108) || $0.value == .mgdl(99) }
        XCTAssertEqual(atOneThirty.map(\.date), [Fixtures.date("2025-11-02T05:30:00Z"), Fixtures.date("2025-11-02T06:30:00Z")])
        XCTAssertEqual(Set(atOneThirty.map(\.id)).count, 2)

        // The same with nothing between the two passes: the transmitter clock (3600 s apart) decides.
        let adjacent = try ClarityExportParser.parse(export([
            ("2025-11-02T01:30:00", "108", "88500"),
            ("2025-11-02T01:30:00", "99", "92100"),
        ]), timeZone: Self.newYork)
        XCTAssertEqual(adjacent.readings.map(\.date), [Fixtures.date("2025-11-02T05:30:00Z"), Fixtures.date("2025-11-02T06:30:00Z")])
        XCTAssertEqual(Set(adjacent.readings.map(\.id)).count, 2)
    }

    /// Rows with an explicit transmitter ID (timestamp, value, transmitter time, transmitter ID).
    private func export(rows: [(String, String, String, String)]) -> Data {
        var lines = ["Index,Timestamp (YYYY-MM-DDThh:mm:ss),Event Type,Event Subtype,Patient Info,Device Info,Source Device ID,Glucose Value (mg/dL),Insulin Value (u),Carb Value (grams),Duration (hh:mm:ss),Glucose Rate of Change (mg/dL/min),Transmitter Time (Long Integer),Transmitter ID"]
        for (index, row) in rows.enumerated() {
            lines.append("\(index + 1),\(row.0),EGV,,,,iOS G7,\(row.1),,,,,\(row.2),\(row.3)")
        }
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    func test_S3_clarityInterleavedFallBackPassesArePlacedByTransmitterTime() throws {
        // Reviewer M1: an export that lists the repeated hour sorted by wall-clock time interleaves
        // the two passes. Transmitter time (not file order) must place every row; none may land an
        // hour early or late. EDT pass: tt 1000, 1300, 1600; EST pass: tt 4600, 4900, 5200.
        let result = try ClarityExportParser.parse(export(rows: [
            ("2025-11-02T00:55:00", "120", "700", "SYNTH1"),    // 04:55Z, anchor
            ("2025-11-02T01:00:00", "121", "1000", "SYNTH1"),   // EDT → 05:00Z
            ("2025-11-02T01:00:00", "131", "4600", "SYNTH1"),   // EST → 06:00Z
            ("2025-11-02T01:05:00", "122", "1300", "SYNTH1"),   // EDT → 05:05Z
            ("2025-11-02T01:05:00", "132", "4900", "SYNTH1"),   // EST → 06:05Z
            ("2025-11-02T01:10:00", "123", "1600", "SYNTH1"),   // EDT → 05:10Z
            ("2025-11-02T01:10:00", "133", "5200", "SYNTH1"),   // EST → 06:10Z
            ("2025-11-02T02:00:00", "140", "8200", "SYNTH1"),   // 07:00Z
        ]), timeZone: Self.newYork)
        let placed = Dictionary(uniqueKeysWithValues: result.readings.map { ($0.value, $0.date) })
        let expected: [(Int, String)] = [
            (120, "2025-11-02T04:55:00Z"), (121, "2025-11-02T05:00:00Z"), (131, "2025-11-02T06:00:00Z"),
            (122, "2025-11-02T05:05:00Z"), (132, "2025-11-02T06:05:00Z"), (123, "2025-11-02T05:10:00Z"),
            (133, "2025-11-02T06:10:00Z"), (140, "2025-11-02T07:00:00Z"),
        ]
        for (value, iso) in expected {
            XCTAssertEqual(placed[.mgdl(value)], Fixtures.date(iso), "reading \(value)")
        }
        XCTAssertEqual(result.readings.count, 8)
        XCTAssertEqual(result.rejectedAmbiguousLocalTime, 0)
    }

    func test_S3_claritySecondPassAtFileStartIsPlacedByALaterAnchor() throws {
        // The file starts inside the second pass: file order alone would pick the first pass (an
        // hour early); the transmitter clock against the later 02:00 row places it correctly.
        let result = try ClarityExportParser.parse(export(rows: [
            ("2025-11-02T01:30:00", "99", "92100", "SYNTH1"),
            ("2025-11-02T02:00:00", "96", "93900", "SYNTH1"),
        ]), timeZone: Self.newYork)
        XCTAssertEqual(result.readings.map(\.date), [Fixtures.date("2025-11-02T06:30:00Z"), Fixtures.date("2025-11-02T07:00:00Z")])
    }

    func test_S3_clarityTransmitterTimeThatMatchesNeitherPassIsRejected() throws {
        // Transmitter clock says 01:40 EDT-equivalent (05:40Z) for a row stamped 01:30: neither
        // 05:30Z nor 06:30Z is within 60 s, so the row is rejected rather than guessed.
        let result = try ClarityExportParser.parse(export(rows: [
            ("2025-11-02T00:55:00", "120", "700", "SYNTH1"),
            ("2025-11-02T01:30:00", "110", "3400", "SYNTH1"),
        ]), timeZone: Self.newYork)
        XCTAssertEqual(result.readings.map(\.value), [.mgdl(120)])
        XCTAssertEqual(result.rejectedAmbiguousLocalTime, 1)
    }

    func test_S3_clarityTransmitterTimeFromAnotherTransmitterIsNotEvidence() throws {
        // A different transmitter's clock cannot be compared; file order applies (second pass here).
        let result = try ClarityExportParser.parse(export(rows: [
            ("2025-11-02T01:55:00", "104", "90000", "SYNTH1"),
            ("2025-11-02T01:00:00", "103", "300", "OTHER2"),
        ]), timeZone: Self.newYork)
        XCTAssertEqual(result.readings.map(\.date), [Fixtures.date("2025-11-02T05:55:00Z"), Fixtures.date("2025-11-02T06:00:00Z")])
    }

    func test_S3_clarityRepeatedRowWithoutEvidenceIsADuplicateNotANewReading() throws {
        // Same local time, same transmitter time (or none): one reading listed twice. It must not be
        // turned into a second reading an hour later (S1).
        for transmitterTimes in [("88500", "88500"), ("", "")] {
            let result = try ClarityExportParser.parse(export([
                ("2025-11-02T01:30:00", "108", transmitterTimes.0),
                ("2025-11-02T01:30:00", "108", transmitterTimes.1),
            ]), timeZone: Self.newYork)
            XCTAssertEqual(result.readings.map(\.date), [Fixtures.date("2025-11-02T05:30:00Z")])
            XCTAssertEqual(result.duplicateRows, 1)
        }
    }

    func test_S3_clarityOutOfOrderAmbiguousTimeIsRejected() throws {
        // 03:00 EST, then a 01:30 that could be 05:30Z or 06:30Z — both before 08:00Z: out of order.
        let result = try ClarityExportParser.parse(export([
            ("2025-11-02T03:00:00", "120", ""),
            ("2025-11-02T01:30:00", "118", ""),
        ]), timeZone: Self.newYork)
        XCTAssertEqual(result.readings.map(\.date), [Fixtures.date("2025-11-02T08:00:00Z")])
        XCTAssertEqual(result.rejectedAmbiguousLocalTime, 1)
    }

    func test_S3_claritySpringForwardNonexistentTimeRejected() throws {
        // 2026-03-08 America/New_York: 02:00 EST jumps to 03:00 EDT; 02:30 never happened.
        let result = try ClarityExportParser.parse(export([
            ("2026-03-08T01:55:00", "130", ""),
            ("2026-03-08T02:30:00", "128", ""),
            ("2026-03-08T03:00:00", "126", ""),
        ]), timeZone: Self.newYork)
        XCTAssertEqual(result.readings.map(\.date), [Fixtures.date("2026-03-08T06:55:00Z"), Fixtures.date("2026-03-08T07:00:00Z")])
        XCTAssertEqual(result.rejectedNonexistentLocalTime, 1)
    }

    func test_S3_clarityDSTInAnotherTimeZone() throws {
        // Europe/London 2025-10-26: 01:00–01:59 happens as BST (UTC+1) then GMT (UTC+0).
        let london = TimeZone(identifier: "Europe/London")!
        let result = try ClarityExportParser.parse(export([
            ("2025-10-26T00:55:00", "100", ""),
            ("2025-10-26T01:30:00", "101", ""),
            ("2025-10-26T01:10:00", "102", ""),
            ("2025-10-26T02:00:00", "103", ""),
        ]), timeZone: london)
        XCTAssertEqual(result.readings.map(\.date), [
            Fixtures.date("2025-10-25T23:55:00Z"), Fixtures.date("2025-10-26T00:30:00Z"),
            Fixtures.date("2025-10-26T01:10:00Z"), Fixtures.date("2025-10-26T02:00:00Z"),
        ])
    }

    func test_timestampsUseTheCallerSuppliedTimeZone() throws {
        let data = export([("2026-01-10T10:00:00", "120", "")])
        let utc = try ClarityExportParser.parse(data, timeZone: TimeZone(identifier: "UTC")!)
        let tokyo = try ClarityExportParser.parse(data, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertEqual(utc.readings.first?.date, Fixtures.date("2026-01-10T10:00:00Z"))
        XCTAssertEqual(tokyo.readings.first?.date, Fixtures.date("2026-01-10T01:00:00Z"))
    }

    func test_invalidTimestampsAreCounted() throws {
        let result = try ClarityExportParser.parse(export([
            ("", "120", ""), ("2026-02-30T10:00:00", "120", ""), ("2026-01-10 25:00:00", "120", ""),
            ("10/01/2026 10:00", "120", ""), ("2026-01-10 10:05:00", "121", ""),
        ]), timeZone: Self.newYork)
        XCTAssertEqual(result.rejectedInvalidTimestamp, 4)
        XCTAssertEqual(result.readings.count, 1, "older exports use a space instead of T")
    }

    func test_refusesMmolExportsAndOtherFiles() {
        let mmol = export([("2026-01-10T10:00:00", "6.7", "")], header: "Index,Timestamp (YYYY-MM-DDThh:mm:ss),Event Type,Event Subtype,Patient Info,Device Info,Source Device ID,Glucose Value (mmol/L),Insulin Value (u),Carb Value (grams),Duration (hh:mm:ss),Glucose Rate of Change (mmol/L/min),Transmitter Time (Long Integer),Transmitter ID")
        XCTAssertThrowsError(try ClarityExportParser.parse(mmol, timeZone: Self.newYork)) { error in
            XCTAssertEqual(error as? ClarityImportError, .unsupportedUnit("Glucose Value (mmol/L)"))
        }
        XCTAssertThrowsError(try ClarityExportParser.parse(Data("date,value\n2026-01-10,120\n".utf8))) { error in
            XCTAssertEqual(error as? ClarityImportError, .notAClarityExport)
        }
        XCTAssertThrowsError(try ClarityExportParser.parse(Data([0xFF, 0xFE, 0x00]))) { error in
            XCTAssertEqual(error as? ClarityImportError, .notUTF8)
        }
        XCTAssertThrowsError(try ClarityExportParser.parse(Data("Index,Event Type,Glucose Value (mg/dL)\n".utf8))) { error in
            XCTAssertEqual(error as? ClarityImportError, .missingColumn("Timestamp (YYYY-MM-DDThh:mm:ss)"))
        }
    }

    func test_S3_clarityImportIsIdempotent() async throws {
        let repository = InMemoryGlucoseReadingRepository()
        let importer = ClarityHistoryImporter(repository: repository, batchSize: 5)
        let data = try Fixtures.data("clarity_export_synthetic.csv")
        let first = try await importer.importExport(data, timeZone: Self.newYork)
        XCTAssertEqual(first.readingsImported, 12)
        XCTAssertEqual(first.readingsSkippedByStore, 0)
        XCTAssertEqual(first.coveredFrom, Fixtures.date("2025-11-02T04:50:00Z"))
        XCTAssertEqual(first.coveredTo, Fixtures.date("2025-11-02T19:15:00Z"))
        let afterFirst = await repository.stored

        let second = try await importer.importExport(data, timeZone: Self.newYork)
        XCTAssertEqual(second.readingsImported, 0)
        XCTAssertEqual(second.readingsSkippedByStore, 12)
        let afterSecond = await repository.stored
        XCTAssertEqual(afterSecond, afterFirst)
    }

    func test_clarityImportBatchesAndReportsProgress() async throws {
        let repository = InMemoryGlucoseReadingRepository()
        let collected = ProgressCollector()
        _ = try await ClarityHistoryImporter(repository: repository, batchSize: 5)
            .importExport(Fixtures.data("clarity_export_synthetic.csv"), timeZone: Self.newYork) { collected.append($0) }
        let values = collected.values
        XCTAssertEqual(values.map(\.readingsProcessed), [5, 10, 12])
        XCTAssertEqual(values.last?.readingsImported, 12)
        XCTAssertEqual(values.last?.coveredTo, Fixtures.date("2025-11-02T19:15:00Z"))
        await XCTAssertEqualAsync(await repository.insertCalls, 3)
    }

    func test_clarityOverlappingNightscoutImportCollapsesInStore() async throws {
        // A Nightscout reading 40 s from a Clarity reading of the same moment: the store keeps one.
        let repository = InMemoryGlucoseReadingRepository()
        let nightscoutDate = Fixtures.date("2026-01-10T15:00:40Z")
        _ = try await repository.insert([GlucoseReading(
            id: GlucoseReading.importedID(origin: .nightscout, date: nightscoutDate), date: nightscoutDate,
            value: .mgdl(120), trendRate: nil, isBackfill: false, source: .imported(.nightscout), sensorSerial: ""
        )])
        let result = try await ClarityHistoryImporter(repository: repository)
            .importExport(export([("2026-01-10T10:00:00", "120", ""), ("2026-01-10T10:05:00", "121", "")]), timeZone: Self.newYork)
        XCTAssertEqual(result.readingsImported, 1)
        XCTAssertEqual(result.readingsSkippedByStore, 1)
    }

    func test_repositoryFailureIsReported() async throws {
        let repository = InMemoryGlucoseReadingRepository()
        await repository.failNextInsert()
        let data = try Fixtures.data("clarity_export_synthetic.csv")
        do {
            _ = try await ClarityHistoryImporter(repository: repository).importExport(data, timeZone: Self.newYork)
            XCTFail("expected a repository error")
        } catch {
            guard case .repository = error else { return XCTFail("unexpected \(error)") }
        }
    }
}

final class ProgressCollector: @unchecked Sendable {
    // @unchecked Sendable: `storage` is only read and written while holding `lock`.
    private let lock = NSLock()
    private var storage: [ClarityImportProgress] = []
    func append(_ value: ClarityImportProgress) { lock.withLock { storage.append(value) } }
    var values: [ClarityImportProgress] { lock.withLock { storage } }
}

final class CSVReaderTests: XCTestCase {
    func test_quotedFieldsEscapesAndLineEndings() throws {
        let text = "\u{FEFF}a,\"b, with comma\",\"say \"\"hi\"\"\"\r\n1,,3\n\n\"multi\nline\",x,y\r"
        XCTAssertEqual(try CSVReader.rows(from: text), [
            ["a", "b, with comma", "say \"hi\""],
            ["1", "", "3"],
            ["multi\nline", "x", "y"],
        ])
    }

    func test_malformedQuotesAreReported() {
        XCTAssertThrowsError(try CSVReader.rows(from: "a,\"open\n")) { error in
            XCTAssertEqual((error as? CSVReader.MalformedCSV)?.reason, "unterminated quoted field")
        }
        XCTAssertThrowsError(try CSVReader.rows(from: "a,b\"c\n")) { error in
            XCTAssertEqual((error as? CSVReader.MalformedCSV)?.line, 1)
        }
    }

    func test_quotedDeviceInfoInClarityRow() throws {
        let data = Data("Index,Timestamp (YYYY-MM-DDThh:mm:ss),Event Type,Event Subtype,Patient Info,Device Info,Source Device ID,Glucose Value (mg/dL)\r\n1,2026-01-10T10:00:00,EGV,,,\"G7, iOS\",iOS G7,120\r\n".utf8)
        let result = try ClarityExportParser.parse(data, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(result.readings.map(\.value), [.mgdl(120)])
    }
}

final class LocalTimeResolverTests: XCTestCase {
    func test_resolvesUniqueAmbiguousAndNonexistentTimes() {
        let resolver = LocalTimeResolver(timeZone: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(resolver.resolve(LocalDateTime(year: 2025, month: 7, day: 4, hour: 12, minute: 0, second: 0)),
                       .unique(Fixtures.date("2025-07-04T16:00:00Z")))
        XCTAssertEqual(resolver.resolve(LocalDateTime(year: 2025, month: 11, day: 2, hour: 1, minute: 0, second: 0)),
                       .ambiguous(earlier: Fixtures.date("2025-11-02T05:00:00Z"), later: Fixtures.date("2025-11-02T06:00:00Z")))
        XCTAssertEqual(resolver.resolve(LocalDateTime(year: 2025, month: 11, day: 2, hour: 1, minute: 59, second: 59)),
                       .ambiguous(earlier: Fixtures.date("2025-11-02T05:59:59Z"), later: Fixtures.date("2025-11-02T06:59:59Z")))
        XCTAssertEqual(resolver.resolve(LocalDateTime(year: 2025, month: 11, day: 2, hour: 2, minute: 0, second: 0)),
                       .unique(Fixtures.date("2025-11-02T07:00:00Z")))
        XCTAssertEqual(resolver.resolve(LocalDateTime(year: 2026, month: 3, day: 8, hour: 2, minute: 0, second: 0)), .nonexistent)
        XCTAssertEqual(resolver.resolve(LocalDateTime(year: 2026, month: 3, day: 8, hour: 2, minute: 59, second: 59)), .nonexistent)
        XCTAssertEqual(resolver.resolve(LocalDateTime(year: 2026, month: 3, day: 8, hour: 3, minute: 0, second: 0)),
                       .unique(Fixtures.date("2026-03-08T07:00:00Z")))
        XCTAssertEqual(resolver.resolve(LocalDateTime(year: 2026, month: 2, day: 29, hour: 0, minute: 0, second: 0)), .invalid)
        XCTAssertEqual(resolver.resolve(LocalDateTime(year: 2028, month: 2, day: 29, hour: 0, minute: 0, second: 0)),
                       .unique(Fixtures.date("2028-02-29T05:00:00Z")))
    }

    func test_zoneWithoutDST() {
        let resolver = LocalTimeResolver(timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertEqual(resolver.resolve(LocalDateTime(year: 2025, month: 11, day: 2, hour: 1, minute: 30, second: 0)),
                       .unique(Fixtures.date("2025-11-01T16:30:00Z")))
    }

    func test_parsesClarityTimestampFormats() {
        XCTAssertEqual(LocalDateTime(clarityTimestamp: "2025-11-02T01:30:00"), LocalDateTime(year: 2025, month: 11, day: 2, hour: 1, minute: 30, second: 0))
        XCTAssertEqual(LocalDateTime(clarityTimestamp: " 2025-11-02 01:30:05 "), LocalDateTime(year: 2025, month: 11, day: 2, hour: 1, minute: 30, second: 5))
        XCTAssertNil(LocalDateTime(clarityTimestamp: "2025-11-02T01:30"))
        XCTAssertNil(LocalDateTime(clarityTimestamp: "2025-11-02T01:30:00Z"))
        XCTAssertNil(LocalDateTime(clarityTimestamp: "2025-1a-02T01:30:00"))
    }
}
