// Original to Sensor (no ported code).
import XCTest
import GlucoseCore
@testable import NightscoutKit

/// Dexcom Clarity CSV import (HANDOFF §4.5 steps 2–5). `clarity_export_synthetic.csv` follows the
/// real export layout (BOM, CRLF, 14-column header, metadata rows, Calibration/Insulin/Carbs
/// events, "Low"/"High" EGVs) with synthetic data recorded in America/New_York across the
/// 2025-11-02 fall-back.
final class ClarityImportTests: XCTestCase {
    static let newYork = TimeZone(identifier: "America/New_York")!
    /// Import time for parser tests: after every fixture date.
    static let now = Fixtures.date("2026-09-23T00:00:00Z")

    private func parseFixture() throws -> ClarityParseResult {
        try ClarityExportParser.parse(Fixtures.data("clarity_export_synthetic.csv"), timeZone: Self.newYork, now: ClarityImportTests.now)
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
        let result = try ClarityExportParser.parse(export([("2026-01-10T10:00:00", "39", ""), ("2026-01-10T10:05:00", "401", ""), ("2026-01-10T10:10:00", "120", "")]), timeZone: Self.newYork, now: ClarityImportTests.now)
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

        // The same with nothing between the two passes: the transmitter clock decides, measured
        // from the 00:55 row (86400 s) — 01:30 EDT at +2100 s, 01:30 EST at +5700 s.
        let adjacent = try ClarityExportParser.parse(export([
            ("2025-11-02T00:55:00", "117", "86400"),
            ("2025-11-02T01:30:00", "108", "88500"),
            ("2025-11-02T01:30:00", "99", "92100"),
        ]), timeZone: Self.newYork, now: ClarityImportTests.now)
        XCTAssertEqual(adjacent.readings.map(\.date), [
            Fixtures.date("2025-11-02T04:55:00Z"), Fixtures.date("2025-11-02T05:30:00Z"), Fixtures.date("2025-11-02T06:30:00Z"),
        ])
        XCTAssertEqual(Set(adjacent.readings.map(\.id)).count, 3)
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
        ]), timeZone: Self.newYork, now: ClarityImportTests.now)
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
        ]), timeZone: Self.newYork, now: ClarityImportTests.now)
        XCTAssertEqual(result.readings.map(\.date), [Fixtures.date("2025-11-02T06:30:00Z"), Fixtures.date("2025-11-02T07:00:00Z")])
    }

    func test_S3_clarityTransmitterTimeThatMatchesNeitherPassIsRejected() throws {
        // Transmitter clock says 01:40 EDT-equivalent (05:40Z) for a row stamped 01:30: neither
        // 05:30Z nor 06:30Z is within 60 s, so the row is rejected rather than guessed.
        let result = try ClarityExportParser.parse(export(rows: [
            ("2025-11-02T00:55:00", "120", "700", "SYNTH1"),
            ("2025-11-02T01:30:00", "110", "3400", "SYNTH1"),
        ]), timeZone: Self.newYork, now: ClarityImportTests.now)
        XCTAssertEqual(result.readings.map(\.value), [.mgdl(120)])
        XCTAssertEqual(result.rejectedAmbiguousLocalTime, 1)
    }

    func test_S3_clarityTransmitterTimeWithoutComparableAnchorIsRejected() throws {
        // Reviewer n2: the old sensor (SYNTH1) stops at 00:55 EDT; a new sensor (OTHER2) starts
        // during the second pass (01:00/01:05 EST = 06:00Z/06:05Z) and its only rows sit inside
        // the repeated hour. File order would place them at 05:00Z/05:05Z — five minutes after the
        // previous row, so no gap check helps — an hour early. Its clock cannot be tied to an
        // instant (SYNTH1's clock is not comparable), so the rows are rejected and counted.
        let result = try ClarityExportParser.parse(export(rows: [
            ("2025-11-02T00:55:00", "104", "86400", "SYNTH1"),
            ("2025-11-02T01:00:00", "103", "300", "OTHER2"),
            ("2025-11-02T01:05:00", "101", "600", "OTHER2"),
        ]), timeZone: Self.newYork, now: ClarityImportTests.now)
        XCTAssertEqual(result.readings.map(\.date), [Fixtures.date("2025-11-02T04:55:00Z")])
        XCTAssertEqual(result.rejectedAmbiguousLocalTime, 2)
    }

    func test_S3_clarityAmbiguousRowWithoutTransmitterTimeIsRejected() throws {
        // Review n4: without a transmitter time, nothing in the file places a repeated-hour row, so
        // every such row is rejected and counted; rows outside the hour are unaffected.

        // Continuous 5-minute data through both passes: all 12 + 3 repeated-hour rows rejected.
        var rows: [(String, String, String)] = [("2025-11-02T00:55:00", "120", "")]
        for minute in stride(from: 0, through: 55, by: 5) { rows.append((String(format: "2025-11-02T01:%02d:00", minute), "121", "")) }  // EDT
        for minute in stride(from: 0, through: 10, by: 5) { rows.append((String(format: "2025-11-02T01:%02d:00", minute), "122", "")) }  // EST
        rows.append(("2025-11-02T02:00:00", "123", ""))
        let continuous = try ClarityExportParser.parse(export(rows), timeZone: Self.newYork, now: ClarityImportTests.now)
        XCTAssertEqual(continuous.readings.map(\.date), [Fixtures.date("2025-11-02T04:55:00Z"), Fixtures.date("2025-11-02T07:00:00Z")])
        XCTAssertEqual(continuous.rejectedAmbiguousLocalTime, 15)

        // Gap straddling the transition: the last first-pass reading is 01:20 EDT (05:20Z); the next
        // is really 01:25 EST (06:25Z), 65 min later. File order would put it at 05:25Z — five
        // minutes on, an hour early. Rejected instead.
        let straddling = try ClarityExportParser.parse(export([
            ("2025-11-02T00:55:00", "120", ""),
            ("2025-11-02T01:20:00", "110", ""),
            ("2025-11-02T01:25:00", "95", ""),
        ]), timeZone: Self.newYork, now: ClarityImportTests.now)
        XCTAssertEqual(straddling.readings.map(\.date), [Fixtures.date("2025-11-02T04:55:00Z")])
        XCTAssertEqual(straddling.rejectedAmbiguousLocalTime, 2)
        XCTAssertFalse(straddling.readings.contains { $0.date == Fixtures.date("2025-11-02T05:25:00Z") })

        // Interleaved passes (a file sorted by wall-clock time) and a non-chronological file.
        for order in [["01:00", "01:00", "01:05", "01:05"], ["01:30", "01:05", "01:40", "01:10"]] {
            let result = try ClarityExportParser.parse(export(
                [("2025-11-02T00:55:00", "120", "")] + order.map { ("2025-11-02T\($0):00", "121", "") }
            ), timeZone: Self.newYork, now: ClarityImportTests.now)
            XCTAssertEqual(result.readings.map(\.date), [Fixtures.date("2025-11-02T04:55:00Z")], "\(order)")
            XCTAssertEqual(result.rejectedAmbiguousLocalTime, 4, "\(order)")
        }

        // With a transmitter time and an anchor, the same rows are placed (control).
        let withClock = try ClarityExportParser.parse(export([
            ("2025-11-02T00:55:00", "120", "86400"),
            ("2025-11-02T01:20:00", "110", "87900"),
            ("2025-11-02T01:25:00", "95", "91800"),
        ]), timeZone: Self.newYork, now: ClarityImportTests.now)
        XCTAssertEqual(withClock.readings.map(\.date), [
            Fixtures.date("2025-11-02T04:55:00Z"), Fixtures.date("2025-11-02T05:20:00Z"), Fixtures.date("2025-11-02T06:25:00Z"),
        ])
    }

    func test_S3_clarityRepeatedRowWithoutEvidenceIsADuplicateNotANewReading() throws {
        // One reading listed twice must not become a second reading an hour later (S1).
        // With transmitter times: same clock value → same instant → duplicate id.
        let withClock = try ClarityExportParser.parse(export([
            ("2025-11-02T00:55:00", "117", "86400"),
            ("2025-11-02T01:30:00", "108", "88500"),
            ("2025-11-02T01:30:00", "108", "88500"),
        ]), timeZone: Self.newYork, now: ClarityImportTests.now)
        XCTAssertEqual(withClock.readings.map(\.date), [Fixtures.date("2025-11-02T04:55:00Z"), Fixtures.date("2025-11-02T05:30:00Z")])
        XCTAssertEqual(withClock.duplicateRows, 1)
    }

    func test_S3_clarityOutOfOrderAmbiguousTimeIsRejected() throws {
        // 03:00 EST, then a 01:30 (05:30Z or 06:30Z) with no transmitter time: rejected (n4).
        let result = try ClarityExportParser.parse(export([
            ("2025-11-02T03:00:00", "120", ""),
            ("2025-11-02T01:30:00", "118", ""),
        ]), timeZone: Self.newYork, now: ClarityImportTests.now)
        XCTAssertEqual(result.readings.map(\.date), [Fixtures.date("2025-11-02T08:00:00Z")])
        XCTAssertEqual(result.rejectedAmbiguousLocalTime, 1)
    }

    func test_S3_claritySpringForwardNonexistentTimeRejected() throws {
        // 2026-03-08 America/New_York: 02:00 EST jumps to 03:00 EDT; 02:30 never happened.
        let result = try ClarityExportParser.parse(export([
            ("2026-03-08T01:55:00", "130", ""),
            ("2026-03-08T02:30:00", "128", ""),
            ("2026-03-08T03:00:00", "126", ""),
        ]), timeZone: Self.newYork, now: ClarityImportTests.now)
        XCTAssertEqual(result.readings.map(\.date), [Fixtures.date("2026-03-08T06:55:00Z"), Fixtures.date("2026-03-08T07:00:00Z")])
        XCTAssertEqual(result.rejectedNonexistentLocalTime, 1)
    }

    func test_S3_clarityDSTInAnotherTimeZone() throws {
        // Europe/London 2025-10-26: 01:00–01:59 happens as BST (UTC+1) then GMT (UTC+0). Transmitter
        // times (seconds from the 00:55 row) place the ambiguous rows.
        let london = TimeZone(identifier: "Europe/London")!
        let result = try ClarityExportParser.parse(export([
            ("2025-10-26T00:55:00", "100", "1000"),
            ("2025-10-26T01:30:00", "101", "3100"),   // +35 min → 00:30Z (BST)
            ("2025-10-26T01:10:00", "102", "5500"),   // +75 min → 01:10Z (GMT)
            ("2025-10-26T02:00:00", "103", "8500"),
        ]), timeZone: london, now: ClarityImportTests.now)
        XCTAssertEqual(result.readings.map(\.date), [
            Fixtures.date("2025-10-25T23:55:00Z"), Fixtures.date("2025-10-26T00:30:00Z"),
            Fixtures.date("2025-10-26T01:10:00Z"), Fixtures.date("2025-10-26T02:00:00Z"),
        ])
    }

    func test_timestampsUseTheCallerSuppliedTimeZone() throws {
        let data = export([("2026-01-10T10:00:00", "120", "")])
        let utc = try ClarityExportParser.parse(data, timeZone: TimeZone(identifier: "UTC")!, now: ClarityImportTests.now)
        let tokyo = try ClarityExportParser.parse(data, timeZone: TimeZone(identifier: "Asia/Tokyo")!, now: ClarityImportTests.now)
        XCTAssertEqual(utc.readings.first?.date, Fixtures.date("2026-01-10T10:00:00Z"))
        XCTAssertEqual(tokyo.readings.first?.date, Fixtures.date("2026-01-10T01:00:00Z"))
    }

    func test_invalidTimestampsAreCounted() throws {
        let result = try ClarityExportParser.parse(export([
            ("", "120", ""), ("2026-02-30T10:00:00", "120", ""), ("2026-01-10 25:00:00", "120", ""),
            ("10/01/2026 10:00", "120", ""), ("2026-01-10 10:05:00", "121", ""),
        ]), timeZone: Self.newYork, now: ClarityImportTests.now)
        XCTAssertEqual(result.rejectedInvalidTimestamp, 4)
        XCTAssertEqual(result.readings.count, 1, "older exports use a space instead of T")
    }

    func test_refusesMmolExportsAndOtherFiles() {
        let mmol = export([("2026-01-10T10:00:00", "6.7", "")], header: "Index,Timestamp (YYYY-MM-DDThh:mm:ss),Event Type,Event Subtype,Patient Info,Device Info,Source Device ID,Glucose Value (mmol/L),Insulin Value (u),Carb Value (grams),Duration (hh:mm:ss),Glucose Rate of Change (mmol/L/min),Transmitter Time (Long Integer),Transmitter ID")
        XCTAssertThrowsError(try ClarityExportParser.parse(mmol, timeZone: Self.newYork, now: ClarityImportTests.now)) { error in
            XCTAssertEqual(error as? ClarityImportError, .unsupportedUnit("Glucose Value (mmol/L)"))
        }
        XCTAssertThrowsError(try ClarityExportParser.parse(Data("date,value\n2026-01-10,120\n".utf8), now: ClarityImportTests.now)) { error in
            XCTAssertEqual(error as? ClarityImportError, .notAClarityExport)
        }
        XCTAssertThrowsError(try ClarityExportParser.parse(Data([0xFF, 0xFE, 0x00]), now: ClarityImportTests.now)) { error in
            XCTAssertEqual(error as? ClarityImportError, .notUTF8)
        }
        XCTAssertThrowsError(try ClarityExportParser.parse(Data("Index,Event Type,Glucose Value (mg/dL)\n".utf8), now: ClarityImportTests.now)) { error in
            XCTAssertEqual(error as? ClarityImportError, .missingColumn("Timestamp (YYYY-MM-DDThh:mm:ss)"))
        }
    }

    func test_S3_futureDatedImportRowsAreSkippedNotStalling() async throws {
        // D33: a row later than now + 60 s (wrong time zone picked, device clock fault) would make
        // the store reject the whole batch; it is skipped and counted, the rest imports. A
        // non-finite rate becomes nil rather than reaching the store.
        let clock = TestClock(Fixtures.date("2026-01-10T15:10:00Z"))
        let repository = InMemoryGlucoseReadingRepository(clock: clock)
        let data = Data([
            "Index,Timestamp (YYYY-MM-DDThh:mm:ss),Event Type,Event Subtype,Patient Info,Device Info,Source Device ID,Glucose Value (mg/dL),Insulin Value (u),Carb Value (grams),Duration (hh:mm:ss),Glucose Rate of Change (mg/dL/min),Transmitter Time (Long Integer),Transmitter ID",
            "1,2026-01-10T10:00:00,EGV,,,,iOS G7,120,,,,NaN,1000,SYNTH1",      // 15:00Z, rate NaN → nil
            "2,2026-01-10T10:05:00,EGV,,,,iOS G7,121,,,,inf,1300,SYNTH1",      // 15:05Z, rate ∞ → nil
            "3,2026-01-10T10:11:00,EGV,,,,iOS G7,122,,,,,1660,SYNTH1",         // 15:11Z, within 60 s
            "4,2026-01-10T10:15:00,EGV,,,,iOS G7,123,,,,,1900,SYNTH1",         // 15:15Z, future
            "5,2026-01-10T11:00:00,EGV,,,,iOS G7,124,,,,,4600,SYNTH1",         // 16:00Z, future
        ].joined(separator: "\r\n").utf8)
        let result = try await ClarityHistoryImporter(repository: repository, clock: clock).importExport(data, timeZone: Self.newYork)
        XCTAssertEqual(result.parse.rejectedFutureDated, 2)
        XCTAssertEqual(result.readingsImported, 3, "one bad row does not stall the import")
        let stored = await repository.stored
        XCTAssertEqual(stored.map(\.value), [.mgdl(120), .mgdl(121), .mgdl(122)])
        XCTAssertTrue(stored.allSatisfy { $0.trendRate == nil })
    }

    func test_clarityMalformedNumbersDoNotTrap() throws {
        // Audit m6: absurd numbers in the value, rate and transmitter-time columns fail closed.
        let result = try ClarityExportParser.parse(export(rows: [
            ("2025-11-02T00:55:00", "1e300", "1e300", "SYNTH1"),     // value rejected
            ("2025-11-02T00:56:00", "120", "-1e300", "SYNTH1"),      // placed (outside the repeated hour)
            ("2025-11-02T01:30:00", "121", "1e300", "SYNTH1"),       // clock gap of ~1e300 s: neither pass matches
            ("2025-11-02T01:35:00", "122", "NaN", "SYNTH1"),         // no usable transmitter time
            ("2025-11-02T01:40:00", "123", "-inf", "SYNTH1"),
        ]), timeZone: Self.newYork, now: ClarityImportTests.now)
        XCTAssertEqual(result.readings.map(\.value), [.mgdl(120)])
        XCTAssertEqual(result.rejectedInvalidValue, 1)
        XCTAssertEqual(result.rejectedAmbiguousLocalTime, 3)
        let rate = try ClarityExportParser.parse(Data([
            "Index,Timestamp (YYYY-MM-DDThh:mm:ss),Event Type,Glucose Value (mg/dL),Glucose Rate of Change (mg/dL/min)",
            "1,2026-01-10T10:00:00,EGV,120,1e999",
            "2,2026-01-10T10:05:00,EGV,121,-1e300",
        ].joined(separator: "\n").utf8), timeZone: Self.newYork, now: ClarityImportTests.now)
        XCTAssertEqual(rate.readings.count, 2)
        XCTAssertNil(rate.readings.first?.trendRate, "1e999 overflows to +inf: not finite → nil")
        XCTAssertTrue(rate.readings.allSatisfy { $0.trendRate.map(\.isFinite) ?? true })
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
        let result = try ClarityExportParser.parse(data, timeZone: TimeZone(identifier: "UTC")!, now: ClarityImportTests.now)
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
