// Original to Sensor (no ported code).
import XCTest
@testable import ForecastKit

final class EndpointTests: XCTestCase {
    private func assertRefused(_ input: String, _ expected: ForecastEndpointError, file: StaticString = #filePath, line: UInt = #line) {
        do {
            let endpoint = try ForecastFeedEndpoint(input)
            XCTFail("accepted \(input) as \(endpoint.host)", file: file, line: line)
        } catch {
            XCTAssertEqual(error, expected, "\(input)", file: file, line: line)
        }
    }

    func testAcceptedForms() throws {
        let forms = [
            "zen.example.com",
            "zen.example.com/",
            "https://zen.example.com",
            "https://zen.example.com/",
            "HTTPS://ZEN.Example.com",
            "  zen.example.com \n",
        ]
        for form in forms {
            let endpoint = try ForecastFeedEndpoint(form)
            XCTAssertEqual(endpoint.host, "zen.example.com", form)
            XCTAssertEqual(endpoint.latestURL.absoluteString, "https://zen.example.com/latest.json", form)
            XCTAssertEqual(endpoint.metricsURL.absoluteString, "https://zen.example.com/metrics.json", form)
        }
    }

    func testTheDisplayedHostIsTheHostContacted() throws {
        // Config/Signing.xcconfig ZEN_PREDICT_FEED_HOST is a bare host (D57); Settings shows `.host`.
        for input in ["zen.example.com", "HTTPS://Zen.Example.COM/", "d111111abcdef8.cloudfront.net", "a-1.b-2.example"] {
            let endpoint = try ForecastFeedEndpoint(input)
            XCTAssertEqual(endpoint.latestURL.host(percentEncoded: false), endpoint.host, input)
            XCTAssertEqual(endpoint.metricsURL.host(percentEncoded: false), endpoint.host, input)
            XCTAssertEqual(endpoint.latestURL.scheme, "https")
            XCTAssertNil(endpoint.latestURL.port)
        }
    }

    func testOtherValidHosts() throws {
        XCTAssertEqual(try ForecastFeedEndpoint("xn--bcher-kva.example").host, "xn--bcher-kva.example")
        XCTAssertEqual(try ForecastFeedEndpoint("d111111abcdef8.cloudfront.net").host, "d111111abcdef8.cloudfront.net")
        XCTAssertEqual(try ForecastFeedEndpoint("123.example.com").host, "123.example.com", "digits are fine except in the last label")
        let longestLabel = String(repeating: "a", count: 63)
        XCTAssertNoThrow(try ForecastFeedEndpoint("\(longestLabel).com"))
        let longestName = Array(repeating: String(repeating: "a", count: 62), count: 4).joined(separator: ".") + ".a"  // 253 bytes
        XCTAssertEqual(longestName.utf8.count, 253)
        XCTAssertNoThrow(try ForecastFeedEndpoint(longestName))
    }

    func testEmpty() {
        for input in ["", "   ", "\n", "/", "https://", "https:///", " https:// "] {
            assertRefused(input, .empty)
        }
    }

    func testOnlyHTTPS() {
        assertRefused("http://zen.example.com", .notHTTPS)
        assertRefused("HTTP://zen.example.com/", .notHTTPS)
        assertRefused("ftp://zen.example.com", .notHTTPS)
        assertRefused("://zen.example.com", .notHTTPS)
    }

    func testRefusesEverythingBeyondTheHost() {
        assertRefused("https://user:secret@zen.example.com", .containsCredentials)
        assertRefused("token@zen.example.com", .containsCredentials)
        assertRefused("https://zen.example.com?token=1", .containsQueryOrFragment)
        assertRefused("https://zen.example.com/?token=1", .containsQueryOrFragment)
        assertRefused("zen.example.com#latest", .containsQueryOrFragment)
        assertRefused("https://zen.example.com/latest.json", .containsPath)
        assertRefused("https://zen.example.com/feeds/", .containsPath)
        assertRefused("https://zen.example.com//", .containsPath)
        assertRefused("//zen.example.com", .containsPath)
        assertRefused("zen.example.com:8443", .containsPort)
        assertRefused("https://zen.example.com:443/", .containsPort)
    }

    func testRefusesInvalidHostNames() {
        let tooLong = Array(repeating: String(repeating: "a", count: 62), count: 4).joined(separator: ".") + ".ab"  // 254 bytes
        for input in ["zen..example.com", ".example.com", "zen.example.com.", "-zen.example.com", "zen-.example.com",
                      "zen_predict.example.com", "zen example.com", "zën.example.com",
                      "\(String(repeating: "a", count: 64)).com", tooLong] {
            assertRefused(input, .invalidHost)
        }
    }

    func testRefusesNonASCII() {
        // A combining mark makes "n" + U+20DD one Swift Character that compares between "a" and
        // "z"; the check runs on the UTF-8 bytes. U+212A KELVIN SIGN lower-cases to ASCII "k".
        for input in ["zen\u{20DD}.example.com", "ze\u{0301}n.example.com", "zen.exampl\u{0435}.com",
                      "zen.example.\u{212A}om", "zen.exam\u{200B}ple.com", "zen\u{FF0E}example.com"] {
            assertRefused(input, .invalidHost)
        }
        // Foundation counts U+200B as whitespace, so at either end it is trimmed like a space.
        XCTAssertEqual(try ForecastFeedEndpoint("zen.example.com\u{200B}").host, "zen.example.com")
    }

    func testRefusesIPAddressesAndSingleLabels() {
        for input in ["0", "localhost", "192.168.1.10", "999.999.999.999", "10.0.0.1", "zen.example.123", "zen.example.c0m", "zen.example.c-m"] {
            assertRefused(input, .invalidHost)
        }
    }

    func testIPv6LiteralIsRefused() {
        // Refused at the ":" check; a CloudFront feed host is always a DNS name.
        assertRefused("[::1]", .containsPort)
    }

    func testDescriptionsAreSentences() {
        let errors: [ForecastEndpointError] = [.empty, .notHTTPS, .containsCredentials, .containsQueryOrFragment, .containsPath, .containsPort, .invalidHost]
        for error in errors {
            XCTAssertTrue(error.description.hasSuffix("."), "\(error)")
        }
    }
}
