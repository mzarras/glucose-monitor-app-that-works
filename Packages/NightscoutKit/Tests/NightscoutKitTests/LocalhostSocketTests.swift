import XCTest
import GlucoseCore
@testable import NightscoutKit

/// End-to-end over real sockets: `URLSessionTransport` (the production transport) talking to the
/// mock servers on 127.0.0.1. Nothing leaves the machine.
final class LocalhostSocketTests: XCTestCase {
    let fixture = SessionFixture()

    func test_importAndUploadOverLocalhostWithURLSession() async throws {
        let entries = try JSONDecoder().decode([MockNightscoutServer.Entry].self, from: Fixtures.data("nightscout_entries.json"))
        let backend = MockNightscoutServer(token: "synthetic-token-1234", entries: entries)
        let server = try LocalHTTPServer(backend: backend)
        let baseURL = try await server.start()
        defer { server.stop() }
        XCTAssertEqual(baseURL.host, "127.0.0.1")

        let site = try NightscoutSite(url: baseURL)
        let credentials = InMemoryCredentialStore([.nightscoutToken: "synthetic-token-1234"])
        let repository = InMemoryGlucoseReadingRepository()
        let importer = NightscoutHistoryImporter(
            site: site, credentials: credentials, repository: repository,
            checkpoints: InMemoryNightscoutImportCheckpointStore(),
            transport: URLSessionTransport(), clock: TestClock(NightscoutImportTests.now)
        )
        let result = try await importer.run()
        XCTAssertEqual(result.readingsImported, 10)
        XCTAssertEqual(result.readingsSkippedByStore, 1)

        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let uploader = try ReadingUploader.nightscout(
            site: site, credentials: credentials, deviceName: "Sensor", queueDirectory: directory,
            transport: URLSessionTransport(), clock: TestClock(fixture.start.addingTimeInterval(3_600))
        )
        try await uploader.submit(fixture.reading(at: 3_600, value: .belowRange), session: fixture.session)
        await XCTAssertEqualAsync(await uploader.flush(), .uploaded(count: 1))
        let uploaded = await backend.entries.last
        XCTAssertEqual(uploaded?.sgv, 39)
        XCTAssertEqual(uploaded?.device, "Sensor")
        let post = try await XCTUnwrapAsync(await backend.requests.last)
        XCTAssertEqual(post.header("api-secret"), "synthetic-token-1234")
        XCTAssertFalse(post.target.contains("synthetic-token-1234"))
    }

    func test_connectionDroppedIsATransportFailureAndRetrySucceeds() async throws {
        let backend = MockNightscoutServer(token: "synthetic-token-1234")
        await backend.script([.transportFailure("dropped")])
        let server = try LocalHTTPServer(backend: backend)
        let baseURL = try await server.start()
        defer { server.stop() }
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let uploader = try ReadingUploader.nightscout(
            site: try NightscoutSite(url: baseURL),
            credentials: InMemoryCredentialStore([.nightscoutToken: "synthetic-token-1234"]),
            deviceName: "Sensor", queueDirectory: directory,
            transport: URLSessionTransport(), clock: TestClock(fixture.start.addingTimeInterval(3_600))
        )
        try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)
        guard case .failed(let error, _) = await uploader.flush() else { return XCTFail("expected a dropped connection") }
        XCTAssertEqual(error.kind, .transport)
        await XCTAssertEqualAsync(await uploader.flush(), .uploaded(count: 1))
        await XCTAssertEqualAsync(await backend.entries.count, 1)
    }

    func test_dexcomShareOverLocalhostWithURLSession() async throws {
        let backend = MockShareServer()
        let server = try LocalHTTPServer(backend: backend)
        let baseURL = try await server.start()
        defer { server.stop() }
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let uploader = try ReadingUploader.dexcomShare(
            server: DexcomShareServer(baseURL: baseURL.appendingPathComponent("ShareWebServices/Services")),
            receiverSerialNumber: "SM12345678",
            credentials: InMemoryCredentialStore([
                .dexcomShareAccountName: MockShareServer.accountName,
                .dexcomSharePassword: MockShareServer.password,
            ]),
            queueDirectory: directory, transport: URLSessionTransport(),
            clock: TestClock(fixture.start.addingTimeInterval(3_600))
        )
        try await uploader.submit(fixture.reading(at: 3_600, value: .mgdl(101)), session: fixture.session)
        await XCTAssertEqualAsync(await uploader.flush(), .uploaded(count: 1))
        await XCTAssertEqualAsync(await backend.stored.map(\.Value), [101])
    }

    func test_redirectToAnotherPortIsRefusedAndTheTokenStaysHome() async throws {
        // Reviewer m9: URLSession re-sends custom headers (api-secret) on a redirect; the transport
        // only follows same-origin redirects, so a 302 to another port fails instead.
        let elsewhere = MockNightscoutServer(token: "synthetic-token-1234")
        let elsewhereServer = try LocalHTTPServer(backend: elsewhere)
        let elsewhereURL = try await elsewhereServer.start()
        defer { elsewhereServer.stop() }
        let redirector = RedirectingBackend(location: elsewhereURL.appendingPathComponent("api/v1/entries").absoluteString)
        let redirectServer = try LocalHTTPServer(backend: redirector)
        let baseURL = try await redirectServer.start()
        defer { redirectServer.stop() }
        XCTAssertNotEqual(baseURL.port, elsewhereURL.port)

        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let uploader = try ReadingUploader.nightscout(
            site: try NightscoutSite(url: baseURL),
            credentials: InMemoryCredentialStore([.nightscoutToken: "synthetic-token-1234"]),
            deviceName: "Sensor", queueDirectory: directory,
            transport: URLSessionTransport(), clock: TestClock(fixture.start.addingTimeInterval(3_600))
        )
        try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)
        guard case .failed(let error, _) = await uploader.flush() else { return XCTFail("expected the redirect to fail") }
        XCTAssertEqual(error.kind, .server)
        XCTAssertTrue(error.message.contains("302"))
        await XCTAssertEqualAsync(await redirector.requests.count, 1)
        await XCTAssertEqualAsync(await elsewhere.requests.count, 0, "nothing, and no token, reached the other server")
        await XCTAssertEqualAsync(await uploader.status.queueDepth, 1)
    }
}
