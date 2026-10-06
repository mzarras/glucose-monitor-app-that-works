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

    /// Both uploaders, each reading its queue from a file written here.
    private func uploaders(queueFile contents: Data?, clock: TestClock) throws -> [(ReadingUploader, @Sendable () async -> Int)] {
        let nightscoutDirectory = directory.appendingPathComponent(UUID().uuidString)
        let shareDirectory = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: nightscoutDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shareDirectory, withIntermediateDirectories: true)
        if let contents {
            try contents.write(to: nightscoutDirectory.appendingPathComponent("nightscout-upload-queue.json"))
            try contents.write(to: shareDirectory.appendingPathComponent("dexcom-share-upload-queue.json"))
        }
        let nightscout = MockNightscoutServer(token: "synthetic-token-1234")
        let share = MockShareServer()
        return [
            (try ReadingUploader.nightscout(
                site: try NightscoutSite("https://nightscout.invalid"),
                credentials: InMemoryCredentialStore([.nightscoutToken: "synthetic-token-1234"]),
                deviceName: "Sensor", queueDirectory: nightscoutDirectory,
                transport: InProcessTransport(backend: nightscout), clock: clock
            ), { await nightscout.entries.count }),
            (try ReadingUploader.dexcomShare(
                server: DexcomShareServer(baseURL: URL(string: "https://share.invalid/ShareWebServices/Services")!),
                receiverSerialNumber: "SM12345678",
                credentials: InMemoryCredentialStore([.dexcomShareAccountName: MockShareServer.accountName, .dexcomSharePassword: MockShareServer.password]),
                queueDirectory: shareDirectory, transport: InProcessTransport(backend: share), clock: clock
            ), { await share.stored.count }),
        ]
    }

    func test_S2_queuedReadingWithImplausibleDateIsDiscardedNotCrashing() async throws {
        // Audit m6 + review m3: absurd dates (before 1970, more than a day ahead) are discarded
        // and counted — they must not trap in either payload encoder's epoch-ms conversion. A date
        // just ahead of the clock is held, not discarded, and sent once the clock passes it.
        let clock = TestClock(fixture.start.addingTimeInterval(3_600))
        func reading(id: String, date: Date) -> GlucoseReading {
            GlucoseReading(id: id, date: date, value: .mgdl(120), trendRate: 0, isBackfill: false, source: .sensor, sensorSerial: SessionFixture.serial)
        }
        let queued = [
            reading(id: "absurd-future", date: Date(timeIntervalSince1970: 1e17)),
            reading(id: "absurd-past", date: Date(timeIntervalSince1970: -1e17)),
            reading(id: "two-days-ahead", date: clock.now().addingTimeInterval(2 * 86_400)),
            reading(id: "61-s-ahead", date: clock.now().addingTimeInterval(LiveReadingGate.futureTolerance + 1)),
            fixture.reading(at: 3_600),
        ]
        let items = try queued.map { "{\"reading\":\(String(decoding: try JSONEncoder().encode($0), as: UTF8.self)),\"enqueuedAt\":0}" }
        let file = Data("{\"version\":1,\"items\":[\(items.joined(separator: ","))]}".utf8)
        let pairs = try uploaders(queueFile: file, clock: clock)
        for (uploader, sentCount) in pairs {
            await XCTAssertEqualAsync(await uploader.status.queueDepth, 5)
            await XCTAssertEqualAsync(await uploader.flush(), .uploaded(count: 1), uploader.destinationName)
            let status = await uploader.status
            XCTAssertEqual(status.discarded, 3, uploader.destinationName)
            XCTAssertEqual(status.heldInFuture, 1, uploader.destinationName)
            XCTAssertEqual(status.queueDepth, 1, uploader.destinationName)
            XCTAssertTrue(status.isFailing, "held readings are not reaching followers (S5)")
            XCTAssertNotNil(status.lastDiscardReason)
            await XCTAssertEqualAsync(await sentCount(), 1, uploader.destinationName)
        }
        clock.advance(by: 2)
        for (uploader, sentCount) in pairs {
            await XCTAssertEqualAsync(await uploader.flush(), .uploaded(count: 1), uploader.destinationName)
            await XCTAssertEqualAsync(await sentCount(), 2, uploader.destinationName)
            await XCTAssertEqualAsync(await uploader.status.heldInFuture, 0, uploader.destinationName)
            await XCTAssertFalseAsync(await uploader.status.isFailing, uploader.destinationName)
        }
    }

    func test_S2_readingDatedInFutureAfterClockCorrectionIsHeldThenSent() async throws {
        // Review m3, probe P9: a valid reading is queued, then the phone's clock is set back two
        // minutes before the flush. It must be held (never sent from "the future", never dropped)
        // and sent once the clock passes its date, with the hold visible in the status meanwhile.
        let clock = TestClock(fixture.start.addingTimeInterval(3_600))
        let pairs = try uploaders(queueFile: nil, clock: clock)
        for (uploader, _) in pairs {
            try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)
        }
        clock.advance(by: -120)
        for (uploader, sentCount) in pairs {
            await XCTAssertEqualAsync(await uploader.flush(), .heldDatedInFuture(count: 1), uploader.destinationName)
            let status = await uploader.status
            XCTAssertEqual(status.heldInFuture, 1)
            XCTAssertEqual(status.discarded, 0, "not dropped")
            XCTAssertEqual(status.queueDepth, 1)
            XCTAssertTrue(status.isFailing, "followers are not getting it yet (S5)")
            await XCTAssertEqualAsync(await sentCount(), 0, uploader.destinationName)
        }
        clock.advance(by: 120 - LiveReadingGate.futureTolerance)
        for (uploader, sentCount) in pairs {
            await XCTAssertEqualAsync(await uploader.flushIfDue(), .uploaded(count: 1), uploader.destinationName)
            await XCTAssertEqualAsync(await sentCount(), 1, uploader.destinationName)
            let status = await uploader.status
            XCTAssertEqual(status.heldInFuture, 0)
            XCTAssertEqual(status.discarded, 0)
            XCTAssertFalse(status.isFailing)
        }
    }
}
