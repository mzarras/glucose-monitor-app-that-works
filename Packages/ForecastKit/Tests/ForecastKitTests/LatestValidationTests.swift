// Original to Sensor (no ported code).
import XCTest
@testable import ForecastKit

/// latest.json documents that must be rejected whole, each with its typed reason.
final class LatestValidationTests: XCTestCase {
    private let now = FeedFixtures.now
    private let tolerance = ForecastLimits.clockSkewTolerance

    private func assertRejected(
        _ data: Data,
        now: Date = FeedFixtures.now,
        _ expected: ForecastDocumentError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let accepted = try ForecastFeedDecoder.decodeLatest(data, at: FeedFixtures.instant(now))
            XCTFail("accepted: \(accepted)", file: file, line: line)
        } catch {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    private func assertRejected(
        _ object: [String: Any],
        now: Date = FeedFixtures.now,
        _ expected: ForecastDocumentError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertRejected(FeedFixtures.json(object), now: now, expected, file: file, line: line)
    }

    private func assertAccepted(_ object: [String: Any], now: Date = FeedFixtures.now, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNoThrow(try ForecastFeedDecoder.decodeLatest(FeedFixtures.json(object), at: FeedFixtures.instant(now)), file: file, line: line)
    }

    private func with(_ path: [String], _ value: Any?) -> [String: Any] {
        FeedFixtures.setting(path, to: value, in: FeedFixtures.latestObject())
    }

    // MARK: - Not a JSON object

    func testNotAJSONObject() {
        let bodies = [
            "",
            "[]",
            "[{\"as_of\": \"2026-10-08T18:59:30+00:00\"}]",
            "5",
            "\"latest\"",
            "null",
            "{",
            "<html><body>403 Forbidden</body></html>",
            // Python's json.dumps writes NaN/Infinity for non-finite floats unless allow_nan=False.
            "{\"as_of\": \"2026-10-08T18:59:30+00:00\", \"predictions\": {\"generated_at\": \"2026-10-08T18:58:00+00:00\", \"zen\": {\"5\": NaN}}}",
            "{\"as_of\": \"2026-10-08T18:59:30+00:00\", \"predictions\": {\"generated_at\": \"2026-10-08T18:58:00+00:00\", \"zen\": {\"5\": Infinity}}}",
            "{\"as_of\": \"2026-10-08T18:59:30+00:00\", \"predictions\": {\"generated_at\": \"2026-10-08T18:58:00+00:00\", \"zen\": {\"5\": 1e400}}}",
        ]
        for body in bodies {
            assertRejected(FeedFixtures.json(body), .notAJSONObject)
        }
    }

    func testNumberTooLargeForSwiftIsRejected() {
        // JSONSerialization reads -1e400 as -infinity; JSONDecoder refuses it at the root.
        let body = "{\"as_of\": \"2026-10-08T18:59:30+00:00\", \"predictions\": {\"generated_at\": \"2026-10-08T18:58:00+00:00\", \"zen\": {\"5\": -1e400}}}"
        assertRejected(FeedFixtures.json(body), .wrongType(field: "(document)"))
    }

    // MARK: - Wrong types

    func testWrongTypes() {
        assertRejected(with(["as_of"], 1_791_486_000), .wrongType(field: "as_of"))
        assertRejected(with(["bg"], "108"), .wrongType(field: "bg"))
        assertRejected(with(["bg", "mg_dl"], "108"), .wrongType(field: "bg.mg_dl"))
        assertRejected(with(["bg", "mg_dl"], true), .wrongType(field: "bg.mg_dl"))
        assertRejected(with(["bg", "trend"], 4), .wrongType(field: "bg.trend"))
        assertRejected(with(["predictions"], ["generated_at", "zen"]), .wrongType(field: "predictions"))
        assertRejected(with(["predictions", "generated_at"], 1_791_485_880), .wrongType(field: "predictions.generated_at"))
        assertRejected(with(["predictions", "zen"], [110.42, 127.06]), .wrongType(field: "predictions.zen"))
        assertRejected(with(["predictions", "zen", "30"], "127.06"), .wrongType(field: "predictions.zen.30"))
        assertRejected(with(["predictions", "oref", "120"], ["p50": 160]), .wrongType(field: "predictions.oref.120"))
        assertRejected(with(["model_version"], 20_261_005), .wrongType(field: "model_version"))
    }

    // MARK: - as_of

    func testMissingAsOf() {
        assertRejected(with(["as_of"], nil), .missingField("as_of"))
        assertRejected(with(["as_of"], NSNull()), .missingField("as_of"))
        assertRejected(FeedFixtures.json("{}"), .missingField("as_of"))
    }

    func testUnparseableTimestamps() {
        assertRejected(with(["as_of"], "yesterday"), .unparseableTimestamp(field: "as_of", text: "yesterday"))
        assertRejected(with(["predictions", "generated_at"], "2026-10-08 18:58:00"),
                       .unparseableTimestamp(field: "predictions.generated_at", text: "2026-10-08 18:58:00"))
        assertRejected(with(["bg", "ts"], "2026-02-30T00:00:00Z"), .unparseableTimestamp(field: "bg.ts", text: "2026-02-30T00:00:00Z"))
    }

    // MARK: - Future-dated and out-of-order timestamps

    func testAsOfBeyondClockSkewIsRejected() {
        assertRejected(with(["as_of"], FeedFixtures.pythonISO(now.addingTimeInterval(tolerance + 1))), .futureDated(field: "as_of"))
        assertRejected(with(["as_of"], FeedFixtures.pythonISO(now.addingTimeInterval(3600))), .futureDated(field: "as_of"))
    }

    func testAsOfWithinClockSkewIsAccepted() {
        assertAccepted(with(["as_of"], FeedFixtures.pythonISO(now.addingTimeInterval(tolerance))))
        assertAccepted(with(["as_of"], FeedFixtures.pythonISO(now.addingTimeInterval(tolerance - 0.5))))
    }

    func testGeneratedAtInTheFutureIsRejected() {
        var object = with(["as_of"], FeedFixtures.pythonISO(now.addingTimeInterval(tolerance)))
        object = FeedFixtures.setting(["predictions", "generated_at"], to: FeedFixtures.pythonISO(now.addingTimeInterval(tolerance + 0.5)), in: object)
        assertRejected(object, .futureDated(field: "predictions.generated_at"))
    }

    func testGeneratedAtLaterThanAsOfIsRejected() {
        // Not in the future, but more than the tolerance after the document's own as_of.
        var object = with(["as_of"], FeedFixtures.pythonISO(now.addingTimeInterval(-600)))
        object = FeedFixtures.setting(["predictions", "generated_at"], to: FeedFixtures.pythonISO(now.addingTimeInterval(-600 + tolerance + 1)), in: object)
        object = FeedFixtures.setting(["bg", "ts"], to: FeedFixtures.pythonISO(now.addingTimeInterval(-700)), in: object)
        assertRejected(object, .laterThanAsOf(field: "predictions.generated_at"))
    }

    func testGeneratedAtWithinToleranceOfAsOfIsAccepted() {
        var object = with(["as_of"], FeedFixtures.pythonISO(now.addingTimeInterval(-600)))
        object = FeedFixtures.setting(["predictions", "generated_at"], to: FeedFixtures.pythonISO(now.addingTimeInterval(-600 + tolerance)), in: object)
        object = FeedFixtures.setting(["bg", "ts"], to: FeedFixtures.pythonISO(now.addingTimeInterval(-700)), in: object)
        assertAccepted(object)
    }

    func testFeedGlucoseTimestampRules() {
        assertRejected(with(["bg", "ts"], FeedFixtures.pythonISO(now.addingTimeInterval(tolerance + 1))), .futureDated(field: "bg.ts"))
        var object = with(["as_of"], FeedFixtures.pythonISO(now.addingTimeInterval(-600)))
        object = FeedFixtures.setting(["predictions", "generated_at"], to: FeedFixtures.pythonISO(now.addingTimeInterval(-900)), in: object)
        object = FeedFixtures.setting(["bg", "ts"], to: FeedFixtures.pythonISO(now.addingTimeInterval(-300)), in: object)
        assertRejected(object, .laterThanAsOf(field: "bg.ts"))
    }

    // MARK: - Values need their time

    func testZenValuesWithoutGeneratedAtAreRejected() {
        assertRejected(with(["predictions", "generated_at"], NSNull()), .valueWithoutTimestamp(field: "predictions.zen"))
        assertRejected(with(["predictions", "generated_at"], nil), .valueWithoutTimestamp(field: "predictions.zen"))
    }

    func testFeedGlucoseWithoutTimeIsRejected() {
        assertRejected(with(["bg", "ts"], NSNull()), .valueWithoutTimestamp(field: "bg.mg_dl"))
    }

    // MARK: - Plausibility

    func testZenPlausibleRangeIsInclusive() {
        assertAccepted(with(["predictions", "zen", "5"], 20))
        assertAccepted(with(["predictions", "zen", "5"], 600))
        assertAccepted(with(["predictions", "zen", "5"], 40))
        assertAccepted(with(["predictions", "zen", "5"], 400))
    }

    func testZenOutsideThePlausibleRangeIsRejected() {
        for value in [19.99, 600.01, 0, -5, 6.1, 2_214, 1e300] {
            assertRejected(with(["predictions", "zen", "120"], value), .implausibleForecast(field: "predictions.zen.120", value: value))
        }
    }

    func testOrefPlausibleRangeIsOrefsOwnClamp() {
        assertAccepted(with(["predictions", "oref", "120"], 39))
        assertAccepted(with(["predictions", "oref", "120"], 1500))
        // Above Zen's limit but inside oref's COB clamp: a genuine oref value.
        assertAccepted(with(["predictions", "oref", "120"], 650))
        for value in [38.9, 1500.5, 0, -1] {
            assertRejected(with(["predictions", "oref", "60"], value), .implausibleForecast(field: "predictions.oref.60", value: value))
        }
    }

    func testFeedGlucoseOutsideThePlausibleRangeIsRejected() {
        for value in [-1, 1000.5, 1e9] {
            assertRejected(with(["bg", "mg_dl"], value), .implausibleFeedGlucose(value: value))
        }
    }

    func testFirstFailingRuleIsReported() {
        // The decoder checks as_of, then generated_at, then the values, then bg.
        var object = with(["predictions", "zen", "5"], 1)
        object = FeedFixtures.setting(["bg", "mg_dl"], to: -1, in: object)
        assertRejected(object, .implausibleForecast(field: "predictions.zen.5", value: 1))
    }

    func testErrorDescriptionsNameTheField() {
        let errors: [ForecastDocumentError] = [
            .notAJSONObject,
            .wrongType(field: "bg.mg_dl"),
            .missingField("as_of"),
            .unparseableTimestamp(field: "as_of", text: "x"),
            .futureDated(field: "as_of"),
            .laterThanAsOf(field: "bg.ts"),
            .valueWithoutTimestamp(field: "predictions.zen"),
            .implausibleForecast(field: "predictions.zen.5", value: 1),
            .implausibleFeedGlucose(value: -1),
            .implausibleMetric(field: "windows.7d.n", value: -1),
        ]
        for error in errors {
            XCTAssertFalse(error.description.isEmpty)
        }
        XCTAssertTrue(ForecastDocumentError.implausibleForecast(field: "predictions.zen.5", value: 1).description.contains("predictions.zen.5"))
        XCTAssertTrue(ForecastDocumentError.futureDated(field: "as_of").description.contains("as_of"))
    }
}
