// Original to Sensor (no ported code).
import XCTest
import GlucoseCore
@testable import NightscoutKit

/// Nightscout live upload (HANDOFF §8A step 1) against `MockNightscoutServer`, which upserts on
/// `sysTime` + `type` like cgm-remote-monitor.
final class NightscoutUploadTests: XCTestCase {
    static let token = "synthetic-token-1234"
    let fixture = SessionFixture()
    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeUploader(
        server: MockNightscoutServer,
        clock: TestClock,
        token: String? = NightscoutUploadTests.token,
        log: any DiagnosticLog = NullDiagnosticLog(),
        queueDirectory: URL? = nil
    ) throws -> ReadingUploader {
        var credentials: [CredentialKey: String] = [:]
        if let token { credentials[.nightscoutToken] = token }
        return try ReadingUploader.nightscout(
            site: try NightscoutSite("https://nightscout.invalid"),
            credentials: InMemoryCredentialStore(credentials),
            deviceName: "Sensor",
            queueDirectory: queueDirectory ?? directory,
            transport: InProcessTransport(backend: server),
            clock: clock,
            log: log
        )
    }

    /// Clock positioned `offset` seconds into the session.
    private func clock(at offset: TimeInterval) -> TestClock {
        TestClock(fixture.start.addingTimeInterval(offset))
    }

    func test_uploadsOneEntryWithExactFields() async throws {
        let server = MockNightscoutServer(token: Self.token)
        let clock = clock(at: 3_600)
        let uploader = try makeUploader(server: server, clock: clock)
        let reading = fixture.reading(at: 3_600, value: .mgdl(123), trendRate: -2.4)
        try await uploader.submit(reading, session: fixture.session)
        await XCTAssertEqualAsync(await uploader.status.queueDepth, 1)

        let outcome = await uploader.flushIfDue()
        XCTAssertEqual(outcome, .uploaded(count: 1))
        let entries = await server.entries
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.type, "sgv")
        XCTAssertEqual(entry.sgv, 123)
        XCTAssertEqual(entry.direction, "SingleDown")
        XCTAssertEqual(entry.date, Double(GlucoseReading.epochMilliseconds(reading.date)))
        XCTAssertEqual(entry.dateString, "2026-09-20T01:00:00.000Z")
        XCTAssertEqual(entry.device, "Sensor")

        let request = try await XCTUnwrapAsync(await server.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v1/entries")
        XCTAssertEqual(request.header("api-secret"), Self.token)
        XCTAssertEqual(request.header("content-type"), "application/json")
        XCTAssertFalse(request.target.contains(Self.token))

        let status = await uploader.status
        XCTAssertEqual(status.queueDepth, 0)
        XCTAssertEqual(status.lastSuccessAt, clock.now())
        XCTAssertFalse(status.isFailing)
    }

    func test_S4_nightscoutUploadEncodesFlagsAs39And401NotClamped() async throws {
        let server = MockNightscoutServer(token: Self.token)
        let uploader = try makeUploader(server: server, clock: clock(at: 7_200))
        try await uploader.submit(fixture.reading(at: 6_600, value: .belowRange, trendRate: -1.0), session: fixture.session)
        try await uploader.submit(fixture.reading(at: 6_900, value: .aboveRange, trendRate: nil), session: fixture.session)
        try await uploader.submit(fixture.reading(at: 7_200, value: .mgdl(40)), session: fixture.session)
        await uploader.flush()
        let sgvs = await server.entries.sorted { ($0.date ?? 0) < ($1.date ?? 0) }.map(\.sgv)
        XCTAssertEqual(sgvs, [39, 401, 40], "LOW → 39 and HIGH → 401 (Nightscout's LOW/HIGH), never 40/400")
    }

