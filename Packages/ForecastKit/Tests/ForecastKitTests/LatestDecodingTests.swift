// Original to Sensor (no ported code).
import XCTest
@testable import ForecastKit

/// latest.json documents that must be accepted, and what they decode to.
final class LatestDecodingTests: XCTestCase {
    private let now = FeedFixtures.now

    private func decode(_ object: [String: Any], at instant: ForecastInstant = FeedFixtures.nowInstant) throws -> LatestForecast {
        try ForecastFeedDecoder.decodeLatest(FeedFixtures.json(object), at: instant)
    }

    private func values(_ points: [ForecastPoint]?) -> [ForecastHorizon: Double] {
        Dictionary(uniqueKeysWithValues: (points ?? []).map { ($0.horizon, $0.predictedMgdl) })
    }

    // MARK: - Fixture documents

    func testSiteFixture() throws {
        // zen-predict-infra site/fixtures/latest.json: integers, "Z" timestamps.
        let asOf = Date(timeIntervalSince1970: 1_785_499_380)  // 2026-07-31T12:03:00Z
        let latest = try ForecastFeedDecoder.decodeLatest(try FeedFixtures.data("site_latest"), at: FeedFixtures.instant(asOf.addingTimeInterval(60)))

        XCTAssertEqual(latest.asOf, asOf)
        let zen = try XCTUnwrap(latest.zen)
        XCTAssertEqual(zen.generatedAt, asOf)
        XCTAssertEqual(zen.points.map(\.horizon), ForecastHorizon.allCases)
        XCTAssertEqual(values(zen.points), [.fiveMinutes: 138, .thirtyMinutes: 132, .oneHour: 126, .twoHours: 122])
        XCTAssertEqual(values(latest.oref?.points), [.fiveMinutes: 137, .thirtyMinutes: 129, .oneHour: 124, .twoHours: 108])
        XCTAssertEqual(latest.feedGlucose, FeedGlucose(date: asOf, value: .mgdl(139), trend: "SingleDown"))
        XCTAssertEqual(latest.modelVersion, "20260731T120000-ab12cd34")
    }

    func testLiveFormat() throws {
        // 6-digit fractions, "+00:00", two-decimal values; the run is the reading itself (same instant).
        let generatedAt = 1_791_469_205.112233   // 2026-10-08T14:20:05.112233Z
        let arrived = FeedFixtures.instant(FeedFixtures.october8(14, 21))
        let latest = try ForecastFeedDecoder.decodeLatest(try FeedFixtures.data("synthetic_latest_live_format"), at: arrived)

        XCTAssertEqual(latest.asOf.timeIntervalSince1970, 1_791_469_241.507318, accuracy: 1e-6)
        let zen = try XCTUnwrap(latest.zen)
        XCTAssertEqual(zen.generatedAt.timeIntervalSince1970, generatedAt, accuracy: 1e-6)
        XCTAssertEqual(values(zen.points), [.fiveMinutes: 110.42, .thirtyMinutes: 127.06, .oneHour: 141.93, .twoHours: 152.37])
        XCTAssertEqual(values(latest.oref?.points), [.fiveMinutes: 111, .thirtyMinutes: 129, .oneHour: 146.5, .twoHours: 160])
        let feedGlucose = try XCTUnwrap(latest.feedGlucose)
        XCTAssertEqual(feedGlucose.value, .mgdl(108))
        XCTAssertEqual(feedGlucose.trend, "FortyFiveUp")
        XCTAssertEqual(feedGlucose.date.timeIntervalSince1970, generatedAt, accuracy: 1e-6)
        XCTAssertEqual(latest.modelVersion, FeedFixtures.modelVersion)
        XCTAssertEqual(latest.receivedAt, arrived, "stamped with the instant it arrived")
        // 14:21:00 − 14:20:05.112233 = 54.887767 s.
        guard case .current(let age) = latest.zenFreshness(at: arrived) else {
            return XCTFail("a 55-second-old run must be current")
        }
        XCTAssertEqual(age, 54.887767, accuracy: 1e-6)
    }

