import XCTest
import GlucoseCore
@testable import NightscoutKit

/// How Nightscout numbers map to GlucoseValue and back (S4), and entry decoding.
final class NightscoutEncodingTests: XCTestCase {
    func test_S4_nightscoutImportClassifiesLikeNightscoutDisplay() {
        // lib/client/index.js:540-549: < 39 error code, < 40 LOW, > 400 HIGH, else the number.
        XCTAssertEqual(NightscoutGlucoseEncoding.decode(sgv: 5), .errorCode(5))
        XCTAssertEqual(NightscoutGlucoseEncoding.decode(sgv: 38.9), .errorCode(38.9))
        XCTAssertEqual(NightscoutGlucoseEncoding.decode(sgv: 39), .value(.belowRange))
        XCTAssertEqual(NightscoutGlucoseEncoding.decode(sgv: 39.6), .value(.belowRange), "Nightscout shows 39.6 as LOW; never round it up to 40")
        XCTAssertEqual(NightscoutGlucoseEncoding.decode(sgv: 40), .value(.mgdl(40)))
        XCTAssertEqual(NightscoutGlucoseEncoding.decode(sgv: 123.4), .value(.mgdl(123)))
        XCTAssertEqual(NightscoutGlucoseEncoding.decode(sgv: 400), .value(.mgdl(400)))
        XCTAssertEqual(NightscoutGlucoseEncoding.decode(sgv: 400.2), .value(.aboveRange))
        XCTAssertEqual(NightscoutGlucoseEncoding.decode(sgv: 401), .value(.aboveRange))
        XCTAssertEqual(NightscoutGlucoseEncoding.decode(sgv: 450), .value(.aboveRange))
        XCTAssertEqual(NightscoutGlucoseEncoding.decode(sgv: .nan), .invalid)
        XCTAssertEqual(NightscoutGlucoseEncoding.decode(sgv: .infinity), .invalid)
    }

    func test_S4_uploadEncodingIsTheFlagNotAClamp() {
        XCTAssertEqual(NightscoutGlucoseEncoding.sgv(for: .belowRange), 39)
        XCTAssertEqual(NightscoutGlucoseEncoding.sgv(for: .aboveRange), 401)
        XCTAssertEqual(NightscoutGlucoseEncoding.sgv(for: .mgdl(40)), 40)
        XCTAssertEqual(NightscoutGlucoseEncoding.sgv(for: .mgdl(400)), 400)
        XCTAssertNil(NightscoutGlucoseEncoding.sgv(for: .mgdl(39)), "a number outside 40...400 would render as a flag")
        XCTAssertNil(NightscoutGlucoseEncoding.sgv(for: .mgdl(401)))
        // Round trip: every value survives upload and re-import unchanged.
        for value: GlucoseValue in [.belowRange, .aboveRange, .mgdl(40), .mgdl(123), .mgdl(400)] {
            let sgv = NightscoutGlucoseEncoding.sgv(for: value)!
            XCTAssertEqual(NightscoutGlucoseEncoding.decode(sgv: Double(sgv)), .value(value))
        }
    }

    func test_entryMapping() {
        let date = 1_789_812_000_000.0
        func map(_ entry: NightscoutEntry) -> NightscoutEntryMapper.Result { NightscoutEntryMapper.map(entry) }
        XCTAssertEqual(map(NightscoutEntry(type: "mbg", sgv: nil, date: date)), .skipped(.notSGV))
        XCTAssertEqual(map(NightscoutEntry(type: "cal", sgv: nil, date: date)), .skipped(.notSGV))
        XCTAssertEqual(map(NightscoutEntry(type: nil, sgv: 120, date: date)), .skipped(.notSGV))
        XCTAssertEqual(map(NightscoutEntry(type: "sgv", sgv: 120, date: nil)), .skipped(.missingDate))
        XCTAssertEqual(map(NightscoutEntry(type: "sgv", sgv: 120, date: 0)), .skipped(.missingDate))
        XCTAssertEqual(map(NightscoutEntry(type: "sgv", sgv: nil, date: date)), .skipped(.missingValue))
        XCTAssertEqual(map(NightscoutEntry(type: "sgv", sgv: .nan, date: date)), .skipped(.missingValue))
        XCTAssertEqual(map(NightscoutEntry(type: "sgv", sgv: 9, date: date)), .skipped(.errorCode))
        let expectedDate = Date(timeIntervalSince1970: 1_789_812_000)
        XCTAssertEqual(map(NightscoutEntry(type: "sgv", sgv: 120, date: date, direction: "Flat")), .reading(GlucoseReading(
            id: "imported:nightscout:1789812000000", date: expectedDate, value: .mgdl(120), trendRate: nil,
            isBackfill: false, source: .imported(.nightscout), sensorSerial: ""
        )))
    }