    func test_S3_backfillUploadKeepsOriginalTimestamp() async throws {
        let server = MockNightscoutServer(token: Self.token)
        let clock = clock(at: 10 * 3_600)
        let uploader = try makeUploader(server: server, clock: clock)
        // Live reading now, then two backfilled readings from 3 hours earlier arrive.
        let live = fixture.reading(at: 10 * 3_600, value: .mgdl(140))
        let backfill1 = fixture.reading(at: 7 * 3_600, value: .mgdl(150), isBackfill: true)
        let backfill2 = fixture.reading(at: 7 * 3_600 + 300, value: .mgdl(152), isBackfill: true)
        try await uploader.submit(live, session: fixture.session)
        try await uploader.submit(backfill1, session: fixture.session)
        try await uploader.submit(backfill2, session: fixture.session)
        await uploader.flush()
        let dates = Set(await server.entries.compactMap(\.date))
        XCTAssertEqual(dates, Set([live, backfill1, backfill2].map { Double(GlucoseReading.epochMilliseconds($0.date)) }))
        let strings = Set(await server.entries.compactMap(\.dateString))
        XCTAssertTrue(strings.contains("2026-09-20T07:00:00.000Z"), "backfill keeps its own time, not the upload time")
    }

    func test_S3_nightscoutRetryDoesNotDuplicateEntries() async throws {
        // The server stores the batch but the response is lost (502). The retry re-sends the same
        // entries; Nightscout's sysTime+type upsert keeps one copy each.
        let server = MockNightscoutServer(token: Self.token)
        await server.storeThenFail([502])
        let clock = clock(at: 3_600)
        let uploader = try makeUploader(server: server, clock: clock)
        try await uploader.submit(fixture.reading(at: 3_300), session: fixture.session)
        try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)

