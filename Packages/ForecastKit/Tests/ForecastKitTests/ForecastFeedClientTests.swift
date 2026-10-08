// Original to Sensor (no ported code).
import XCTest
@testable import ForecastKit

/// The client against in-process transports: requests, conditional GETs, status codes, errors,
/// one request per URL at a time, cancellation.
final class ForecastFeedClientTests: XCTestCase {
    private let endpoint = try! ForecastFeedEndpoint("zen.example.com")
    private let latestBody = FeedFixtures.json(FeedFixtures.latestObject())
    private let metricsBody = FeedFixtures.json(FeedFixtures.metricsObject())

    private func client(_ transport: any ForecastTransport, now: ForecastInstant = FeedFixtures.nowInstant) -> ForecastFeedClient {
        ForecastFeedClient(endpoint: endpoint, transport: transport, now: { now })
    }

    private func expectError(_ expected: ForecastFeedError, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () async throws(ForecastFeedError) -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    // MARK: - Requests

    func testLatestRequest() async throws {
        let transport = MockForecastTransport([MockForecastTransport.ok(latestBody, eTag: "\"a1\"")])
        let latest = try await client(transport).fetchLatest()
        XCTAssertEqual(latest, try ForecastFeedDecoder.decodeLatest(latestBody, at: FeedFixtures.nowInstant))

        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://zen.example.com/latest.json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(request.httpBody)
    }

    func testMetricsRequest() async throws {
        let transport = MockForecastTransport([MockForecastTransport.ok(metricsBody)])
        let accuracy = try await client(transport).fetchAccuracy()
        XCTAssertEqual(accuracy.typicalMiss(at: .thirtyMinutes), 16.4)
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://zen.example.com/metrics.json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 10)
    }

    func testEndpointIsReadableWithoutAwait() {
        XCTAssertEqual(client(MockForecastTransport()).endpoint, endpoint)
    }

    func testDocumentsAreStampedWhenTheResponseArrives() async throws {
        let clock = TestClock(FeedFixtures.nowInstant)
        let transport = MockForecastTransport([MockForecastTransport.ok(latestBody), MockForecastTransport.ok(metricsBody)])
        let client = ForecastFeedClient(endpoint: endpoint, transport: transport, now: { clock.now })
        clock.advance(by: 5)
        let latest = try await client.fetchLatest()
        let accuracy = try await client.fetchAccuracy()
        XCTAssertEqual(latest.receivedAt, clock.now)
        XCTAssertEqual(accuracy.receivedAt, clock.now)
    }

    // MARK: - Conditional requests

    func testNotModifiedReturnsThePreviouslyValidatedDocument() async throws {
        let transport = MockForecastTransport([
            MockForecastTransport.ok(latestBody, eTag: "\"a1\""),
            MockForecastTransport.status(304, eTag: "\"a1\""),
            MockForecastTransport.status(304),
        ])
        let client = client(transport)
        let first = try await client.fetchLatest()
        let second = try await client.fetchLatest()
        let third = try await client.fetchLatest()
        XCTAssertEqual(second, first)
        XCTAssertEqual(third, first)
        let conditions = await transport.ifNoneMatchHeaders()
        XCTAssertEqual(conditions, [nil, "\"a1\"", "\"a1\""])
    }

    func testNotModifiedKeepsTheOriginalReceiptInstant() async throws {
        let clock = TestClock(FeedFixtures.nowInstant)
        let transport = MockForecastTransport([MockForecastTransport.ok(latestBody, eTag: "\"a1\""), MockForecastTransport.status(304)])
        let client = ForecastFeedClient(endpoint: endpoint, transport: transport, now: { clock.now })
        let first = try await client.fetchLatest()
        clock.advance(by: 60)
        let second = try await client.fetchLatest()
        XCTAssertEqual(second.receivedAt, FeedFixtures.nowInstant)
        XCTAssertEqual(second.zenRunAge(at: clock.now), 180, "2 minutes old on arrival + 1 minute since")
        XCTAssertEqual(second, first)
    }

    func testNewETagReplacesTheRememberedDocument() async throws {
        let changed = FeedFixtures.json(FeedFixtures.setting(["predictions", "zen", "30"], to: 99.5, in: FeedFixtures.latestObject()))
        let transport = MockForecastTransport([
            MockForecastTransport.ok(latestBody, eTag: "\"a1\""),
            MockForecastTransport.ok(changed, eTag: "\"b2\""),
            MockForecastTransport.status(304),
        ])
        let client = client(transport)
        _ = try await client.fetchLatest()
        let second = try await client.fetchLatest()
        let third = try await client.fetchLatest()
        XCTAssertEqual(second.zen?.point(at: .thirtyMinutes)?.predictedMgdl, 99.5)
        XCTAssertEqual(third, second)
        let conditions = await transport.ifNoneMatchHeaders()
        XCTAssertEqual(conditions, [nil, "\"a1\"", "\"b2\""])
    }

    func testWeakETagIsSentBackVerbatim() async throws {
        let transport = MockForecastTransport([MockForecastTransport.ok(latestBody, eTag: "W/\"a1\""), MockForecastTransport.status(304)])
        let client = client(transport)
        _ = try await client.fetchLatest()
        _ = try await client.fetchLatest()
        let conditions = await transport.ifNoneMatchHeaders()
        XCTAssertEqual(conditions, [nil, "W/\"a1\""])
    }

    func testWithoutAnETagEveryRequestIsUnconditional() async throws {
        let transport = MockForecastTransport([MockForecastTransport.ok(latestBody), MockForecastTransport.ok(latestBody)])
        let client = client(transport)
        _ = try await client.fetchLatest()
        _ = try await client.fetchLatest()
        let conditions = await transport.ifNoneMatchHeaders()
        XCTAssertEqual(conditions, [nil, nil])
    }

    func testNotModifiedWithNothingRememberedIsAnError() async {
        let transport = MockForecastTransport([MockForecastTransport.status(304), MockForecastTransport.status(304)])
        let client = client(transport)
        await expectError(.notModifiedWithoutCachedValue) { () async throws(ForecastFeedError) in _ = try await client.fetchLatest() }
        await expectError(.notModifiedWithoutCachedValue) { () async throws(ForecastFeedError) in _ = try await client.fetchAccuracy() }
    }

    func testFailuresOtherThanARejectedDocumentKeepTheRememberedDocument() async throws {
        // Offline or a 503 says nothing about the document, so a later 304 may still use it.
        let transport = MockForecastTransport([
            MockForecastTransport.ok(latestBody, eTag: "\"a1\""),
            MockForecastTransport.offline(),
            MockForecastTransport.status(503),
            MockForecastTransport.status(304),
        ])
        let client = client(transport)
        let first = try await client.fetchLatest()
        await expectError(.transport(ForecastTransportError(message: "The Internet connection appears to be offline."))) { () async throws(ForecastFeedError) in
            _ = try await client.fetchLatest()
        }
        await expectError(.httpStatus(503)) { () async throws(ForecastFeedError) in _ = try await client.fetchLatest() }
        let fourth = try await client.fetchLatest()
        XCTAssertEqual(fourth, first)
        let conditions = await transport.ifNoneMatchHeaders()
        XCTAssertEqual(conditions, [nil, "\"a1\"", "\"a1\"", "\"a1\""])
    }

    func testAccuracyConditionalRequests() async throws {
        let transport = MockForecastTransport([
            MockForecastTransport.ok(metricsBody, eTag: "\"m1\""),
            MockForecastTransport.status(304),
            MockForecastTransport.ok(FeedFixtures.json("{}"), eTag: "\"m2\""),
            MockForecastTransport.status(304),
        ])
        let client = client(transport)
        let first = try await client.fetchAccuracy()
        let second = try await client.fetchAccuracy()
        XCTAssertEqual(second, first)
        await expectError(.invalidDocument(.missingField("as_of"))) { () async throws(ForecastFeedError) in _ = try await client.fetchAccuracy() }
        await expectError(.notModifiedWithoutCachedValue) { () async throws(ForecastFeedError) in _ = try await client.fetchAccuracy() }
        let conditions = await transport.ifNoneMatchHeaders()
        XCTAssertEqual(conditions, [nil, "\"m1\"", "\"m1\"", nil])
    }

    func testLatestAndMetricsRememberSeparately() async throws {
        let transport = MockForecastTransport([
            MockForecastTransport.ok(latestBody, eTag: "\"l1\""),
            MockForecastTransport.ok(metricsBody, eTag: "\"m1\""),
            MockForecastTransport.status(304),
            MockForecastTransport.status(304),
        ])
        let client = client(transport)
        _ = try await client.fetchLatest()
        _ = try await client.fetchAccuracy()
        _ = try await client.fetchLatest()
        _ = try await client.fetchAccuracy()
        let conditions = await transport.ifNoneMatchHeaders()
        XCTAssertEqual(conditions, [nil, nil, "\"l1\"", "\"m1\""])
    }

    // MARK: - One request per URL at a time

    func testOverlappingFetchesShareOneRequest() async throws {
        let transport = GatedTransport()
        let client = client(transport)
        let latestURL = endpoint.latestURL
        let a = Task { try await client.fetchLatest() }
        await transport.waitUntilSent(1)
        let b = Task { try await client.fetchLatest() }
        let c = Task { try await client.fetchAccuracy() }   // another URL: its own request
        await transport.waitUntilSent(2)
        for _ in 0..<1_000 { await Task.yield() }
        let latestBody = latestBody, metricsBody = metricsBody
        await transport.answerAll { request, _ in
            request.url == latestURL
                ? ForecastHTTPResponse(statusCode: 200, eTag: "\"l1\"", body: latestBody)
                : ForecastHTTPResponse(statusCode: 200, eTag: "\"m1\"", body: metricsBody)
        }
        let first = try await a.value
        let second = try await b.value
        XCTAssertEqual(first, second)
        _ = try await c.value
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url == latestURL }.count, 1, "b must join a's request")
        XCTAssertEqual(requests.count, 2)

