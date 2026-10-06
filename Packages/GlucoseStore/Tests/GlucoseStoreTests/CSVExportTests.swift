import GlucoseCore
import XCTest
@testable import GlucoseStore

/// Golden test for "Export all data (CSV)". The format is documented in CSVExport.swift and
/// docs/storage.md; any change to it must change this file on purpose.
final class CSVExportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func test_exportMatchesGoldenFile() async throws {
        let store = try GlucoseStore.productionInMemory(now: testClock)
        _ = try await store.insert([
            sensorReading(at: 0, .mgdl(112), trendRate: 0.2),
            sensorReading(at: 300, .belowRange, trendRate: nil),
            sensorReading(at: 600, .aboveRange, trendRate: nil, isBackfill: true),
            importedReading(at: -86_400, .mgdl(95), origin: .nightscout),
            importedReading(at: -86_100, .belowRange, origin: .clarityCSV),
            GlucoseReading(
                id: "3M,99:900", date: referenceInstant.addingTimeInterval(900.1234), value: .mgdl(101),
                trendRate: -1.5, isBackfill: false, source: .sensor, sensorSerial: "3M,99"
            ),
            GlucoseReading(
                id: "Q:1", date: referenceInstant.addingTimeInterval(1_200.9996), value: .mgdl(250),
                trendRate: 3.25, isBackfill: false, source: .sensor, sensorSerial: "Q\"uote"
            ),
        ])
        let url = directory.appendingPathComponent("export.csv")

        let count = try await store.exportCSV(to: url)

        XCTAssertEqual(count, 7)
        let golden = """
            date_utc,glucose_mgdl,trend_mgdl_per_min,is_backfill,source,import_origin,sensor_serial,id
            2026-01-14T12:00:00.000Z,95,,false,imported,nightscout,,imported:nightscout:1768392000000
            2026-01-14T12:05:00.000Z,LOW,,false,imported,clarityCSV,,imported:clarityCSV:1768392300000
            2026-01-15T12:00:00.000Z,112,0.2,false,sensor,,3M1234,3M1234:0
            2026-01-15T12:05:00.000Z,LOW,,false,sensor,,3M1234,3M1234:300
            2026-01-15T12:10:00.000Z,HIGH,,true,sensor,,3M1234,3M1234:600
            2026-01-15T12:15:00.123Z,101,-1.5,false,sensor,,"3M,99","3M,99:900"
            2026-01-15T12:20:01.000Z,250,3.25,false,sensor,,"Q""uote",Q:1

            """
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), golden)
    }

    #if DEBUG
    func test_replayStoreExportNamesReplayAndMockSources() async throws {
        let store = try GlucoseStore.replay(now: testClock)
        _ = try await store.insert([replayReading(at: 0, .belowRange), replayReading(at: 300, .mgdl(99), source: .mock)])
        let url = directory.appendingPathComponent("replay.csv")
        try await store.exportCSV(to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), """
            date_utc,glucose_mgdl,trend_mgdl_per_min,is_backfill,source,import_origin,sensor_serial,id
            2026-01-15T12:00:00.000Z,LOW,,false,replay,,REPLAY-TEST,REPLAY-TEST:0
            2026-01-15T12:05:00.000Z,99,,false,mock,,REPLAY-TEST,REPLAY-TEST:300

            """)
    }
    #endif

    func test_emptyStoreExportsTheHeaderOnly() async throws {
        let store = try GlucoseStore.productionInMemory(now: testClock)
        let url = directory.appendingPathComponent("empty.csv")
        let count = try await store.exportCSV(to: url)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), CSVExport.header + "\n")
    }

    func test_exportReplacesAnExistingFileAndLeavesNoPartialFile() async throws {
        let store = try GlucoseStore.productionInMemory(now: testClock)
        _ = try await store.insert([sensorReading(at: 0)])
        let url = directory.appendingPathComponent("export.csv")
        try Data("old content".utf8).write(to: url)

        try await store.exportCSV(to: url)

        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasPrefix(CSVExport.header))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["export.csv"])
    }

    func test_exportStreamsLargeTablesInChunks() async throws {
        // More than one 64 KB chunk: 3 000 lines of ~60 bytes.
        let store = try GlucoseStore.productionInMemory(now: testClock)
        _ = try await store.insert((0..<3_000).map { sensorReading(at: TimeInterval($0) * 300) })
        let url = directory.appendingPathComponent("big.csv")
        let count = try await store.exportCSV(to: url)
        XCTAssertEqual(count, 3_000)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 3_001)
        XCTAssertEqual(lines.last, "2026-01-25T21:55:00.000Z,110,0.2,false,sensor,,3M1234,3M1234:899700")
    }

    func test_utcTimestampFormatting() {
        XCTAssertEqual(CSVExport.utcTimestamp(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(CSVExport.utcTimestamp(Date(timeIntervalSince1970: -0.5)), "1969-12-31T23:59:59.500Z")
        XCTAssertEqual(CSVExport.utcTimestamp(Date(timeIntervalSince1970: 1_768_478_400.999_6)), "2026-01-15T12:00:01.000Z")
    }

    func test_quotingFollowsRFC4180() {
        XCTAssertEqual(CSVExport.quoted("plain"), "plain")
        XCTAssertEqual(CSVExport.quoted("a,b"), "\"a,b\"")
        XCTAssertEqual(CSVExport.quoted("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CSVExport.quoted("two\nlines"), "\"two\nlines\"")
    }
}
