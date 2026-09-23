// The bytes and the meaning of what the bridge writes (HANDOFF §8 step 4): a golden file, plus the
// same payload read back through the model of Trio's reader.

import Foundation
import GlucoseCore
import XCTest
@testable import TrioBridge

final class TrioPayloadContractTests: XCTestCase {
    /// Three readings covering a flat trend, a backfilled falling one, and one without a trend rate.
    private let fixtureReadings: [GlucoseReading] = [
        Fixture.reading(at: 7_200, value: .mgdl(112), rate: 0.3),
        Fixture.reading(at: 7_500, value: .mgdl(108), rate: -1.2, backfill: true),
        Fixture.reading(at: 7_800, value: .mgdl(101), rate: nil),
    ]

    private func goldenPayload() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "latestReadings.golden", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func writtenPayload() async throws -> Data {
        let store = InMemoryTrioStore()
        let bridge = TrioBridge(store: store, clock: { Fixture.time(7_800) })
        let result = await bridge.publish(fixtureReadings, session: Fixture.session)
        XCTAssertTrue(result.didWrite)
        return try XCTUnwrap(store.payload)
    }

    func test_goldenFile_fixtureReadingsEncodeToExactBytes() async throws {
        let written = try await writtenPayload()
        let golden = try goldenPayload()
        XCTAssertEqual(written, golden, """
            Payload differs from Fixtures/latestReadings.golden.json.
            written: \(String(decoding: written, as: UTF8.self))
            golden:  \(String(decoding: golden, as: UTF8.self))
            """)
    }

    func test_goldenFile_isWhatTrioReads() throws {
        // The golden file itself, through the model of Trio's reader: all three accepted, newest first,
        // values in mg/dL, timestamps to the millisecond, directions Trio can store.
        let (accepted, skipped) = try TrioReaderEmulation.read(goldenPayload())
        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(accepted, [
            TrioReaderEmulation.Element(mgdl: 101, date: Date(timeIntervalSince1970: 1_758_007_800.123), direction: "NOT COMPUTABLE"),
            TrioReaderEmulation.Element(mgdl: 108, date: Date(timeIntervalSince1970: 1_758_007_500.123), direction: "FortyFiveDown"),
            TrioReaderEmulation.Element(mgdl: 112, date: Date(timeIntervalSince1970: 1_758_007_200.123), direction: "Flat"),
        ])
        for element in accepted {
            XCTAssertTrue(TrioReaderEmulation.trioDirectionRawValues.contains(element.direction))
        }
    }

    func test_payloadShape_topLevelArrayOfFiveKeysWithoutFrom() throws {
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: goldenPayload()) as? [[String: Any]])
        for element in array {
            XCTAssertEqual(Set(element.keys), ["DT", "ST", "Trend", "Value", "direction"])
            XCTAssertNil(element["from"], "no \"from\": never claims to be xDrip4iOS, accepted by Trio")
            let dt = try XCTUnwrap(element["DT"] as? String)
            XCTAssertNotNil(dt.range(of: #"^/Date\(\d+\)/$"#, options: .regularExpression), "digits only, no offset: \(dt)")
            XCTAssertEqual(element["ST"] as? String, dt)
        }
    }

    func test_dateString_isMillisecondsSince1970() {
        XCTAssertEqual(TrioSharedReading.dexcomDateString(Date(timeIntervalSince1970: 0)), "/Date(0)/")
        XCTAssertEqual(TrioSharedReading.dexcomDateString(Date(timeIntervalSince1970: 1_758_007_200.1234)), "/Date(1758007200123)/")
        XCTAssertEqual(TrioSharedReading.dexcomDateString(Date(timeIntervalSince1970: 1_758_007_200.9996)), "/Date(1758007201000)/")
    }

    func test_trendMapping_everyArrowHasTrioDirectionAndDexcomShareOrdinal() throws {
        // Rate → (Trend ordinal, direction). Ordinals from share2nightscout-bridge index.js:57-68.
        let cases: [(Double?, Int, String)] = [
            (3.5, 1, "DoubleUp"), (2.5, 2, "SingleUp"), (1.5, 3, "FortyFiveUp"), (0.0, 4, "Flat"),
            (-1.5, 5, "FortyFiveDown"), (-2.5, 6, "SingleDown"), (-3.5, 7, "DoubleDown"), (nil, 8, "NOT COMPUTABLE"),
        ]
        for (rate, ordinal, direction) in cases {
            let element = TrioSharedReading(mgdl: 100, date: Fixture.time(3_600), trendRate: rate)
            XCTAssertEqual(element.trend, ordinal, "\(String(describing: rate))")
            XCTAssertEqual(element.direction, direction, "\(String(describing: rate))")
            XCTAssertTrue(TrioReaderEmulation.trioDirectionRawValues.contains(element.direction))
        }
        XCTAssertEqual(Set(TrendArrow.allCases.map(TrioSharedReading.dexcomShareTrend)).count, TrendArrow.allCases.count)
    }

    func test_readerModel_skipsWhatTrioSkipsAndFlagsWhatWouldCrashIt() throws {
        // Guards the test model itself against drifting from docs/trio-bridge.md.
        let json = #"""
        [{"DT":"/Date(1000)/","Value":100,"direction":"Flat"},
         {"DT":"/Date(2000)/","Value":100.5,"direction":"Flat"},
         {"DT":"/Date(3000)/","Value":100},
         {"DT":"/Date(4000)/","Value":100,"Trend":4},
         {"DT":"/Date(5000)/","Value":100,"direction":"Flat","from":"Other"},
         {"DT":"no parentheses","Value":100,"direction":"Flat"}]
        """#
        let (accepted, skipped) = try TrioReaderEmulation.read(Data(json.utf8))
        XCTAssertEqual(accepted.map(\.date.timeIntervalSince1970), [1, 4])
        XCTAssertEqual(accepted.map(\.direction), ["Flat", "Flat"])
        XCTAssertEqual(skipped, 4)
        XCTAssertThrowsError(try TrioReaderEmulation.read(Data(#"[{"DT":"/Date(1426292016000-0700)/","Value":100,"direction":"Flat"}]"#.utf8)))
        XCTAssertEqual(try TrioReaderEmulation.read(Data(#"{"recentReadings":[]}"#.utf8)).accepted, [])
    }
}