    func testLiveFormatWhereTheRunLagsTheNewestReading() throws {
        // Before zen-predict-infra 3f3d682 made predict trigger publish, publish could carry a newer
        // reading than the newest run: here the reading is 14:30:06, the run 14:25:05.
        let arrived = FeedFixtures.instant(FeedFixtures.october8(14, 33))
        let latest = try ForecastFeedDecoder.decodeLatest(try FeedFixtures.data("synthetic_latest_lagging_run"), at: arrived)
        let zen = try XCTUnwrap(latest.zen)
        XCTAssertEqual(zen.generatedAt.timeIntervalSince1970, 1_791_469_505.990001, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(latest.feedGlucose).date.timeIntervalSince1970, 1_791_469_806.004512, accuracy: 1e-6)
        XCTAssertEqual(latest.asOf.timeIntervalSince1970, 1_791_469_842.250731, accuracy: 1e-6)
        XCTAssertEqual(values(zen.points), [.fiveMinutes: 158.66, .thirtyMinutes: 171.2, .oneHour: 179.08, .twoHours: 176.45])
        XCTAssertEqual(latest.oref?.point(at: .twoHours)?.predictedMgdl, 194.5)
        XCTAssertEqual(latest.feedGlucose?.value, .mgdl(163))
        // 14:33:00 − 14:25:05.990001 = 474.009999 s: still current.
        XCTAssertEqual(try XCTUnwrap(latest.zenRunAge(at: arrived)), 474.009999, accuracy: 1e-6)
        XCTAssertNotNil(latest.currentRun(at: arrived))
    }

    // MARK: - Nulls mean "not published"

    func testNullHorizonIsNoPoint() throws {
        let object = FeedFixtures.setting(["predictions", "zen"], to: ["5": NSNull(), "30": 127.06, "60": NSNull(), "120": 152.37], in: FeedFixtures.latestObject())
        let zen = try XCTUnwrap(try decode(object).zen)
        XCTAssertEqual(zen.points.map(\.horizon), [.thirtyMinutes, .twoHours])
        XCTAssertNil(zen.point(at: .fiveMinutes))
        XCTAssertNil(zen.point(at: .oneHour))
        XCTAssertEqual(zen.point(at: .thirtyMinutes)?.predictedMgdl, 127.06)
    }

    func testMissingHorizonKeyIsNoPoint() throws {
        let object = FeedFixtures.setting(["predictions", "zen"], to: ["120": 152.37], in: FeedFixtures.latestObject())
        let zen = try XCTUnwrap(try decode(object).zen)
        XCTAssertEqual(zen.points, [ForecastPoint(horizon: .twoHours, predictedMgdl: 152.37)])
    }

    func testNullZenIsNoForecastYet() throws {
        XCTAssertNil(try decode(FeedFixtures.setting(["predictions", "zen"], to: NSNull(), in: FeedFixtures.latestObject())).zen)
    }

    func testAllNullZenIsNoForecastYet() throws {
        let allNull: [String: Any] = ["5": NSNull(), "30": NSNull(), "60": NSNull(), "120": NSNull()]
        XCTAssertNil(try decode(FeedFixtures.setting(["predictions", "zen"], to: allNull, in: FeedFixtures.latestObject())).zen)
    }

    func testProducersEmptyDocumentIsValid() throws {
        // What publish.py `build_latest` + `filter_doc` write before the first run and without a
        // Nightscout reading: every leaf null, oref null as a whole.
        let object: [String: Any] = [
            "as_of": FeedFixtures.pythonISO(now.addingTimeInterval(-10)),
            "bg": NSNull(),
            "predictions": [
                "generated_at": NSNull(),
                "zen": ["5": NSNull(), "30": NSNull(), "60": NSNull(), "120": NSNull()],
                "oref": NSNull(),
            ] as [String: Any],
            "model_version": NSNull(),
        ]
        let latest = try decode(object)
        XCTAssertNil(latest.zen)
        XCTAssertNil(latest.oref)
        XCTAssertNil(latest.feedGlucose)
        XCTAssertNil(latest.modelVersion)
    }

