// Original to Sensor (no ported code).
import XCTest
@testable import ForecastKit

/// metrics.json: accepted documents, nulls, and every rejection.
final class AccuracyDecodingTests: XCTestCase {
    private let now = FeedFixtures.now

    private func decode(_ object: [String: Any], at instant: ForecastInstant = FeedFixtures.nowInstant) throws -> ForecastAccuracy {
        try ForecastFeedDecoder.decodeAccuracy(FeedFixtures.json(object), at: instant)
    }

    private func with(_ path: [String], _ value: Any?) -> [String: Any] {
        FeedFixtures.setting(path, to: value, in: FeedFixtures.metricsObject())
    }

    private func assertRejected(_ object: [String: Any], _ expected: ForecastDocumentError, file: StaticString = #filePath, line: UInt = #line) {
        assertRejected(FeedFixtures.json(object), expected, file: file, line: line)
    }

    private func assertRejected(_ data: Data, _ expected: ForecastDocumentError, file: StaticString = #filePath, line: UInt = #line) {
        do {
            let accepted = try ForecastFeedDecoder.decodeAccuracy(data, at: FeedFixtures.nowInstant)
            XCTFail("accepted: \(accepted)", file: file, line: line)
        } catch {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    // MARK: - Fixture documents

    func testSiteFixture() throws {
        let asOf = Date(timeIntervalSince1970: 1_785_499_380)
        let accuracy = try ForecastFeedDecoder.decodeAccuracy(try FeedFixtures.data("site_metrics"), at: FeedFixtures.instant(asOf))
        XCTAssertEqual(accuracy.asOf, asOf)
        XCTAssertEqual(accuracy.modelVersion, "20260731T120000-ab12cd34")

        let week = try XCTUnwrap(accuracy.sevenDays)
        XCTAssertEqual(week.sampleCount, 1934)
        XCTAssertEqual(week.parkesABPercent, 99.4)
        XCTAssertEqual(week.accuracy(at: .fiveMinutes), HorizonAccuracy(meanAbsoluteError: 4.81, persistenceMeanAbsoluteError: 5.19, winRateVsOref: 0.571))
        XCTAssertEqual(week.accuracy(at: .twoHours), HorizonAccuracy(meanAbsoluteError: 34.07, persistenceMeanAbsoluteError: 39.62, winRateVsOref: 0.667))

        let month = try XCTUnwrap(accuracy.thirtyDays)
        XCTAssertEqual(month.sampleCount, 8207)
        XCTAssertEqual(month.parkesABPercent, 99.1)
        XCTAssertEqual(month.accuracy(at: .oneHour), HorizonAccuracy(meanAbsoluteError: 25.55, persistenceMeanAbsoluteError: 28.02, winRateVsOref: 0.627))

        XCTAssertEqual(ForecastHorizon.allCases.map { accuracy.typicalMiss(at: $0) }, [4.81, 16.12, 24.94, 34.07])
    }

    func testLiveFormat() throws {
        let arrived = FeedFixtures.instant(FeedFixtures.october8(14, 33))
        let accuracy = try ForecastFeedDecoder.decodeAccuracy(try FeedFixtures.data("synthetic_metrics_live_format"), at: arrived)
        XCTAssertEqual(accuracy.asOf.timeIntervalSince1970, 1_791_469_842.250731, accuracy: 1e-6)
        XCTAssertEqual(accuracy.modelVersion, FeedFixtures.modelVersion)
        XCTAssertEqual(ForecastHorizon.allCases.map { accuracy.typicalMiss(at: $0) }, [5.12, 16.4, 24.73, 31.86])
        XCTAssertEqual(accuracy.sevenDays?.sampleCount, 2016)
        XCTAssertEqual(accuracy.sevenDays?.parkesABPercent, 98.12)
        XCTAssertEqual(accuracy.thirtyDays?.sampleCount, 8640)
        XCTAssertEqual(accuracy.thirtyDays?.accuracy(at: .twoHours),
                       HorizonAccuracy(meanAbsoluteError: 34.4, persistenceMeanAbsoluteError: 40.27, winRateVsOref: 0.6104))
        XCTAssertEqual(accuracy.receivedAt, arrived)
    }

    // MARK: - Nulls

    func testEmptyWindowAsTheProducerWritesIt() throws {
        // publish.py `_window_stats` with no rollups: every horizon null, n 0, parkes null.
        let allNull: [String: Any] = ["5": NSNull(), "30": NSNull(), "60": NSNull(), "120": NSNull()]
        let empty: [String: Any] = ["mae": allNull, "persistence_mae": allNull, "win_rate_vs_oref": allNull, "n": 0, "parkes_ab_pct": NSNull()]
        let accuracy = try decode(with(["windows", "7d"], empty))
        let week = try XCTUnwrap(accuracy.sevenDays)
        XCTAssertEqual(week.sampleCount, 0)
        XCTAssertNil(week.parkesABPercent)
        for horizon in ForecastHorizon.allCases {
            XCTAssertEqual(week.accuracy(at: horizon), HorizonAccuracy(meanAbsoluteError: nil, persistenceMeanAbsoluteError: nil, winRateVsOref: nil))
            XCTAssertNil(accuracy.typicalMiss(at: horizon))
        }
        XCTAssertNotNil(accuracy.thirtyDays)
    }

    func testNullMapsAndScalars() throws {
        var object = with(["windows", "7d", "persistence_mae"], NSNull())
        object = FeedFixtures.setting(["windows", "7d", "win_rate_vs_oref", "30"], to: NSNull(), in: object)
        object = FeedFixtures.setting(["windows", "7d", "n"], to: NSNull(), in: object)
        let week = try XCTUnwrap(try decode(object).sevenDays)
        XCTAssertNil(week.sampleCount)
        XCTAssertNil(week.accuracy(at: .fiveMinutes).persistenceMeanAbsoluteError)
        XCTAssertEqual(week.accuracy(at: .fiveMinutes).meanAbsoluteError, 5.12)
        XCTAssertNil(week.accuracy(at: .thirtyMinutes).winRateVsOref)
        XCTAssertEqual(week.accuracy(at: .oneHour).winRateVsOref, 0.6081)
    }

    func testNullWindows() throws {
        let accuracy = try decode(with(["windows"], NSNull()))
        XCTAssertNil(accuracy.sevenDays)
        XCTAssertNil(accuracy.thirtyDays)
        XCTAssertNil(accuracy.typicalMiss(at: .thirtyMinutes))

        let noWeek = try decode(with(["windows", "7d"], NSNull()))
        XCTAssertNil(noWeek.sevenDays)
        XCTAssertNotNil(noWeek.thirtyDays)
        XCTAssertNil(noWeek.typicalMiss(at: .thirtyMinutes), "the typical miss is the 7-day MAE only")
    }

    func testNullModelVersionAndUnknownKeys() throws {
        var object = with(["model_version"], NSNull())
        object["windows"] = FeedFixtures.setting(["90d"], to: ["n": 1], in: object["windows"] as? [String: Any] ?? [:])
        object = FeedFixtures.setting(["windows", "7d", "rmse"], to: ["5": 6.1], in: object)
        let accuracy = try decode(object)
        XCTAssertNil(accuracy.modelVersion)
        XCTAssertEqual(accuracy.typicalMiss(at: .fiveMinutes), 5.12)
    }

    // MARK: - Rejections

    func testShapeAndTimestampRejections() {
        assertRejected(FeedFixtures.json("[]"), .notAJSONObject)
        assertRejected(FeedFixtures.json("{\"as_of\": \"2026-10-08T18:59:30+00:00\", \"windows\": {\"7d\": {\"n\": NaN}}}"), .notAJSONObject)
        assertRejected(with(["as_of"], NSNull()), .missingField("as_of"))
        assertRejected(with(["as_of"], "2026-10-08"), .unparseableTimestamp(field: "as_of", text: "2026-10-08"))
        assertRejected(with(["as_of"], FeedFixtures.pythonISO(now.addingTimeInterval(ForecastLimits.clockSkewTolerance + 1))), .futureDated(field: "as_of"))
        assertRejected(with(["windows", "7d", "n"], "2016"), .wrongType(field: "windows.7d.n"))
        assertRejected(with(["windows", "7d", "mae", "30"], "16.4"), .wrongType(field: "windows.7d.mae.30"))
        assertRejected(with(["windows", "30d"], [1, 2]), .wrongType(field: "windows.30d"))
    }

    func testImplausibleMetricsAreRejected() {
        assertRejected(with(["windows", "7d", "mae", "5"], -0.1), .implausibleMetric(field: "windows.7d.mae.5", value: -0.1))
        assertRejected(with(["windows", "7d", "mae", "120"], 600.5), .implausibleMetric(field: "windows.7d.mae.120", value: 600.5))
        assertRejected(with(["windows", "30d", "persistence_mae", "60"], -3), .implausibleMetric(field: "windows.30d.persistence_mae.60", value: -3))
        assertRejected(with(["windows", "7d", "win_rate_vs_oref", "30"], 1.01), .implausibleMetric(field: "windows.7d.win_rate_vs_oref.30", value: 1.01))
        assertRejected(with(["windows", "7d", "win_rate_vs_oref", "30"], -0.01), .implausibleMetric(field: "windows.7d.win_rate_vs_oref.30", value: -0.01))
        assertRejected(with(["windows", "7d", "parkes_ab_pct"], 100.5), .implausibleMetric(field: "windows.7d.parkes_ab_pct", value: 100.5))
        assertRejected(with(["windows", "30d", "parkes_ab_pct"], -1), .implausibleMetric(field: "windows.30d.parkes_ab_pct", value: -1))
        assertRejected(with(["windows", "7d", "n"], -1), .implausibleMetric(field: "windows.7d.n", value: -1))
    }

    func testMetricBoundariesAreAccepted() throws {
        var object = with(["windows", "7d", "mae", "5"], 0)
        object = FeedFixtures.setting(["windows", "7d", "mae", "120"], to: 600, in: object)
        object = FeedFixtures.setting(["windows", "7d", "win_rate_vs_oref", "5"], to: 0, in: object)
        object = FeedFixtures.setting(["windows", "7d", "win_rate_vs_oref", "120"], to: 1, in: object)
        object = FeedFixtures.setting(["windows", "7d", "parkes_ab_pct"], to: 100, in: object)
        let week = try XCTUnwrap(try decode(object).sevenDays)
        XCTAssertEqual(week.accuracy(at: .fiveMinutes).meanAbsoluteError, 0)
        XCTAssertEqual(week.accuracy(at: .twoHours).winRateVsOref, 1)
        XCTAssertEqual(week.parkesABPercent, 100)
    }
}