        // Once it finished, the next fetch sends a new request.
        let d = Task { try await client.fetchLatest() }
        await transport.answerAll { _, _ in ForecastHTTPResponse(statusCode: 304, eTag: "\"l1\"", body: Data()) }
        let third = try await d.value
        XCTAssertEqual(third, first)
        let conditions = await transport.sent
        XCTAssertEqual(conditions, [nil, nil, "\"l1\""])
    }

    func testOverlappingFetchesShareAFailure() async throws {
        let transport = GatedTransport()
        let client = client(transport)
        let a = Task { try await client.fetchAccuracy() }
        await transport.waitUntilSent(1)
        let b = Task { try await client.fetchAccuracy() }
        for _ in 0..<1_000 { await Task.yield() }
        await transport.answerAll { _, _ in ForecastHTTPResponse(statusCode: 503, eTag: nil, body: Data()) }
        for task in [a, b] {
            do {
                _ = try await task.value
                XCTFail("expected HTTP 503")
            } catch {
                XCTAssertEqual(error as? ForecastFeedError, .httpStatus(503))
            }
        }
        let sent = await transport.sent
        XCTAssertEqual(sent.count, 1, "b must join a's request")
    }

    // MARK: - Cancellation is not a failure

    func testTransportCancellationIsCancelledNotAFailure() async {
        let client = client(MockForecastTransport([.failure(.cancelled), .failure(.cancelled)]))
        await expectError(.cancelled) { () async throws(ForecastFeedError) in _ = try await client.fetchLatest() }
        await expectError(.cancelled) { () async throws(ForecastFeedError) in _ = try await client.fetchAccuracy() }
    }

    func testTaskCancellationIsCancelled() async throws {
        // The transport does not know about cancellation; the client sees the task was cancelled.
        let transport = HangingTransport()
        let client = client(transport)
        let task = Task { try await client.fetchLatest() }
        await transport.waitUntilStarted()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled fetch returned a value")
        } catch {
            XCTAssertEqual(error as? ForecastFeedError, .cancelled)
        }
        let started = await transport.started
        XCTAssertEqual(started, 1)
    }

    func testAlreadyCancelledCallerSendsNothing() async throws {
        let transport = MockForecastTransport([MockForecastTransport.ok(latestBody)])
        let client = client(transport)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.fetchLatest()
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled fetch returned a value")
        } catch {
            XCTAssertEqual(error as? ForecastFeedError, .cancelled)
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
        // The client is still usable.
        _ = try await client.fetchLatest()
    }

    // MARK: - Status codes and errors

    func testNon2xxStatusesAreTypedErrors() async {
        for status in [100, 301, 302, 400, 403, 404, 429, 500, 502, 503, 504] {
            let client = client(MockForecastTransport([MockForecastTransport.status(status), MockForecastTransport.status(status)]))
            await expectError(.httpStatus(status)) { () async throws(ForecastFeedError) in _ = try await client.fetchLatest() }
            await expectError(.httpStatus(status)) { () async throws(ForecastFeedError) in _ = try await client.fetchAccuracy() }
        }
    }

    func testOther2xxBodiesAreValidated() async throws {
        let client = client(MockForecastTransport([
            .success(ForecastHTTPResponse(statusCode: 203, eTag: nil, body: latestBody)),
            .success(ForecastHTTPResponse(statusCode: 204, eTag: nil, body: Data())),
        ]))
        _ = try await client.fetchLatest()
        await expectError(.invalidDocument(.notAJSONObject)) { () async throws(ForecastFeedError) in _ = try await client.fetchLatest() }
    }

    func testOversizedBodyFromAnyTransportIsATransportError() async {
        let huge = Data(count: ForecastLimits.maximumResponseBytes + 1)
        let client = client(MockForecastTransport([MockForecastTransport.ok(huge, eTag: "\"x\""), MockForecastTransport.status(304)]))
        await expectError(.transport(.bodyTooLarge)) { () async throws(ForecastFeedError) in _ = try await client.fetchLatest() }
        // Nothing was remembered from it.
        await expectError(.notModifiedWithoutCachedValue) { () async throws(ForecastFeedError) in _ = try await client.fetchLatest() }
    }

    func testTransportErrors() async {
        let client = client(MockForecastTransport([MockForecastTransport.offline(), MockForecastTransport.offline()]))
        let offline = ForecastFeedError.transport(ForecastTransportError(message: "The Internet connection appears to be offline."))
        await expectError(offline) { () async throws(ForecastFeedError) in _ = try await client.fetchLatest() }
        await expectError(offline) { () async throws(ForecastFeedError) in _ = try await client.fetchAccuracy() }
    }

    func testDocumentsAreValidatedAgainstTheInjectedClock() async {
        // The same body is fine at FeedFixtures.now but future-dated an hour earlier.
        let client = client(MockForecastTransport([MockForecastTransport.ok(latestBody), MockForecastTransport.ok(metricsBody)]),
                            now: FeedFixtures.instant(FeedFixtures.now.addingTimeInterval(-3600)))
        await expectError(.invalidDocument(.futureDated(field: "as_of"))) { () async throws(ForecastFeedError) in _ = try await client.fetchLatest() }
        await expectError(.invalidDocument(.futureDated(field: "as_of"))) { () async throws(ForecastFeedError) in _ = try await client.fetchAccuracy() }
    }

    func testTheClockIsReadAtEachFetch() async throws {
        let clock = TestClock(FeedFixtures.instant(FeedFixtures.now.addingTimeInterval(-3600)))
        let transport = MockForecastTransport([MockForecastTransport.ok(latestBody), MockForecastTransport.ok(latestBody)])
        let client = ForecastFeedClient(endpoint: endpoint, transport: transport, now: { clock.now })
        await expectError(.invalidDocument(.futureDated(field: "as_of"))) { () async throws(ForecastFeedError) in _ = try await client.fetchLatest() }
        clock.advance(by: 3600)
        _ = try await client.fetchLatest()
    }

    func testDefaultClockIsThePhonesClock() async throws {
        // The one test that reads the real clock: it only checks the default argument.
        let real = Date()
        let transport = MockForecastTransport([
            MockForecastTransport.ok(FeedFixtures.json(FeedFixtures.latestObject(now: real))),
            MockForecastTransport.ok(FeedFixtures.json(FeedFixtures.latestObject(now: real.addingTimeInterval(3600)))),
        ])
        let client = ForecastFeedClient(endpoint: endpoint, transport: transport)
        let latest = try await client.fetchLatest()
        XCTAssertGreaterThanOrEqual(latest.receivedAt.wall, real)
        await expectError(.invalidDocument(.futureDated(field: "as_of"))) { () async throws(ForecastFeedError) in _ = try await client.fetchLatest() }
    }

    func testErrorDescriptions() {
        let errors: [ForecastFeedError] = [
            .transport(ForecastTransportError(message: "offline")),
            .httpStatus(404),
            .notModifiedWithoutCachedValue,
            .invalidDocument(.notAJSONObject),
            .cancelled,
        ]
        for error in errors {
            XCTAssertFalse(error.description.isEmpty)
        }
        XCTAssertTrue(ForecastFeedError.httpStatus(404).description.contains("404"))
        XCTAssertTrue(ForecastFeedError.transport(ForecastTransportError(message: "offline")).description.contains("offline"))
        XCTAssertEqual(ForecastTransportError(message: "offline").description, "offline")
        XCTAssertFalse(ForecastTransportError(message: "offline").isCancellation)
        XCTAssertTrue(ForecastTransportError.cancelled.isCancellation)
        XCTAssertTrue(ForecastTransportError.bodyTooLarge.message.contains("512 KB"))
    }
}
