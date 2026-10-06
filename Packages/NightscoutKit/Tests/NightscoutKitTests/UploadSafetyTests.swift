// Original to Sensor (no ported code).
import XCTest
import GlucoseCore
@testable import NightscoutKit

/// S2 and S6 for both uploaders: only authenticated, valid, live sensor readings are ever queued.
/// Each case checks the refusal, that nothing was queued, and that nothing reached the server.
final class UploadSafetyTests: XCTestCase {
    let fixture = SessionFixture()
    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Both uploaders, each with its mock server, sharing one clock.
    private func uploaders(clock: TestClock) throws -> [(ReadingUploader, @Sendable () async -> Int)] {
        let nightscout = MockNightscoutServer(token: "synthetic-token-1234")
        let share = MockShareServer()
        let nightscoutUploader = try ReadingUploader.nightscout(
            site: try NightscoutSite("https://nightscout.invalid"),
            credentials: InMemoryCredentialStore([.nightscoutToken: "synthetic-token-1234"]),
            deviceName: "Sensor",
            queueDirectory: directory.appendingPathComponent(UUID().uuidString),
            transport: InProcessTransport(backend: nightscout),
            clock: clock
        )
        let shareUploader = try ReadingUploader.dexcomShare(
            server: DexcomShareServer(baseURL: URL(string: "https://share.invalid/ShareWebServices/Services")!),
            receiverSerialNumber: "SM12345678",
            credentials: InMemoryCredentialStore([
                .dexcomShareAccountName: MockShareServer.accountName,
                .dexcomSharePassword: MockShareServer.password,
            ]),
            queueDirectory: directory.appendingPathComponent(UUID().uuidString),
            transport: InProcessTransport(backend: share),
            clock: clock
        )
        return [
            (nightscoutUploader, { await nightscout.requests.count }),
            (shareUploader, { await share.requests.count }),
        ]
    }

    /// Submits `reading` to both uploaders and asserts each refuses it with `expected`, queues
    /// nothing, and sends nothing even when flushed.
    private func assertBothRefuse(
        _ reading: GlucoseReading,
        session: SensorSession?,
        clock: TestClock,
        expected: LiveReadingGate.Rejection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for (uploader, requestCount) in try uploaders(clock: clock) {
            do {
                try await uploader.submit(reading, session: session)
                XCTFail("\(uploader.destinationName) accepted \(reading.source) \(reading.value)", file: file, line: line)
            } catch {
                XCTAssertEqual(error, .gate(expected), uploader.destinationName, file: file, line: line)
            }
            let status = await uploader.status
            XCTAssertEqual(status.queueDepth, 0, file: file, line: line)
            XCTAssertEqual(status.refusedByGate, 1, file: file, line: line)
            await XCTAssertEqualAsync(await uploader.flush(), .nothingQueued, file: file, line: line)
            await XCTAssertEqualAsync(await requestCount(), 0, "\(uploader.destinationName) sent something", file: file, line: line)
        }
    }

    // MARK: - S6

    func test_S6_nightscoutUploaderRefusesImportedReplayAndMock() async throws {
        try await assertNonSensorSourcesRefused(destinationIndex: 0)
    }

    func test_S6_dexcomShareUploaderRefusesImportedReplayAndMock() async throws {
        try await assertNonSensorSourcesRefused(destinationIndex: 1)
    }

    private func assertNonSensorSourcesRefused(destinationIndex: Int) async throws {
        let clock = TestClock(fixture.start.addingTimeInterval(3_600))
        for source: ReadingSource in [.imported(.nightscout), .imported(.clarityCSV), .replay, .mock] {
            let (uploader, requestCount) = try uploaders(clock: clock)[destinationIndex]
            // Everything else about the reading is valid: only the source is wrong.
            let reading = fixture.reading(at: 3_600, source: source)
            do {
                try await uploader.submit(reading, session: fixture.session)
                XCTFail("\(uploader.destinationName) accepted a \(source) reading")
            } catch {
                XCTAssertEqual(error, .gate(.notLiveSensor(source)))
            }
            await XCTAssertEqualAsync(await uploader.status.queueDepth, 0)
            await XCTAssertEqualAsync(await uploader.flush(), .nothingQueued)
            await XCTAssertEqualAsync(await requestCount(), 0)
        }
    }

