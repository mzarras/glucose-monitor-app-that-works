import XCTest
import GlucoseCore
@testable import NightscoutKit

/// Nightscout history import (HANDOFF §4.5 steps 1, 3, 5) against `nightscout_entries.json`:
/// duplicates (same ms from two uploaders, and a near-duplicate 2 s apart), mbg/cal entries, a
/// LOW (39), a HIGH (401), a Dexcom error code (5), a one-week gap, and history older than 90 days.
final class NightscoutImportTests: XCTestCase {
    static let now = Fixtures.date("2026-09-20T12:00:00Z")
    static let token = "synthetic-token-1234"

    private func fixtureEntries() throws -> [MockNightscoutServer.Entry] {
        try JSONDecoder().decode([MockNightscoutServer.Entry].self, from: Fixtures.data("nightscout_entries.json"))
    }

    private func makeServer() throws -> MockNightscoutServer {
        MockNightscoutServer(token: Self.token, entries: try fixtureEntries())
    }

    private func makeImporter(
        server: MockNightscoutServer,
        repository: InMemoryGlucoseReadingRepository,
        checkpoints: any NightscoutImportCheckpointStore = InMemoryNightscoutImportCheckpointStore(),
        clock: TestClock = TestClock(NightscoutImportTests.now),
        pageSize: Int = NightscoutHistoryImporter.defaultPageSize,
        token: String? = NightscoutImportTests.token,
        log: any DiagnosticLog = NullDiagnosticLog()
    ) throws -> NightscoutHistoryImporter {
        var credentials: [CredentialKey: String] = [:]
        if let token { credentials[.nightscoutToken] = token }
        return NightscoutHistoryImporter(
            site: try NightscoutSite("https://nightscout.invalid"),
            credentials: InMemoryCredentialStore(credentials),
            repository: repository,
            checkpoints: checkpoints,
            transport: InProcessTransport(backend: server),
            clock: clock,
            log: log,
            pageSize: pageSize
        )
    }

    /// Expected result of the default 90-day import, hand-derived from the fixture.
    private let expected90Days: [(String, GlucoseValue)] = [
        ("2026-07-01T00:00:00Z", .mgdl(180)),
        ("2026-09-01T08:00:00Z", .mgdl(250)),
        ("2026-09-01T08:05:00Z", .mgdl(245)),
        ("2026-09-18T03:00:00Z", .belowRange),   // sgv 39
        ("2026-09-18T15:00:00Z", .aboveRange),   // sgv 401
        ("2026-09-19T10:00:00Z", .mgdl(100)),
        ("2026-09-19T10:05:00Z", .mgdl(104)),    // two uploaders, same ms → one reading
        ("2026-09-19T10:10:00Z", .mgdl(109)),    // 10:10:02 near-duplicate skipped by the store
        ("2026-09-19T10:15:00Z", .mgdl(115)),
        ("2026-09-19T10:20:00Z", .mgdl(121)),
    ]

    private func assertStored(_ repository: InMemoryGlucoseReadingRepository, _ expected: [(String, GlucoseValue)], file: StaticString = #filePath, line: UInt = #line) async {
        let stored = await repository.stored
        XCTAssertEqual(stored.map(\.date), expected.map { Fixtures.date($0.0) }, file: file, line: line)
        XCTAssertEqual(stored.map(\.value), expected.map(\.1), file: file, line: line)
    }