    func test_entryDecodingIsLenient() throws {
        let json = """
        [{"_id":"a","type":"sgv","sgv":"123","date":"1789812000000","direction":"Flat"},
         {"_id":{"$oid":"b"},"type":"sgv","sgv":120,"date":1789812300000},
         {"type":"sgv","sgv":true,"date":1789812600000},
         {}]
        """
        let entries = try JSONDecoder().decode([NightscoutEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[0].sgv, 123)
        XCTAssertEqual(entries[0].date, 1_789_812_000_000)
        XCTAssertNil(entries[1].id)
        XCTAssertEqual(entries[1].sgv, 120)
        XCTAssertNil(entries[2].sgv)
        XCTAssertNil(entries[3].type)
    }

    func test_uploadPayloadFields() throws {
        let session = SessionFixture()
        let reading = session.reading(at: 3_600.123, value: .mgdl(123), trendRate: 1.5)
        let payload = try XCTUnwrap(NightscoutEntryPayload(reading: reading, deviceName: "Sensor"))
        XCTAssertEqual(payload.type, "sgv")
        XCTAssertEqual(payload.sgv, 123)
        XCTAssertEqual(payload.direction, "FortyFiveUp")
        XCTAssertEqual(payload.date, GlucoseReading.epochMilliseconds(reading.date))
        XCTAssertEqual(payload.dateString, "2026-09-20T01:00:00.123Z")
        XCTAssertEqual(payload.device, "Sensor")
        XCTAssertEqual(NightscoutEntryPayload(reading: session.reading(at: 60, trendRate: nil), deviceName: "Sensor")?.direction, "NOT COMPUTABLE")
    }

    func test_iso8601FromIntegerMilliseconds() {
        XCTAssertEqual(NightscoutEntryPayload.iso8601UTC(milliseconds: 0), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(NightscoutEntryPayload.iso8601UTC(milliseconds: 1_789_812_000_999), "2026-09-19T10:00:00.999Z")
        XCTAssertEqual(NightscoutEntryPayload.iso8601UTC(milliseconds: 1_789_812_000_001), "2026-09-19T10:00:00.001Z")
        XCTAssertEqual(NightscoutEntryPayload.iso8601UTC(milliseconds: -1), "1969-12-31T23:59:59.999Z")
    }
}

final class NightscoutSiteTests: XCTestCase {
    func test_acceptsHTTPSAndNormalises() throws {
        XCTAssertEqual(try NightscoutSite("https://ns.example.org/").baseURL.absoluteString, "https://ns.example.org")
        XCTAssertEqual(try NightscoutSite(" https://ns.example.org/sub// ").baseURL.absoluteString, "https://ns.example.org/sub")
        XCTAssertEqual(try NightscoutSite("https://ns.example.org").entriesURL.absoluteString, "https://ns.example.org/api/v1/entries")
        XCTAssertEqual(try NightscoutSite("https://ns.example.org").entriesJSONURL.absoluteString, "https://ns.example.org/api/v1/entries.json")
        XCTAssertNoThrow(try NightscoutSite("http://127.0.0.1:8080"))
        XCTAssertNoThrow(try NightscoutSite(url: URL(string: "http://localhost:1337")!))
    }

    func test_refusesCleartextCredentialsAndGarbage() {
        XCTAssertThrowsError(try NightscoutSite("http://ns.example.org")) { XCTAssertEqual($0 as? NightscoutSite.ValidationError, .insecureScheme) }
        XCTAssertThrowsError(try NightscoutSite("https://ns.example.org/?token=abc")) { XCTAssertEqual($0 as? NightscoutSite.ValidationError, .containsCredentialsOrQuery) }
        XCTAssertThrowsError(try NightscoutSite("https://user:pw@ns.example.org")) { XCTAssertEqual($0 as? NightscoutSite.ValidationError, .containsCredentialsOrQuery) }
        XCTAssertThrowsError(try NightscoutSite("ns.example.org")) { XCTAssertNotNil($0 as? NightscoutSite.ValidationError) }
        XCTAssertThrowsError(try NightscoutSite("ftp://ns.example.org")) { XCTAssertEqual($0 as? NightscoutSite.ValidationError, .insecureScheme) }
    }
}

extension NightscoutSiteTests {
    func test_decodingValidatesLikeTypingTheURL() throws {
        // Reviewer m1: a stored site (import checkpoint) goes through the same validation.
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(NightscoutSite.self, from: Data(#"{"baseURL":"http://ns.example.org"}"#.utf8)))
        XCTAssertThrowsError(try decoder.decode(NightscoutSite.self, from: Data(#"{"baseURL":"https://u:p@ns.example.org"}"#.utf8)))
        XCTAssertEqual(try decoder.decode(NightscoutSite.self, from: Data(#"{"baseURL":"http://127.0.0.1:1337"}"#.utf8)).baseURL.absoluteString, "http://127.0.0.1:1337")
        let site = try NightscoutSite("https://ns.example.org/")
        XCTAssertEqual(try decoder.decode(NightscoutSite.self, from: JSONEncoder().encode(site)), site)
    }
}

final class RetryPolicyAndCredentialTests: XCTestCase {
    func test_backoffDoublesToTheCapAndCredentialsWaitLonger() {
        let policy = RetryPolicy.default
        XCTAssertEqual((1...6).map { policy.delay(afterConsecutiveFailures: $0, kind: .server) }, [30, 60, 120, 240, 300, 300])
        XCTAssertEqual(policy.delay(afterConsecutiveFailures: 1_000, kind: .transport), 300)
        XCTAssertEqual(policy.delay(afterConsecutiveFailures: 1, kind: .unauthorized), 1_800)
        XCTAssertEqual(policy.delay(afterConsecutiveFailures: 1, kind: .missingCredentials), 1_800)
    }

    func test_inMemoryCredentialStore() throws {
        let store = InMemoryCredentialStore()
        XCTAssertNil(try store.read(.nightscoutToken))
        try store.write("abc", for: .nightscoutToken)
        XCTAssertEqual(try store.read(.nightscoutToken), "abc")
        try store.delete(.nightscoutToken)
        XCTAssertNil(try store.read(.nightscoutToken))
        XCTAssertEqual(Set(CredentialKey.allCases.map(\.rawValue)).count, 3)
    }

    func test_redirectsOnlyToTheSameOrigin() {
        let origin = URL(string: "https://ns.example.org/api/v1/entries")
        XCTAssertTrue(SameOriginRedirectsOnly.allows(from: origin, to: URL(string: "https://NS.example.org/api/v1/entries/")))
        XCTAssertFalse(SameOriginRedirectsOnly.allows(from: origin, to: URL(string: "https://evil.example.com/api/v1/entries")))
        XCTAssertFalse(SameOriginRedirectsOnly.allows(from: origin, to: URL(string: "http://ns.example.org/api/v1/entries")))
        XCTAssertFalse(SameOriginRedirectsOnly.allows(from: origin, to: URL(string: "https://ns.example.org:8443/api/v1/entries")))
        XCTAssertFalse(SameOriginRedirectsOnly.allows(from: nil, to: origin))
    }
}