        guard case .failed(let error, 0) = await uploader.flushIfDue() else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .server)
        await XCTAssertEqualAsync(await server.entries.count, 2, "stored despite the failed response")
        await XCTAssertEqualAsync(await uploader.status.queueDepth, 2, "the client cannot know; it keeps them")

        clock.advance(by: 31)
        await XCTAssertEqualAsync(await uploader.flushIfDue(), .uploaded(count: 2))
        await XCTAssertEqualAsync(await server.entries.count, 2, "no duplicates after the retry")
        // Nightscout dedupes only on an exact sysTime + type match, so the retry must be the same
        // bytes, dateString included.
        let posts = await server.requests.filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].body, posts[1].body, "retry body is byte-identical")
        XCTAssertTrue(String(decoding: posts[0].body, as: UTF8.self).contains(#""dateString":"2026-09-20T00:55:00.000Z""#))

        // A backfilled copy of an already-uploaded reading (same sensor timestamp) is also harmless.
        try await uploader.submit(fixture.reading(at: 3_300, isBackfill: true), session: fixture.session)
        await uploader.flush()
        await XCTAssertEqualAsync(await server.entries.count, 2)
    }

    func test_submitIsIdempotentInTheQueue() async throws {
        let uploader = try makeUploader(server: MockNightscoutServer(token: Self.token), clock: clock(at: 3_600))
        let reading = fixture.reading(at: 3_600)
        try await uploader.submit(reading, session: fixture.session)
        try await uploader.submit(reading, session: fixture.session)
        await XCTAssertEqualAsync(await uploader.status.queueDepth, 1)
    }

    func test_S5_nightscoutFailureSurfacesInStatus() async throws {
        let server = MockNightscoutServer(token: Self.token)
        let log = RecordingDiagnosticLog()
        let clock = clock(at: 3_600)
        let uploader = try makeUploader(server: server, clock: clock, token: "revoked-token", log: log)
        try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)

        guard case .failed(let error, _) = await uploader.flushIfDue() else { return XCTFail("expected 401") }
        XCTAssertEqual(error.kind, .unauthorized)
        let status = await uploader.status
        XCTAssertTrue(status.isFailing)
        XCTAssertEqual(status.consecutiveFailures, 1)
        XCTAssertEqual(status.totalFailures, 1)
        XCTAssertEqual(status.lastError?.kind, .unauthorized)
        XCTAssertEqual(status.lastErrorAt, clock.now())
        XCTAssertEqual(status.queueDepth, 1)
        XCTAssertNil(status.lastSuccessAt)
        XCTAssertEqual(status.nextAttemptAt, clock.now().addingTimeInterval(RetryPolicy.default.authenticationFailureDelay))
        XCTAssertTrue(log.messages.contains { $0.contains("Nightscout: upload failed") })
        XCTAssertFalse(log.messages.contains { $0.contains("revoked-token") }, "the token never reaches diagnostics")

        // Backing off: flushIfDue does not hammer the server.
        clock.advance(by: 60)
        guard case .deferred = await uploader.flushIfDue() else { return XCTFail("expected deferral") }
        await XCTAssertEqualAsync(await server.requests.count, 1)
    }

    func test_S5_missingTokenSurfacesInStatus() async throws {
        let uploader = try makeUploader(server: MockNightscoutServer(token: Self.token), clock: clock(at: 3_600), token: nil)
        try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)
        guard case .failed(let error, _) = await uploader.flush() else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .missingCredentials)
        await XCTAssertTrueAsync(await uploader.status.isFailing)
    }

    func test_serverErrorRetriesWithBackoffThenRecovers() async throws {
        let server = MockNightscoutServer(token: Self.token)
        await server.script([.status(500), .status(503)])
        let clock = clock(at: 3_600)
        let uploader = try makeUploader(server: server, clock: clock)
        try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)

        guard case .failed = await uploader.flushIfDue() else { return XCTFail("expected 500") }
        await XCTAssertEqualAsync(await uploader.status.nextAttemptAt, clock.now().addingTimeInterval(30))
        clock.advance(by: 29)
        guard case .deferred = await uploader.flushIfDue() else { return XCTFail("expected deferral") }
        clock.advance(by: 1)
        guard case .failed = await uploader.flushIfDue() else { return XCTFail("expected 503") }
        await XCTAssertEqualAsync(await uploader.status.consecutiveFailures, 2)
        await XCTAssertEqualAsync(await uploader.status.nextAttemptAt, clock.now().addingTimeInterval(60))
        clock.advance(by: 60)
        await XCTAssertEqualAsync(await uploader.flushIfDue(), .uploaded(count: 1))
        let status = await uploader.status
        XCTAssertEqual(status.consecutiveFailures, 0)
        XCTAssertEqual(status.totalFailures, 2)
        XCTAssertFalse(status.isFailing)
        XCTAssertNil(status.nextAttemptAt)
        await XCTAssertEqualAsync(await server.entries.count, 1)
    }

    func test_offlineQueueDrainsInOneBatchWhenBackOnline() async throws {
        let server = MockNightscoutServer(token: Self.token)
        await server.goOffline(afterRequests: 0)
        let clock = clock(at: 3_600)
        let uploader = try makeUploader(server: server, clock: clock)
        for step in 0..<6 {
            try await uploader.submit(fixture.reading(at: 3_600 + Double(step) * 300), session: fixture.session)
            guard case .failed(let error, _) = await uploader.flush() else { return XCTFail("expected offline") }
            XCTAssertEqual(error.kind, .transport)
            clock.advance(by: 300)
        }
        await XCTAssertEqualAsync(await uploader.status.queueDepth, 6)
        await server.goOffline(afterRequests: nil)
        await XCTAssertEqualAsync(await uploader.flushIfDue(), .uploaded(count: 6))
        await XCTAssertEqualAsync(await server.entries.count, 6)
        let posts = await server.requests.filter { $0.method == "POST" }
        XCTAssertEqual(posts.last.flatMap { try? JSONSerialization.jsonObject(with: $0.body) as? [Any] }?.count, 6, "one batch")
    }

    func test_queueSurvivesRelaunch() async throws {
        let server = MockNightscoutServer(token: Self.token)
        await server.goOffline(afterRequests: 0)
        let clock = clock(at: 3_600)
        do {
            let uploader = try makeUploader(server: server, clock: clock)
            try await uploader.submit(fixture.reading(at: 3_300), session: fixture.session)
            try await uploader.submit(fixture.reading(at: 3_600, isBackfill: true), session: fixture.session)
            await uploader.flush()
        }
        await server.goOffline(afterRequests: nil)
        var lastSuccess: Date?
        do {
            let relaunched = try makeUploader(server: server, clock: clock)
            await XCTAssertEqualAsync(await relaunched.status.queueDepth, 2)
            await XCTAssertEqualAsync(await relaunched.flush(), .uploaded(count: 2))
            await XCTAssertEqualAsync(await server.entries.count, 2)
            lastSuccess = await relaunched.status.lastSuccessAt
        }

        let again = try makeUploader(server: server, clock: clock)
        await XCTAssertEqualAsync(await again.status.queueDepth, 0)
        await XCTAssertEqualAsync(await again.status.lastSuccessAt, lastSuccess, "last success survives relaunch")
    }

    func test_largeBacklogIsSentInBatchesOf100() async throws {
        let server = MockNightscoutServer(token: Self.token)
        let clock = clock(at: 2 * 86_400)
        let uploader = try makeUploader(server: server, clock: clock)
        for index in 0..<250 {
            try await uploader.submit(fixture.reading(at: 3_600 + Double(index) * 300, isBackfill: true), session: fixture.session)
        }
        await XCTAssertEqualAsync(await uploader.flush(), .uploaded(count: 250))
        let sizes = await server.requests.compactMap { (try? JSONSerialization.jsonObject(with: $0.body) as? [Any])?.count }
        XCTAssertEqual(sizes, [100, 100, 50])
        await XCTAssertEqualAsync(await server.entries.count, 250)
    }

    func test_S5_unreadableQueueFileSurfacesInStatus() async throws {
        let file = directory.appendingPathComponent("nightscout-upload-queue.json")
        try Data("not json".utf8).write(to: file)
        let log = RecordingDiagnosticLog()
        let uploader = try makeUploader(server: MockNightscoutServer(token: Self.token), clock: clock(at: 3_600), log: log)
        let status = await uploader.status
        XCTAssertTrue(status.isFailing)
        XCTAssertNotNil(status.queueLoadProblem)
        XCTAssertTrue(log.messages.contains { $0.contains("unreadable") })
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains("unreadable") }
        XCTAssertEqual(quarantined.count, 1, "kept for diagnostics, not deleted")
        // Still works.
        try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)
        await XCTAssertEqualAsync(await uploader.flush(), .uploaded(count: 1))
    }

    func test_S5_statusStreamReportsFailureAndRecovery() async throws {
        let server = MockNightscoutServer(token: Self.token)
        await server.script([.status(500)])
        let clock = clock(at: 3_600)
        let uploader = try makeUploader(server: server, clock: clock)
        let stream = await uploader.statusUpdates()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.isFailing, false)

        try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)
        _ = await iterator.next()
        await uploader.flush()
        let failing = await iterator.next()
        XCTAssertEqual(failing?.isFailing, true)
        XCTAssertEqual(failing?.lastError?.kind, .server)

        await uploader.flush()
        let recovered = await iterator.next()
        XCTAssertEqual(recovered?.isFailing, false)
        XCTAssertEqual(recovered?.queueDepth, 0)
        XCTAssertEqual(recovered?.lastSuccessAt, clock.now())
    }

    func test_S6_queuedNonSensorReadingIsDiscardedNotUploaded() async throws {
        // A queue file altered outside the app (the only way a non-sensor reading could be in it).
        let imported = GlucoseReading(
            id: "imported:nightscout:1", date: fixture.start.addingTimeInterval(3_600), value: .mgdl(100),
            trendRate: nil, isBackfill: false, source: .imported(.nightscout), sensorSerial: ""
        )
        let replay = fixture.reading(at: 3_300, source: .replay)
        let file = """
        {"version":1,"items":[{"reading":\(String(data: try JSONEncoder().encode(imported), encoding: .utf8)!),"enqueuedAt":0},
        {"reading":\(String(data: try JSONEncoder().encode(replay), encoding: .utf8)!),"enqueuedAt":0}]}
        """
        try Data(file.utf8).write(to: directory.appendingPathComponent("nightscout-upload-queue.json"))
        let server = MockNightscoutServer(token: Self.token)
        let log = RecordingDiagnosticLog()
        let uploader = try makeUploader(server: server, clock: clock(at: 3_600), log: log)
        await XCTAssertEqualAsync(await uploader.status.queueDepth, 2)
        await XCTAssertEqualAsync(await uploader.flush(), .nothingQueued)
        await XCTAssertEqualAsync(await server.requests.count, 0)
        await XCTAssertEqualAsync(await uploader.status.discarded, 2)
        XCTAssertTrue(log.messages.contains { $0.contains("non-sensor") })
    }

    func test_concurrentFlushesSendOnce() async throws {
        // Deterministic: the first flush is held inside its POST, so the second provably overlaps it.
        let server = MockNightscoutServer(token: Self.token)
        await server.holdNextRequest()
        let uploader = try makeUploader(server: server, clock: clock(at: 3_600))
        try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)
        let first = Task { await uploader.flush() }
        await server.waitUntilHoldingRequest()

        await XCTAssertEqualAsync(await uploader.flush(), .alreadyFlushing)

        await server.releaseHeldRequest()
        await XCTAssertEqualAsync(await first.value, .uploaded(count: 1))
        await XCTAssertEqualAsync(await server.requests.count, 1)
        await XCTAssertEqualAsync(await uploader.flush(), .nothingQueued)
    }

    func test_S5_failureAndBackoffSurviveRelaunch() async throws {
        // Reviewer m2: a relaunch must not reset the S5 banner or skip the backoff.
        let server = MockNightscoutServer(token: Self.token)
        let clock = clock(at: 3_600)
        var nextAttempt: Date?
        do {
            let uploader = try makeUploader(server: server, clock: clock, token: "revoked-token")
            try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)
            guard case .failed = await uploader.flushIfDue() else { return XCTFail("expected 401") }
            nextAttempt = await uploader.status.nextAttemptAt
        }
        clock.advance(by: 60)
        let relaunched = try makeUploader(server: server, clock: clock, token: "revoked-token")
        let status = await relaunched.status
        XCTAssertTrue(status.isFailing)
        XCTAssertEqual(status.consecutiveFailures, 1)
        XCTAssertEqual(status.lastError?.kind, .unauthorized)
        XCTAssertEqual(status.nextAttemptAt, nextAttempt)
        guard case .deferred = await relaunched.flushIfDue() else { return XCTFail("relaunch must respect the backoff") }
        await XCTAssertEqualAsync(await server.requests.count, 1, "no extra attempt with the rejected token")
    }

    func test_S5_nightscoutNonJSONSuccessIsNotTreatedAsStored() async throws {
        // Reviewer m4: a 2xx that is not Nightscout's JSON array (captive portal, proxy page) must
        // not drop the readings from the queue.
        let server = MockNightscoutServer(token: Self.token)
        await server.script([.status(200, body: "<html>Sign in to Wi-Fi</html>")])
        let uploader = try makeUploader(server: server, clock: clock(at: 3_600))
        try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)
        guard case .failed(let error, _) = await uploader.flush() else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .server)
        await XCTAssertEqualAsync(await uploader.status.queueDepth, 1)
        await XCTAssertTrueAsync(await uploader.status.isFailing)
        await XCTAssertEqualAsync(await uploader.flush(), .uploaded(count: 1))
    }

    func test_S5_refusalsSurfaceUntilAnUploadSucceeds() async throws {
        // Reviewer m5.
        let server = MockNightscoutServer(token: Self.token)
        let clock = clock(at: 20 * 60)
        let uploader = try makeUploader(server: server, clock: clock)
        do {
            try await uploader.submit(fixture.reading(at: 20 * 60), session: fixture.session)
            XCTFail("warm-up reading accepted")
        } catch {
            XCTAssertEqual(error, .gate(.duringWarmUp))
        }
        var status = await uploader.status
        XCTAssertEqual(status.lastRefusal, .gate(.duringWarmUp))
        XCTAssertEqual(status.lastRefusedAt, clock.now())
        XCTAssertEqual(status.refusalsSinceLastSuccess, 1)
        XCTAssertTrue(status.isFailing, "readings refused and nothing uploaded since")

        clock.advance(by: 15 * 60)
        try await uploader.submit(fixture.reading(at: 35 * 60), session: fixture.session)
        await XCTAssertEqualAsync(await uploader.flush(), .uploaded(count: 1))
        status = await uploader.status
        XCTAssertFalse(status.isFailing)
        XCTAssertEqual(status.refusalsSinceLastSuccess, 0)
        XCTAssertEqual(status.lastRefusal, .gate(.duringWarmUp), "kept for Settings")
    }

    func test_onlyOneUploaderPerQueueFile() async throws {
        // Reviewer m7: two owners would each rewrite the file from their own memory.
        let server = MockNightscoutServer(token: Self.token)
        let clock = clock(at: 3_600)
        do {
            let first = try makeUploader(server: server, clock: clock)
            XCTAssertThrowsError(try makeUploader(server: server, clock: clock)) { error in
                XCTAssertNotNil(error as? QueueFileInUse)
            }
            try await first.submit(fixture.reading(at: 3_600), session: fixture.session)
        }
        let next = try makeUploader(server: server, clock: clock)
        await XCTAssertEqualAsync(await next.status.queueDepth, 1, "the file is free again once the first uploader is gone")
    }
}