    func testOnlyAsOfIsRequired() throws {
        let latest = try decode(["as_of": FeedFixtures.pythonISO(now)])
        XCTAssertNil(latest.zen)
        XCTAssertNil(latest.oref)
        XCTAssertNil(latest.feedGlucose)
        XCTAssertNil(latest.modelVersion)
    }

    func testNullPredictionsIsNoForecast() throws {
        let latest = try decode(FeedFixtures.setting(["predictions"], to: NSNull(), in: FeedFixtures.latestObject()))
        XCTAssertNil(latest.zen)
        XCTAssertNil(latest.oref)
    }

    func testNullOrefWithAZenRun() throws {
        let latest = try decode(FeedFixtures.setting(["predictions", "oref"], to: NSNull(), in: FeedFixtures.latestObject()))
        XCTAssertNotNil(latest.zen)
        XCTAssertNil(latest.oref)
    }

    func testAllNullOrefIsNoOref() throws {
        let allNull: [String: Any] = ["5": NSNull(), "30": NSNull(), "60": NSNull(), "120": NSNull()]
        XCTAssertNil(try decode(FeedFixtures.setting(["predictions", "oref"], to: allNull, in: FeedFixtures.latestObject())).oref)
    }

    func testPartialOref() throws {
        let object = FeedFixtures.setting(["predictions", "oref"], to: ["5": 111, "30": NSNull(), "60": NSNull(), "120": NSNull()], in: FeedFixtures.latestObject())
        let oref = try XCTUnwrap(try decode(object).oref)
        XCTAssertEqual(oref.points, [ForecastPoint(horizon: .fiveMinutes, predictedMgdl: 111)])
        XCTAssertNil(oref.point(at: .thirtyMinutes))
    }

    func testOrefWithoutAZenRun() throws {
        // oref has its own runs; a feed can carry oref values before any Zen run exists.
        var object = FeedFixtures.setting(["predictions", "generated_at"], to: NSNull(), in: FeedFixtures.latestObject())
        object = FeedFixtures.setting(["predictions", "zen"], to: NSNull(), in: object)
        let latest = try decode(object)
        XCTAssertNil(latest.zen)
        XCTAssertEqual(latest.oref?.points.count, 4)
    }

    func testGeneratedAtWithoutValuesIsNoForecast() throws {
        XCTAssertNil(try decode(FeedFixtures.setting(["predictions", "zen"], to: [String: Any](), in: FeedFixtures.latestObject())).zen)
    }

    func testNullBGIsNoFeedGlucose() throws {
        XCTAssertNil(try decode(FeedFixtures.setting(["bg"], to: NSNull(), in: FeedFixtures.latestObject())).feedGlucose)
        let allNull: [String: Any] = ["ts": NSNull(), "mg_dl": NSNull(), "trend": NSNull()]
        XCTAssertNil(try decode(FeedFixtures.setting(["bg"], to: allNull, in: FeedFixtures.latestObject())).feedGlucose)
    }

    func testBGTimeWithoutValueIsNoFeedGlucose() throws {
        XCTAssertNil(try decode(FeedFixtures.setting(["bg", "mg_dl"], to: NSNull(), in: FeedFixtures.latestObject())).feedGlucose)
    }

    func testNullTrend() throws {
        let latest = try decode(FeedFixtures.setting(["bg", "trend"], to: NSNull(), in: FeedFixtures.latestObject()))
        XCTAssertEqual(latest.feedGlucose?.value, .mgdl(108))
        XCTAssertNil(latest.feedGlucose?.trend)
    }