    func test_importsLast90DaysInSevenDayWindowsWithTokenHeader() async throws {
        let server = try makeServer()
        let repository = InMemoryGlucoseReadingRepository()
        let result = try await makeImporter(server: server, repository: repository).run()

        await assertStored(repository, expected90Days)
        XCTAssertEqual(result.phase, .finished)
        XCTAssertEqual(result.readingsImported, 10)
        XCTAssertEqual(result.readingsSkippedByStore, 1, "10:10:02 lies within 150 s of 10:10:00")
        XCTAssertEqual(result.skipped[.errorCode], 1, "sgv 5 is a Dexcom error code")
        XCTAssertEqual(result.coveredTo, Self.now)
        XCTAssertEqual(result.coveredFrom, Self.now.addingTimeInterval(-90 * 86_400))

        let requests = await server.requests
        XCTAssertEqual(requests.count, 13, "90 days = 13 windows of at most 7 days")
        for request in requests {
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.path, "/api/v1/entries.json")
            XCTAssertEqual(request.query("find[type]"), "sgv")
            XCTAssertEqual(request.header("api-secret"), Self.token)
            XCTAssertFalse(request.target.contains(Self.token), "the token never goes in the URL")
            let lower = try XCTUnwrap(request.query("find[date][$gte]").flatMap(Int64.init))
            let upper = try XCTUnwrap(request.query("find[date][$lt]").flatMap(Int64.init))
            XCTAssertLessThanOrEqual(upper - lower, 7 * 86_400_000)
        }
        let first = requests[0]
        XCTAssertEqual(first.query("find[date][$lt]"), String(GlucoseReading.epochMilliseconds(Self.now)))
        XCTAssertEqual(first.query("find[date][$gte]"), String(GlucoseReading.epochMilliseconds(Self.now.addingTimeInterval(-7 * 86_400))))
    }

    func test_S6_nightscoutImporterProducesOnlyImportedReadings() async throws {
        let repository = InMemoryGlucoseReadingRepository()
        try await makeImporter(server: try makeServer(), repository: repository).run(scope: .everything)
        let stored = await repository.stored
        XCTAssertFalse(stored.isEmpty)
        for reading in stored {
            XCTAssertEqual(reading.source, .imported(.nightscout))
            XCTAssertEqual(reading.id, GlucoseReading.importedID(origin: .nightscout, date: reading.date))
            XCTAssertNil(reading.trendRate, "Nightscout has no rate field; directions are buckets")
            XCTAssertFalse(reading.isBackfill)
            XCTAssertEqual(reading.sensorSerial, "")
            XCTAssertThrowsError(try LiveReadingGate.validate(reading, session: SessionFixture().session, now: reading.date))
        }
    }

    func test_S4_nightscoutImportLowHighMapToFlags() async throws {
        let repository = InMemoryGlucoseReadingRepository()
        try await makeImporter(server: try makeServer(), repository: repository).run()
        let stored = await repository.stored
        let low = try XCTUnwrap(stored.first { $0.date == Fixtures.date("2026-09-18T03:00:00Z") })
        let high = try XCTUnwrap(stored.first { $0.date == Fixtures.date("2026-09-18T15:00:00Z") })
        XCTAssertEqual(low.value, .belowRange)
        XCTAssertEqual(high.value, .aboveRange)
        XCTAssertFalse(stored.contains { $0.value == .mgdl(40) || $0.value == .mgdl(400) }, "never clamped")
    }

    func test_everythingFollowsHistoryAcrossGapsAndStops() async throws {
        let server = try makeServer()
        let repository = InMemoryGlucoseReadingRepository()
        let result = try await makeImporter(server: server, repository: repository).run(scope: .everything)

        await assertStored(repository, [("2026-06-01T00:00:00Z", .mgdl(90)), ("2026-06-01T00:05:00Z", .mgdl(95))] + expected90Days)
        XCTAssertEqual(result.phase, .finished)
        XCTAssertNil(result.planStart)
        // Gap jumps: after an empty window, a probe (count=1, no lower bound) finds the newest older
        // entry and the walk resumes 1 ms above it. Windows: W1 data, W2 empty → probe finds
        // 09-01 08:05, W3 data, W4 empty → probe finds 07-01, W5 data, W6 empty → probe finds
        // 06-01 00:05, W7 data, W8 empty → probe finds nothing → done.
        let requests = await server.requests
        let probes = requests.filter { $0.query("count") == "1" }
        XCTAssertEqual(probes.count, 4)
        XCTAssertTrue(probes.allSatisfy { $0.query("find[date][$gte]") == nil && $0.query("find[type]") == "sgv" })
        XCTAssertEqual(requests.count, 12, "8 windows + 4 probes: gaps are skipped, not walked week by week")
        let oldest = GlucoseReading.epochMilliseconds(Fixtures.date("2026-06-01T00:05:00Z"))
        XCTAssertEqual(GlucoseReading.epochMilliseconds(result.coveredFrom), oldest + 1 - 14 * 86_400_000)
    }

    func test_pagesInsideAWindowWithoutLosingEntriesThatShareAMillisecond() async throws {
        let server = try makeServer()
        let repository = InMemoryGlucoseReadingRepository()
        // Window 1 holds 11 sgv entries, two of them at the same millisecond; pages of 3.
        let result = try await makeImporter(server: server, repository: repository, pageSize: 3).run()
        await assertStored(repository, expected90Days)
        XCTAssertEqual(result.readingsImported, 10)
        let window1Requests = await server.requests.filter {
            $0.query("find[date][$gte]") == String(GlucoseReading.epochMilliseconds(Self.now.addingTimeInterval(-7 * 86_400)))
        }
        XCTAssertGreaterThan(window1Requests.count, 3)
    }

    func test_pageTooDenseFailsLoudly() async throws {
        let entries = (0..<3).map { index in
            MockNightscoutServer.Entry(_id: "dense\(index)", type: "sgv", sgv: 100, date: 1_789_812_000_000, device: "x\(index)")
        }
        let server = MockNightscoutServer(token: Self.token, entries: entries)
        let importer = try makeImporter(server: server, repository: InMemoryGlucoseReadingRepository(), pageSize: 2)
        do {
            try await importer.run()
            XCTFail("expected pageTooDense")
        } catch let error as NightscoutImportError {
            XCTAssertEqual(error, .pageTooDense(atMilliseconds: 1_789_812_000_000))
        }
    }

    func test_ignoresMbgAndCalEvenIfServerReturnsThem() async throws {
        let server = try makeServer()
        await server.setIgnoresTypeFilter(true)
        let repository = InMemoryGlucoseReadingRepository()
        let result = try await makeImporter(server: server, repository: repository).run()
        await assertStored(repository, expected90Days)
        XCTAssertEqual(result.skipped[.notSGV], 2, "one mbg, one cal")
    }

    func test_S3_nightscoutImportIsIdempotent() async throws {
        let server = try makeServer()
        let repository = InMemoryGlucoseReadingRepository()
        let checkpoints = InMemoryNightscoutImportCheckpointStore()
        let importer = try makeImporter(server: server, repository: repository, checkpoints: checkpoints)
        try await importer.run()
        let afterFirst = await repository.stored

        // Re-running a finished plan does nothing at all (no requests, no inserts).
        let requestsBefore = await server.requests.count
        let again = try await importer.run()
        XCTAssertEqual(again.phase, .finished)
        let requestsAfterRerun = await server.requests.count
        XCTAssertEqual(requestsAfterRerun, requestsBefore)

        // Starting over (reset) re-fetches everything and stores nothing new.
        try await importer.reset()
        let second = try await importer.run()
        XCTAssertEqual(second.readingsImported, 0)
        XCTAssertEqual(second.readingsSkippedByStore, 11)
        let afterSecond = await repository.stored
        XCTAssertEqual(afterSecond, afterFirst)
    }

    func test_interruptedImportResumesFromCheckpoint() async throws {
        let server = try makeServer()
        let repository = InMemoryGlucoseReadingRepository()
        let checkpoints = InMemoryNightscoutImportCheckpointStore()
        let clock = TestClock(Self.now)
        await server.goOffline(afterRequests: 4)
        let importer = try makeImporter(server: server, repository: repository, checkpoints: checkpoints, clock: clock)
        do {
            try await importer.run()
            XCTFail("expected the import to stop when the network drops")
        } catch let error as NightscoutImportError {
            guard case .nightscout(.transport) = error else { return XCTFail("unexpected \(error)") }
        }
        let saved = try await XCTUnwrapAsync(await checkpoints.checkpoint)
        XCTAssertFalse(saved.isFinished)
        XCTAssertEqual(saved.completedDownTo, Self.now.addingTimeInterval(-4 * 7 * 86_400), "4 windows completed")
        let requestsBeforeResume = await server.requests.count

        // Later (clock moved on), network back: resume continues below the checkpoint, same plan end.
        clock.advance(by: 3_600)
        await server.goOffline(afterRequests: nil)
        let result = try await importer.run()
        XCTAssertEqual(result.phase, .finished)
        XCTAssertEqual(result.coveredTo, Self.now, "the plan keeps its original end")
        await assertStored(repository, expected90Days)
        let resumed = await server.requests.dropFirst(requestsBeforeResume)
        XCTAssertEqual(resumed.count, 9, "13 windows − 4 done")
        for request in resumed {
            let upper = try XCTUnwrap(request.query("find[date][$lt]").flatMap(Int64.init))
            XCTAssertLessThanOrEqual(upper, GlucoseReading.epochMilliseconds(saved.completedDownTo))
        }
    }

    func test_checkpointForAnotherScopeStartsANewPlan() async throws {
        let server = try makeServer()
        let repository = InMemoryGlucoseReadingRepository()
        let checkpoints = InMemoryNightscoutImportCheckpointStore()
        let importer = try makeImporter(server: server, repository: repository, checkpoints: checkpoints)
        try await importer.run(scope: .lastDays(7))
        await XCTAssertEqualAsync(await repository.stored.count, 7)
        let result = try await importer.run(scope: .everything)
        XCTAssertEqual(result.phase, .finished)
        await XCTAssertEqualAsync(await repository.stored.count, 12)
    }

    func test_repositoryFailureStopsWithoutAdvancingCheckpoint() async throws {
        let repository = InMemoryGlucoseReadingRepository()
        await repository.failNextInsert()
        let checkpoints = InMemoryNightscoutImportCheckpointStore()
        let importer = try makeImporter(server: try makeServer(), repository: repository, checkpoints: checkpoints)
        do {
            try await importer.run()
            XCTFail("expected a repository error")
        } catch let error as NightscoutImportError {
            guard case .repository = error else { return XCTFail("unexpected \(error)") }
        }
        let saved = try await XCTUnwrapAsync(await checkpoints.checkpoint)
        XCTAssertEqual(saved.completedDownTo, Self.now, "the failed window is not marked done")
        try await importer.run()
        await assertStored(repository, expected90Days)
    }

    func test_unauthorizedTokenFailsLoudly() async throws {
        let importer = try makeImporter(server: try makeServer(), repository: InMemoryGlucoseReadingRepository(), token: "wrong-token")
        do {
            try await importer.run()
            XCTFail("expected 401")
        } catch let error as NightscoutImportError {
            XCTAssertEqual(error, .nightscout(.unauthorized(statusCode: 401)))
        }
    }

    func test_readsWithoutTokenWhenSiteIsReadable() async throws {
        let server = try makeServer()
        await server.setReadableWithoutToken(true)
        let repository = InMemoryGlucoseReadingRepository()
        try await makeImporter(server: server, repository: repository, token: nil).run()
        await assertStored(repository, expected90Days)
        let headers = await server.requests.map { $0.header("api-secret") }
        XCTAssertTrue(headers.allSatisfy { $0 == nil })
    }

    func test_progressStreamReportsRangeAndCounts() async throws {
        let importer = try makeImporter(server: try makeServer(), repository: InMemoryGlucoseReadingRepository())
        var values: [NightscoutImportProgress] = []
        for try await progress in importer.progressStream() { values.append(progress) }
        XCTAssertEqual(values.count, 14, "initial + one per window")
        XCTAssertEqual(values.first?.readingsImported, 0)
        XCTAssertEqual(values.first?.coveredFrom, Self.now)
        XCTAssertEqual(values.last?.phase, .finished)
        XCTAssertEqual(values.last?.readingsImported, 10)
        XCTAssertEqual(zip(values, values.dropFirst()).filter { $0.coveredFrom < $1.coveredFrom }.count, 0, "coverage only grows")
    }

    func test_concurrentRunIsRefused() async throws {
        let server = try makeServer()
        let importer = try makeImporter(server: server, repository: InMemoryGlucoseReadingRepository())
        async let first: NightscoutImportProgress = importer.run()
        async let second: NightscoutImportProgress = importer.run()
        var outcomes: [Bool] = []
        do { _ = try await first; outcomes.append(true) } catch { XCTAssertEqual(error as? NightscoutImportError, .alreadyRunning); outcomes.append(false) }
        do { _ = try await second; outcomes.append(true) } catch { XCTAssertEqual(error as? NightscoutImportError, .alreadyRunning); outcomes.append(false) }
        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
    }

    func test_userDefaultsCheckpointStoreRoundTrips() throws {
        let suite = "NightscoutKitTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = UserDefaultsNightscoutImportCheckpointStore(suiteName: suite)
        XCTAssertNil(try store.loadCheckpoint())
        let checkpoint = NightscoutImportCheckpoint(
            site: try NightscoutSite("https://nightscout.invalid"), scope: .lastDays(90),
            planEnd: Self.now, planStart: Self.now.addingTimeInterval(-90 * 86_400),
            completedDownTo: Self.now.addingTimeInterval(-7 * 86_400), readingsImported: 12,
            readingsSkippedByStore: 3, skipped: [.errorCode: 1, .notSGV: 2], isFinished: false
        )
        try store.saveCheckpoint(checkpoint)
        XCTAssertEqual(try store.loadCheckpoint(), checkpoint)
        try store.clearCheckpoint()
        XCTAssertNil(try store.loadCheckpoint())
    }
}
