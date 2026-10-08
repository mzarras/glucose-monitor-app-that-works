// Original to Sensor (no ported code).
import XCTest
@testable import ForecastKit

/// The production transport over a URLSession whose requests are answered in-process.
final class URLSessionForecastTransportTests: XCTestCase {
    private let transport = URLSessionForecastTransport(session: StubURLProtocol.session())

    private func url(_ host: String, _ path: String = "/latest.json") -> URL {
        URL(string: "https://\(host).stub.invalid\(path)")!
    }

    func testOKResponseWithETag() async throws {
        let url = url("ok")
        StubURLProtocol.registry.set(.http(status: 200, headers: ["ETag": "\"713b78d6\"", "Content-Type": "application/json"], body: Data("{}".utf8)), for: url)
        let response = try await transport.send(ForecastFeedClient.request(url: url, ifNoneMatch: nil))
        XCTAssertEqual(response, ForecastHTTPResponse(statusCode: 200, eTag: "\"713b78d6\"", body: Data("{}".utf8)))
    }

    func testNotModifiedReachesTheCallerAsNotModified() async throws {
        // With no URL cache, URLSession must not turn a 304 into a cached 200 (or vice versa).
        let url = url("notmodified")
        StubURLProtocol.registry.set(.http(status: 304, headers: ["ETag": "\"a1\""], body: Data()), for: url)
        let response = try await transport.send(ForecastFeedClient.request(url: url, ifNoneMatch: "\"a1\""))
        XCTAssertEqual(response.statusCode, 304)
        XCTAssertEqual(response.eTag, "\"a1\"")
        XCTAssertTrue(response.body.isEmpty)
        let sent = try XCTUnwrap(StubURLProtocol.registry.requests(to: url).last)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "If-None-Match"), "\"a1\"")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testErrorStatusIsAResponseNotATransportError() async throws {
        let url = url("forbidden")
        StubURLProtocol.registry.set(.http(status: 403, headers: [:], body: Data("<Error/>".utf8)), for: url)
        let response = try await transport.send(ForecastFeedClient.request(url: url, ifNoneMatch: nil))
        XCTAssertEqual(response.statusCode, 403)
        XCTAssertNil(response.eTag)
    }

    func testURLErrorsBecomeTransportErrors() async {
        let url = url("offline")
        StubURLProtocol.registry.set(.failure(.notConnectedToInternet), for: url)
        do {
            _ = try await transport.send(ForecastFeedClient.request(url: url, ifNoneMatch: nil))
            XCTFail("expected a transport error")
        } catch {
            XCTAssertFalse(error.message.isEmpty)
            XCTAssertFalse(error.isCancellation)
        }
    }

    func testCancellationIsReportedAsCancellation() async throws {
        let url = url("cancelled")
        StubURLProtocol.registry.set(.failure(.cancelled), for: url)
        do {
            _ = try await transport.send(ForecastFeedClient.request(url: url, ifNoneMatch: nil))
            XCTFail("expected a cancellation")
        } catch {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(URLSessionForecastTransport.transportError(CancellationError()), .cancelled)
        XCTAssertEqual(URLSessionForecastTransport.transportError(URLError(.cancelled)), .cancelled)
        XCTAssertFalse(URLSessionForecastTransport.transportError(URLError(.timedOut)).isCancellation)

        // Through the client: cancelled, not a failure.
        let endpoint = try ForecastFeedEndpoint("cancelled.stub.invalid")
        StubURLProtocol.registry.set(.failure(.cancelled), for: endpoint.latestURL)
        do {
            _ = try await ForecastFeedClient(endpoint: endpoint, transport: transport).fetchLatest()
            XCTFail("expected a cancellation")
        } catch {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testBodyOverTheLimitIsRefusedByContentLength() async {
        let url = url("big-declared")
        let body = Data(count: ForecastLimits.maximumResponseBytes + 1)
        StubURLProtocol.registry.set(.http(status: 200, headers: ["Content-Length": String(body.count)], body: body), for: url)
        do {
            _ = try await transport.send(ForecastFeedClient.request(url: url, ifNoneMatch: nil))
            XCTFail("an oversized body was accepted")
        } catch {
            XCTAssertEqual(error, .bodyTooLarge)
        }
    }

    func testBodyOverTheLimitIsRefusedWhileReading() async throws {
        // No Content-Length: the transport counts as it reads.
        let url = url("big-undeclared")
        StubURLProtocol.registry.set(.http(status: 200, headers: [:], body: Data(count: ForecastLimits.maximumResponseBytes + 1)), for: url)
        do {
            _ = try await transport.send(ForecastFeedClient.request(url: url, ifNoneMatch: nil))
            XCTFail("an oversized body was accepted")
        } catch {
            XCTAssertEqual(error, .bodyTooLarge)
        }
        // Exactly the limit is accepted.
        let atLimit = self.url("at-limit")
        StubURLProtocol.registry.set(.http(status: 200, headers: [:], body: Data(count: ForecastLimits.maximumResponseBytes)), for: atLimit)
        let response = try await transport.send(ForecastFeedClient.request(url: atLimit, ifNoneMatch: nil))
        XCTAssertEqual(response.body.count, ForecastLimits.maximumResponseBytes)
    }

    func testReleasingTheTransportInvalidatesItsSession() async {
        let invalidated = expectation(description: "session invalidated")
        let probe = InvalidationProbe(invalidated)
        let configuration = URLSessionForecastTransport.makeConfiguration()
        configuration.protocolClasses = [StubURLProtocol.self]
        var transport: URLSessionForecastTransport? = URLSessionForecastTransport(
            session: URLSession(configuration: configuration, delegate: probe, delegateQueue: nil)
        )
        XCTAssertNotNil(transport)
        transport = nil
        await fulfillment(of: [invalidated], timeout: 10)
    }

    func testNonHTTPResponseIsATransportError() async {
        let url = url("nothttp")
        StubURLProtocol.registry.set(.notHTTP, for: url)
        do {
            _ = try await transport.send(ForecastFeedClient.request(url: url, ifNoneMatch: nil))
            XCTFail("expected a transport error")
        } catch {
            XCTAssertEqual(error, ForecastTransportError(message: "The response is not HTTP."))
        }
    }

    func testClientEndToEndOverURLSession() async throws {
        let endpoint = try ForecastFeedEndpoint("endtoend.stub.invalid")
        StubURLProtocol.registry.set(.http(status: 200, headers: ["ETag": "\"e1\""], body: try FeedFixtures.data("synthetic_latest_live_format")), for: endpoint.latestURL)
        let client = ForecastFeedClient(endpoint: endpoint, transport: transport, now: { FeedFixtures.instant(FeedFixtures.october8(14, 21)) })
        let first = try await client.fetchLatest()
        XCTAssertEqual(first.zen?.point(at: .thirtyMinutes)?.predictedMgdl, 127.06)

        StubURLProtocol.registry.set(.http(status: 304, headers: ["ETag": "\"e1\""], body: Data()), for: endpoint.latestURL)
        let second = try await client.fetchLatest()
        XCTAssertEqual(second, first)
        let conditions = StubURLProtocol.registry.requests(to: endpoint.latestURL).map { $0.value(forHTTPHeaderField: "If-None-Match") }
        XCTAssertEqual(conditions, [nil, "\"e1\""])
    }

    func testDefaultConfigurationKeepsNothingAndFailsFast() {
        let configuration = URLSessionForecastTransport.makeConfiguration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 10)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 10)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertEqual(URLSessionForecastTransport.timeout, 10)

        let session = URLSessionForecastTransport.makeDefaultSession()
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 10)
        _ = URLSessionForecastTransport()  // the app's default initializer
    }

    func testRedirectsAreRefused() async throws {
        // The target would answer 200; a session that followed the redirect would return it.
        let from = url("redirect")
        let elsewhere = url("elsewhere")
        StubURLProtocol.registry.set(.redirect(to: elsewhere), for: from)
        StubURLProtocol.registry.set(.http(status: 200, headers: [:], body: try FeedFixtures.data("site_latest")), for: elsewhere)

        let response = try await transport.send(ForecastFeedClient.request(url: from, ifNoneMatch: nil))
        XCTAssertEqual(response.statusCode, 301)
        XCTAssertTrue(StubURLProtocol.registry.requests(to: elsewhere).isEmpty, "the redirect was followed")

        // Control: a plain session with the same stub does follow it, so the check above is real.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let (_, followed) = try await URLSession(configuration: configuration).data(from: from)
        XCTAssertEqual((followed as? HTTPURLResponse)?.statusCode, 200)
    }

    func testClientReportsARedirectAsAnHTTPStatus() async throws {
        let endpoint = try ForecastFeedEndpoint("moved.stub.invalid")
        StubURLProtocol.registry.set(.redirect(to: url("elsewhere2")), for: endpoint.latestURL)
        let client = ForecastFeedClient(endpoint: endpoint, transport: transport, now: { FeedFixtures.nowInstant })
        do {
            _ = try await client.fetchLatest()
            XCTFail("a redirect must not produce a forecast")
        } catch {
            XCTAssertEqual(error, .httpStatus(301))
        }
    }
}

/// Reports when its session has been invalidated.
final class InvalidationProbe: NSObject, URLSessionDelegate, Sendable {
    private let invalidated: XCTestExpectation

    init(_ invalidated: XCTestExpectation) { self.invalidated = invalidated }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        invalidated.fulfill()
    }
}
