// Original to Sensor (no ported code).
import XCTest
@testable import ForecastKit

final class FeedTimestampTests: XCTestCase {
    private func parse(_ text: String) -> TimeInterval? {
        FeedTimestamp.parse(text)?.timeIntervalSince1970
    }

    // MARK: - Accepted

    func testReferenceInstants() {
        // Anchors that need no arithmetic: Foundation's reference date and the Unix epoch.
        XCTAssertEqual(FeedTimestamp.parse("2001-01-01T00:00:00Z"), Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertEqual(parse("1970-01-01T00:00:00Z"), 0)
    }

    func testLiveFormatWithSixDigitFractionAndOffset() throws {
        let seconds = try XCTUnwrap(parse("2026-10-08T18:46:13.580641+00:00"))
        XCTAssertEqual(seconds, 1_791_485_173.580641, accuracy: 1e-6)
    }

    func testLiveFormatWithoutFraction() {
        // Python's isoformat() leaves out the fraction when the microseconds are 0.
        XCTAssertEqual(parse("2026-10-08T18:46:13+00:00"), 1_791_485_173)
    }

    func testFixtureFormatWithZ() {
        XCTAssertEqual(parse("2026-07-31T12:03:00Z"), 1_785_499_380)
    }

    func testFractionsOfAnyLength() throws {
        XCTAssertEqual(try XCTUnwrap(parse("2001-01-01T00:00:00.5Z")), 978_307_200.5, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(parse("2001-01-01T00:00:00.250Z")), 978_307_200.25, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(parse("2001-01-01T00:00:00.123456789Z")), 978_307_200.123456789, accuracy: 1e-6)
    }

    func testOffsetsAreSubtracted() {
        // 02:00 at UTC+2 and 19:30 the previous day at UTC−4:30 are both 2001-01-01T00:00Z.
        XCTAssertEqual(parse("2001-01-01T02:00:00+02:00"), 978_307_200)
        XCTAssertEqual(parse("2000-12-31T19:30:00-04:30"), 978_307_200)
        XCTAssertEqual(parse("2001-01-01T00:00:00-00:00"), 978_307_200)
    }

    func testLeapDayAndEdgesOfTheDay() {
        XCTAssertNotNil(parse("2028-02-29T00:00:00Z"))
        XCTAssertNotNil(parse("2026-12-31T23:59:59.999999+00:00"))
        XCTAssertNotNil(parse("2026-10-08T18:46:13+23:59"))
    }

    // MARK: - Refused

    func testRefusesEverythingElse() {
        let refused = [
            "",
            "2026-10-08",
            "2026-10-08T18:46:13",            // no zone
            "2026-10-08 18:46:13Z",           // space separator
            "2026-10-08t18:46:13z",           // lower case
            "2026/10/08T18:46:13Z",
            "2026-10-08T18:46:13.Z",          // empty fraction
            "2026-10-08T18:46:13,5Z",         // comma fraction
            "2026-10-08T18:46:13+0000",       // offset without colon
            "2026-10-08T18:46:13+00",
            "2026-10-08T18:46:13+00:00Z",
            "2026-10-08T18:46:13Zjunk",
            "2026-10-08T18:46:13+00:00 ",
            "2026-10-08T18:46:13UTC",
            "2026-10-08T18:46:13+24:00",
            "2026-10-08T18:46:13+00:60",
            "2026-10-08T18:46:13+0a:00",
            "2026-02-30T00:00:00Z",           // no 30 February
            "2026-02-29T00:00:00Z",           // 2026 is not a leap year
            "2026-13-01T00:00:00Z",
            "2026-00-10T00:00:00Z",
            "2026-10-00T00:00:00Z",
            "2026-10-08T24:00:00Z",
            "2026-10-08T18:60:00Z",
            "2026-10-08T18:46:60Z",           // no leap seconds
            "2026-1O-08T18:46:13Z",           // letter O
            "+2026-10-08T18:46:13Z",
            "yesterday at noon, roughly",
            "２０２６-10-08T18:46:13Z",        // full-width digits
        ]
        for text in refused {
            XCTAssertNil(FeedTimestamp.parse(text), "accepted \(text)")
        }
    }
}