    func test_S6_liveSensorReadingIsAcceptedByBoth() async throws {
        // Control: the same builder with `.sensor` goes through, so the refusals above are about source.
        let clock = TestClock(fixture.start.addingTimeInterval(3_600))
        for (uploader, requestCount) in try uploaders(clock: clock) {
            try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)
            await XCTAssertEqualAsync(await uploader.flush(), .uploaded(count: 1), uploader.destinationName)
            await XCTAssertGreaterThanAsync(await requestCount(), 0)
        }
    }

    // MARK: - S2

    func test_S2_uploadersRefuseWarmUpReading() async throws {
        let clock = TestClock(fixture.start.addingTimeInterval(20 * 60))
        try await assertBothRefuse(fixture.reading(at: 20 * 60), session: fixture.session, clock: clock, expected: .duringWarmUp)
    }

    func test_S2_uploadersRefuseReadingWithoutSession() async throws {
        let clock = TestClock(fixture.start.addingTimeInterval(3_600))
        try await assertBothRefuse(fixture.reading(at: 3_600), session: nil, clock: clock, expected: .noSession)
    }

    func test_S2_uploadersRefuseFutureReading() async throws {
        let clock = TestClock(fixture.start.addingTimeInterval(3_600))
        let future = fixture.reading(at: 3_600 + LiveReadingGate.futureTolerance + 1)
        try await assertBothRefuse(future, session: fixture.session, clock: clock, expected: .inFuture)
    }

    func test_S2_uploadersRefuseReadingFromAnotherSensor() async throws {
        let clock = TestClock(fixture.start.addingTimeInterval(3_600))
        try await assertBothRefuse(
            fixture.reading(at: 3_600, serial: "OTHER1"), session: fixture.session, clock: clock,
            expected: .serialMismatch(readingSerial: "OTHER1", sessionSerial: SessionFixture.serial)
        )
    }

    func test_S2_uploadersRefuseExpiredSessionReading() async throws {
        let offset: TimeInterval = 10 * 86_400 + 12 * 3_600 + 60
        let clock = TestClock(fixture.start.addingTimeInterval(offset))
        try await assertBothRefuse(fixture.reading(at: offset), session: fixture.session, clock: clock, expected: .afterSessionEnd)
    }

    func test_S2_uploadersRefuseReadingBeforeSessionStart() async throws {
        let clock = TestClock(fixture.start.addingTimeInterval(3_600))
        let early = GlucoseReading(
            id: "SYNTHG7:early", date: fixture.start.addingTimeInterval(-300), value: .mgdl(120), trendRate: 0,
            isBackfill: true, source: .sensor, sensorSerial: SessionFixture.serial
        )
        try await assertBothRefuse(early, session: fixture.session, clock: clock, expected: .beforeSessionStart)
    }

    func test_S2_uploadersRefuseImplausibleValue() async throws {
        let clock = TestClock(fixture.start.addingTimeInterval(3_600))
        for value in [0, 39, 401, 4_095] {
            try await assertBothRefuse(fixture.reading(at: 3_600, value: .mgdl(value)), session: fixture.session, clock: clock, expected: .implausibleValue(value))
        }
    }

    func test_S2_uploadersRefuseNonFiniteTrendRate() async throws {
        let clock = TestClock(fixture.start.addingTimeInterval(3_600))
        for rate in [Double.nan, .infinity, -.infinity] {
            try await assertBothRefuse(fixture.reading(at: 3_600, trendRate: rate), session: fixture.session, clock: clock, expected: .nonFiniteTrendRate)
        }
    }

    func test_S2_uploadersRefuseMalformedSession() async throws {
        let clock = TestClock(fixture.start.addingTimeInterval(3_600))
        let start = fixture.start
        let malformed = [
            SensorSession(serial: "", start: start, warmUpEndsAt: start.addingTimeInterval(1_800), expiresAt: start.addingTimeInterval(864_000), gracePeriodEndsAt: start.addingTimeInterval(907_200)),
            SensorSession(serial: SessionFixture.serial, start: start, warmUpEndsAt: start.addingTimeInterval(1_800), expiresAt: start.addingTimeInterval(1_000), gracePeriodEndsAt: start.addingTimeInterval(907_200)),
        ]
        for session in malformed {
            try await assertBothRefuse(fixture.reading(at: 3_600), session: session, clock: clock, expected: .malformedSession)
        }
    }

    func test_S2_queuedReadingWithImplausibleDateIsDiscardedNotCrashing() async throws {
        // Audit m6: an altered queue file with absurd dates must not trap in the epoch-ms
        // conversion of either payload encoder; such readings are discarded and counted.
        let clock = TestClock(fixture.start.addingTimeInterval(3_600))
        let absurd = [1e17, -1e17, 3_600 + LiveReadingGate.futureTolerance + 1].map { offset in
            GlucoseReading(
                id: "\(SessionFixture.serial):\(offset)", date: offset > 1e14 || offset < -1e14 ? Date(timeIntervalSince1970: offset) : fixture.start.addingTimeInterval(offset),
                value: .mgdl(120), trendRate: 0, isBackfill: false, source: .sensor, sensorSerial: SessionFixture.serial
            )
        }
        let valid = fixture.reading(at: 3_600)
        let items = try (absurd + [valid]).map { reading in
            "{\"reading\":\(String(decoding: try JSONEncoder().encode(reading), as: UTF8.self)),\"enqueuedAt\":0}"
        }
        let file = Data("{\"version\":1,\"items\":[\(items.joined(separator: ","))]}".utf8)
        let nightscoutDirectory = directory.appendingPathComponent(UUID().uuidString)
        let shareDirectory = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: nightscoutDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shareDirectory, withIntermediateDirectories: true)
        try file.write(to: nightscoutDirectory.appendingPathComponent("nightscout-upload-queue.json"))
        try file.write(to: shareDirectory.appendingPathComponent("dexcom-share-upload-queue.json"))

        let nightscout = MockNightscoutServer(token: "synthetic-token-1234")
        let share = MockShareServer()
        let uploaders = [
            try ReadingUploader.nightscout(
                site: try NightscoutSite("https://nightscout.invalid"),
                credentials: InMemoryCredentialStore([.nightscoutToken: "synthetic-token-1234"]),
                deviceName: "Sensor", queueDirectory: nightscoutDirectory,
                transport: InProcessTransport(backend: nightscout), clock: clock
            ),
            try ReadingUploader.dexcomShare(
                server: DexcomShareServer(baseURL: URL(string: "https://share.invalid/ShareWebServices/Services")!),
                receiverSerialNumber: "SM12345678",
                credentials: InMemoryCredentialStore([.dexcomShareAccountName: MockShareServer.accountName, .dexcomSharePassword: MockShareServer.password]),
                queueDirectory: shareDirectory, transport: InProcessTransport(backend: share), clock: clock
            ),
        ]
        for uploader in uploaders {
            await XCTAssertEqualAsync(await uploader.status.queueDepth, 4)
            await XCTAssertEqualAsync(await uploader.flush(), .uploaded(count: 1), uploader.destinationName)
            await XCTAssertEqualAsync(await uploader.status.discarded, 3, uploader.destinationName)
        }
        await XCTAssertEqualAsync(await nightscout.entries.count, 1)
        await XCTAssertEqualAsync(await share.stored.count, 1)
    }
}