    func testCurrentRunWithoutAnyRun() throws {
        let latest = try decode(FeedFixtures.setting(["predictions", "zen"], to: NSNull(), in: FeedFixtures.latestObject()))
        XCTAssertNil(latest.currentRun(at: FeedFixtures.nowInstant))
    }

    func testNullModelVersion() throws {
        let latest = try decode(FeedFixtures.setting(["model_version"], to: NSNull(), in: FeedFixtures.latestObject()))
        XCTAssertNotNil(latest.zen)
        XCTAssertNil(latest.modelVersion)
    }

    // MARK: - Forward compatibility

    func testUnknownKeysAreIgnored() throws {
        var object = FeedFixtures.latestObject()
        object["intervals"] = ["30": [100, 130]]
        object["schema"] = 2
        object = FeedFixtures.setting(["bg", "noise"], to: "light", in: object)
        object = FeedFixtures.setting(["predictions", "zen", "240"], to: 99_999, in: object)  // a future horizon
        object = FeedFixtures.setting(["predictions", "oref_generated_at"], to: "not read", in: object)
        let latest = try decode(object)
        XCTAssertEqual(latest, try decode(FeedFixtures.latestObject()))
    }

    // MARK: - Derived values

    func testTargetDatesAreGeneratedAtPlusHorizon() throws {
        let zen = try XCTUnwrap(try decode(FeedFixtures.latestObject()).zen)
        let generatedAt = now.addingTimeInterval(-120)
        XCTAssertEqual(zen.generatedAt, generatedAt)
        XCTAssertEqual(zen.targetDate(for: .fiveMinutes), generatedAt.addingTimeInterval(5 * 60))
        XCTAssertEqual(zen.targetDate(for: .thirtyMinutes), generatedAt.addingTimeInterval(30 * 60))
        XCTAssertEqual(zen.targetDate(for: .oneHour), generatedAt.addingTimeInterval(60 * 60))
        XCTAssertEqual(zen.targetDate(for: .twoHours), generatedAt.addingTimeInterval(120 * 60))
    }

    func testHorizons() {
        XCTAssertEqual(ForecastHorizon.allCases.map(\.minutes), [5, 30, 60, 120])
        XCTAssertEqual(ForecastHorizon.allCases.map(\.feedKey), ["5", "30", "60", "120"])
        XCTAssertEqual(ForecastHorizon.twoHours.interval, 7200)
        XCTAssertEqual(ForecastHorizon.allCases.sorted(by: >).first, .twoHours)
    }

    func testModelBoundEdges() {
        let cases: [(Double, ForecastModelBound)] = [
            (20, .atOrBelowFloor), (40, .atOrBelowFloor), (40.000001, .within), (110.42, .within),
            (399.999999, .within), (400, .atOrAboveCeiling), (600, .atOrAboveCeiling),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(ForecastPoint(horizon: .thirtyMinutes, predictedMgdl: value).modelBound, expected, "\(value)")
        }
    }

    func testFeedGlucoseClassification() throws {
        let cases: [(Double, FeedGlucoseValue)] = [
            (0, .notGlucose(code: 0)),
            (9, .notGlucose(code: 9)),       // Nightscout errorcodes.js: 9 = "?AD"
            (38, .notGlucose(code: 38)),
            (39, .belowRange),
            (39.5, .belowRange),
            (40, .mgdl(40)),
            (123.4, .mgdl(123)),
            (123.5, .mgdl(124)),
            (400, .mgdl(400)),
            (400.5, .aboveRange),
            (401, .aboveRange),
            (1000, .aboveRange),
        ]
        for (sgv, expected) in cases {
            let latest = try decode(FeedFixtures.setting(["bg", "mg_dl"], to: sgv, in: FeedFixtures.latestObject()))
            XCTAssertEqual(latest.feedGlucose?.value, expected, "mg_dl \(sgv)")
        }
    }
}
