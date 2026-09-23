import XCTest
import GlucoseCore
@testable import NightscoutKit

/// Dexcom Share upload (HANDOFF §8A step 2) against `MockShareServer`, which follows the protocol
/// as xDrip4iOS 7.1.0 uses it. Base URL `https://share.invalid/...` never resolves; the in-process
/// transport answers instead.
final class DexcomShareUploadTests: XCTestCase {
    static let serial = "SM12345678"
    static let server = DexcomShareServer(baseURL: URL(string: "https://share.invalid/ShareWebServices/Services")!)
    let fixture = SessionFixture()
    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeUploader(
        share: MockShareServer,
        clock: TestClock,
        password: String = MockShareServer.password,
        serial: String = DexcomShareUploadTests.serial,
        log: any DiagnosticLog = NullDiagnosticLog(),
        credentials: InMemoryCredentialStore? = nil,
        queueDirectory: URL? = nil
    ) throws -> ReadingUploader {
        try ReadingUploader.dexcomShare(
            server: Self.server,
            receiverSerialNumber: serial,
            credentials: credentials ?? InMemoryCredentialStore([
                .dexcomShareAccountName: MockShareServer.accountName,
                .dexcomSharePassword: password,
            ]),
            queueDirectory: queueDirectory ?? directory,
            transport: InProcessTransport(backend: share),
            clock: clock,
            log: log
        )
    }

    private func clock(at offset: TimeInterval) -> TestClock {
        TestClock(fixture.start.addingTimeInterval(offset))
    }

    func test_regionBaseURLsMatchXDrip4iOS() {
        // ConstantsDexcomShare.swift:11 and :13 @ 7.1.0.
        XCTAssertEqual(DexcomShareServer.us.baseURL.absoluteString, "https://share2.dexcom.com/ShareWebServices/Services")
        XCTAssertEqual(DexcomShareServer.outsideUS.baseURL.absoluteString, "https://shareous1.dexcom.com/ShareWebServices/Services")
    }

    func test_firstUploadLogsInStartsMonitoringAndPostsEGV() async throws {
        let share = MockShareServer()
        let uploader = try makeUploader(share: share, clock: clock(at: 3_600))
        try await uploader.submit(fixture.reading(at: 3_600, value: .mgdl(123), trendRate: 2.5), session: fixture.session)
        await XCTAssertEqualAsync(await uploader.flush(), .uploaded(count: 1))

        let paths = await share.requests.map(\.path)
        XCTAssertEqual(paths, [
            "/ShareWebServices/Services/General/AuthenticatePublisherAccount",
            "/ShareWebServices/Services/General/LoginPublisherAccountById",
            "/ShareWebServices/Services/Publisher/PostReceiverEgvRecords",    // MonitoringSessionNotActive
            "/ShareWebServices/Services/Publisher/StartRemoteMonitoringSession",
            "/ShareWebServices/Services/Publisher/PostReceiverEgvRecords",
        ])
        let requests = await share.requests
        XCTAssertEqual(requests[0].header("user-agent"), "Dexcom%20Share/3.0.2.11 CFNetwork/1390 Darwin/22.0.0")
        XCTAssertEqual(requests[2].header("user-agent"), "Dexcom Share/3.0.2.11 CFNetwork/711.2.23 Darwin/14.0.0")
        XCTAssertEqual(requests[2].header("accept"), "application/json")
        XCTAssertEqual(requests[2].query("sessionId"), "session-1")
        XCTAssertEqual(requests[3].query("serialNumber"), Self.serial)
        XCTAssertFalse(requests.contains { $0.target.contains(MockShareServer.password) }, "password only in login bodies")

        let stored = await share.stored
        XCTAssertEqual(stored, [MockShareServer.PostedEGV(Trend: 2, ST: "/Date(1789866000000)/", DT: "/Date(1789866000000)/", Value: 123, direction: "SingleUp")])
        let body = try await XCTUnwrapAsync(await share.uploadBodies.last)
        XCTAssertEqual(body.SN, Self.serial)
        XCTAssertEqual(body.TA, -5)
        await XCTAssertEqualAsync(await uploader.status.lastError, nil)
    }

    func test_trendCodesFollowXDrip4iOSNumbering() {
        let expected: [(TrendArrow, Int)] = [
            (.doubleUp, 1), (.singleUp, 2), (.fortyFiveUp, 3), (.flat, 4),
            (.fortyFiveDown, 5), (.singleDown, 6), (.doubleDown, 7), (.notComputable, 0),
        ]
        for (arrow, code) in expected { XCTAssertEqual(DexcomShareEGV.trendCode(arrow), code, "\(arrow)") }
        XCTAssertEqual(DexcomShareEGV.shareDate(Date(timeIntervalSince1970: 1_758_330_000.999)), "/Date(1758330000000)/", "whole seconds")
    }

    func test_sessionReusedThenRenewedWhenShareForgetsIt() async throws {
        let share = MockShareServer()
        let clock = clock(at: 3_600)
        let uploader = try makeUploader(share: share, clock: clock)
        try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)
        await uploader.flush()
        clock.advance(by: 300)
        try await uploader.submit(fixture.reading(at: 3_900), session: fixture.session)
        await uploader.flush()
        await XCTAssertEqualAsync(await share.logins, 1, "session reused")

        await share.expireSessions()
        clock.advance(by: 300)
        try await uploader.submit(fixture.reading(at: 4_200), session: fixture.session)
        await XCTAssertEqualAsync(await uploader.flush(), .uploaded(count: 1))
        await XCTAssertEqualAsync(await share.logins, 2, "SessionNotValid → one new login → retry")
        await XCTAssertEqualAsync(await share.stored.count, 3)
    }

    func test_monitoringSessionRestartedWhenInactive() async throws {
        let share = MockShareServer()
        let clock = clock(at: 3_600)
        let uploader = try makeUploader(share: share, clock: clock)
        try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)
        await uploader.flush()
        await share.stopMonitoring()
        clock.advance(by: 300)
        try await uploader.submit(fixture.reading(at: 3_900), session: fixture.session)
        await XCTAssertEqualAsync(await uploader.flush(), .uploaded(count: 1))
        await XCTAssertEqualAsync(await share.monitoringStarts, 2)
    }

    func test_S3_dexcomShareDuplicateHandlingStoresEveryReadingOnce() async throws {
        // Reading A reached Share but its response was lost; A and B are then sent as one batch.
        // The mock rejects the whole batch with DuplicateEgvPosted; the uploader re-posts one by
        // one so B gets in and A is not duplicated.
        let share = MockShareServer()
        let a = fixture.reading(at: 3_600, value: .mgdl(110))
        let b = fixture.reading(at: 3_900, value: .mgdl(114))
        await share.seed(MockShareServer.PostedEGV(Trend: 4, ST: DexcomShareEGV.shareDate(a.date), DT: DexcomShareEGV.shareDate(a.date), Value: 110, direction: "Flat"))
        let uploader = try makeUploader(share: share, clock: clock(at: 3_900))
        try await uploader.submit(a, session: fixture.session)
        try await uploader.submit(b, session: fixture.session)
        await XCTAssertEqualAsync(await uploader.flush(), .uploaded(count: 2))
        let stored = await share.stored
        XCTAssertEqual(stored.map(\.Value), [110, 114])
        XCTAssertEqual(Set(stored.map(\.ST)).count, 2)
    }

    func test_S3_dexcomShareBackfillKeepsOriginalTimestampAndNewestFirst() async throws {
        let share = MockShareServer()
        let uploader = try makeUploader(share: share, clock: clock(at: 5 * 3_600))
        let backfill = fixture.reading(at: 3 * 3_600, value: .mgdl(150), isBackfill: true)
        let live = fixture.reading(at: 5 * 3_600, value: .mgdl(140))
        try await uploader.submit(live, session: fixture.session)
        try await uploader.submit(backfill, session: fixture.session)
        await uploader.flush()
        let body = try await XCTUnwrapAsync(await share.uploadBodies.last)
        XCTAssertEqual(body.Egvs.map(\.ST), [DexcomShareEGV.shareDate(live.date), DexcomShareEGV.shareDate(backfill.date)])
        XCTAssertEqual(body.Egvs.last?.ST, "/Date(\(Int64(fixture.start.addingTimeInterval(3 * 3_600).timeIntervalSince1970) * 1000))/")
    }

    func test_readingsOlderThanEightHoursAreDiscardedAndCounted() async throws {
        let share = MockShareServer()
        await share.setOffline(true)
        let clock = clock(at: 3_600)
        let log = RecordingDiagnosticLog()
        let uploader = try makeUploader(share: share, clock: clock, log: log)
        try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)
        await uploader.flush()
        clock.advance(by: 9 * 3_600)
        try await uploader.submit(fixture.reading(at: 3_600 + 9 * 3_600), session: fixture.session)
        await share.setOffline(false)
        await XCTAssertEqualAsync(await uploader.flush(), .uploaded(count: 1))
        await XCTAssertEqualAsync(await uploader.status.discarded, 1)
        XCTAssertTrue(log.messages.contains { $0.contains("older than this destination accepts") })
    }

    func test_S4_dexcomShareEncodesFlagsAs39And401NotClamped() async throws {
        // PROGRESS D30: LOW → 39, HIGH → 401 (unverified with Dexcom Follow until §11 step 4a).
        let share = MockShareServer()
        let uploader = try makeUploader(share: share, clock: clock(at: 3_600))
        try await uploader.submit(fixture.reading(at: 3_000, value: .belowRange, trendRate: nil), session: fixture.session)
        try await uploader.submit(fixture.reading(at: 3_300, value: .aboveRange, trendRate: nil), session: fixture.session)
        try await uploader.submit(fixture.reading(at: 3_600, value: .mgdl(40)), session: fixture.session)
        await XCTAssertEqualAsync(await uploader.flush(), .uploaded(count: 3))
        let stored = await share.stored.sorted { $0.ST < $1.ST }
        XCTAssertEqual(stored.map(\.Value), [39, 401, 40], "flags as 39/401; the number 40 stays 40")
        XCTAssertEqual(stored.first?.Trend, 0, "no rate reported → trend 0 (xDrip4iOS hideSlope)")
        XCTAssertEqual(DexcomShareEGV.value(for: .belowRange), 39)
        XCTAssertEqual(DexcomShareEGV.value(for: .aboveRange), 401)
        XCTAssertNil(DexcomShareEGV.value(for: .mgdl(39)), "a number is never sent as a flag value")
        XCTAssertNil(DexcomShareEGV.value(for: .mgdl(401)))
        await XCTAssertEqualAsync(await uploader.status.notRepresentable, 0)
    }

    func test_S5_dexcomShareFailureSurfacesInStatus() async throws {
        // Wrong password: Share answers with the all-zero session id (xDrip4iOS :654-657).
        let share = MockShareServer()
        let clock = clock(at: 3_600)
        let log = RecordingDiagnosticLog()
        let uploader = try makeUploader(share: share, clock: clock, password: "wrong-password", log: log)
        try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)
        guard case .failed(let error, _) = await uploader.flushIfDue() else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .unauthorized)
        let status = await uploader.status
        XCTAssertTrue(status.isFailing)
        XCTAssertEqual(status.destination, "Dexcom Share")
        XCTAssertEqual(status.queueDepth, 1)
        XCTAssertEqual(status.nextAttemptAt, clock.now().addingTimeInterval(30 * 60), "slow retries protect the account from lockout")
        XCTAssertFalse(log.messages.contains { $0.contains("wrong-password") })
        clock.advance(by: 5 * 60)
        guard case .deferred = await uploader.flushIfDue() else { return XCTFail("expected deferral") }
        await XCTAssertEqualAsync(await share.logins, 1)
    }

    func test_receiverNotAssignedIsAConfigurationError() async throws {
        let share = MockShareServer()
        await share.setAssignedSerial(nil)
        let uploader = try makeUploader(share: share, clock: clock(at: 3_600))
        try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)
        guard case .failed(let error, _) = await uploader.flush() else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .configuration)
        XCTAssertTrue(error.message.contains("not assigned"))
    }

    func test_serialMismatchIsAConfigurationError() async throws {
        let share = MockShareServer()
        let uploader = try makeUploader(share: share, clock: clock(at: 3_600), serial: "sm00000000")
        try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)
        guard case .failed(let error, _) = await uploader.flush() else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .configuration)
        await XCTAssertEqualAsync(await share.uploadBodies.last?.SN, "SM00000000", "upper-cased like xDrip4iOS")
    }

    func test_unknownAccountAndMissingCredentials() async throws {
        let share = MockShareServer()
        let unknown = try ReadingUploader.dexcomShare(
            server: Self.server, receiverSerialNumber: Self.serial,
            credentials: InMemoryCredentialStore([.dexcomShareAccountName: "nobody", .dexcomSharePassword: "x"]),
            queueDirectory: directory.appendingPathComponent("a"), transport: InProcessTransport(backend: share),
            clock: clock(at: 3_600)
        )
        try await unknown.submit(fixture.reading(at: 3_600), session: fixture.session)
        guard case .failed(let error, _) = await unknown.flush() else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .unauthorized)

        let empty = try ReadingUploader.dexcomShare(
            server: Self.server, receiverSerialNumber: Self.serial, credentials: InMemoryCredentialStore(),
            queueDirectory: directory.appendingPathComponent("b"), transport: InProcessTransport(backend: share),
            clock: clock(at: 3_600)
        )
        try await empty.submit(fixture.reading(at: 3_600), session: fixture.session)
        guard case .failed(let missing, _) = await empty.flush() else { return XCTFail("expected failure") }
        XCTAssertEqual(missing.kind, .missingCredentials)
    }

    func test_offlineIsATransportFailure() async throws {
        let share = MockShareServer()
        await share.setOffline(true)
        let uploader = try makeUploader(share: share, clock: clock(at: 3_600))
        try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)
        guard case .failed(let error, _) = await uploader.flush() else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .transport)
        await XCTAssertEqualAsync(await uploader.status.nextAttemptAt, clock(at: 3_600).now().addingTimeInterval(30))
    }

    func test_loginErrorMapping() {
        XCTAssertEqual(DexcomShareClient.loginError(code: "SSO_AuthenticateAccountNotFound", statusCode: 500).kind, .unauthorized)
        XCTAssertEqual(DexcomShareClient.loginError(code: "SSO_AuthenticatePasswordInvalid", statusCode: 500).kind, .unauthorized)
        XCTAssertEqual(DexcomShareClient.loginError(code: "SSO_AuthenticateMaxAttemptsExceeed", statusCode: 500).kind, .unauthorized)
        XCTAssertEqual(DexcomShareClient.loginError(code: "Other", statusCode: 500).kind, .server)
        XCTAssertEqual(DexcomShareClient.loginError(code: nil, statusCode: 503).kind, .server)
        XCTAssertEqual(DexcomShareClient.errorCode(in: Data(#"{"Code":"SessionNotValid","Message":"x","SubCode":null}"#.utf8)), "SessionNotValid")
        XCTAssertNil(DexcomShareClient.errorCode(in: Data("<html>".utf8)))
    }

    /// Runs one upload with scripted publisher replies and returns the resulting error.
    private func uploadError(scripted replies: [MockReply], serial: String = DexcomShareUploadTests.serial) async throws -> UploadError? {
        let share = MockShareServer()
        await share.scriptPublisher(replies)
        let uploader = try makeUploader(share: share, clock: clock(at: 3_600), serial: serial, queueDirectory: directory.appendingPathComponent(UUID().uuidString))
        try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)
        guard case .failed(let error, _) = await uploader.flush() else { return nil }
        await XCTAssertEqualAsync(await uploader.status.queueDepth, 1, "a failed upload keeps the reading queued")
        return error
    }

    func test_shareErrorPathsFailLoudlyAndKeepTheReading() async throws {
        let unknown = try await uploadError(scripted: [.json(500, ["Code": "SomethingNew"])])
        XCTAssertEqual(unknown?.kind, .server)
        XCTAssertTrue(unknown?.message.contains("SomethingNew") == true)

        let noCode = try await uploadError(scripted: [.status(503, body: "<html>")])
        XCTAssertEqual(noCode?.kind, .server)
        XCTAssertTrue(noCode?.message.contains("HTTP 503") == true)

        let sessionTwice = try await uploadError(scripted: [.json(500, ["Code": "SessionNotValid"]), .json(500, ["Code": "SessionIdNotFound"])])
        XCTAssertEqual(sessionTwice?.kind, .server, "one re-login per upload, not a loop")

        let monitoringTwice = try await uploadError(scripted: [.json(500, ["Code": "MonitoringSessionNotActive"]), .status(200), .json(500, ["Code": "MonitoringSessionNotActive"])])
        XCTAssertEqual(monitoringTwice?.kind, .server, "one session start per upload, not a loop")

        let startRefused = try await uploadError(scripted: [.json(500, ["Code": "MonitoringSessionNotActive"]), .json(500, ["Code": "MonitoredReceiverNotAssigned"])])
        XCTAssertEqual(startRefused?.kind, .configuration)

        let startMismatch = try await uploadError(scripted: [.json(500, ["Code": "MonitoringSessionNotActive"]), .json(500, ["Code": "MonitoredReceiverSerialNumberDoesNotMatch"])])
        XCTAssertEqual(startMismatch?.kind, .configuration)

        let startSessionLost = try await uploadError(scripted: [.json(500, ["Code": "MonitoringSessionNotActive"]), .json(500, ["Code": "SessionNotValid"])])
        XCTAssertEqual(startSessionLost?.kind, .server)

        let startOther = try await uploadError(scripted: [.json(500, ["Code": "MonitoringSessionNotActive"]), .status(500)])
        XCTAssertEqual(startOther?.kind, .server)

        let noSerial = try await uploadError(scripted: [], serial: "  ")
        XCTAssertEqual(noSerial?.kind, .configuration)
    }

    func test_nonEmptySuccessBodyAndSingleDuplicateCountAsAccepted() async throws {
        // xDrip4iOS :482-485 (2xx with a body) and :452-455 (DuplicateEgvPosted).
        for reply: MockReply in [.status(200, body: "{\"Accepted\":true}"), .json(500, ["Code": "DuplicateEgvPosted"])] {
            let share = MockShareServer()
            await share.scriptPublisher([reply])
            let uploader = try makeUploader(share: share, clock: clock(at: 3_600), queueDirectory: directory.appendingPathComponent(UUID().uuidString))
            try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)
            await XCTAssertEqualAsync(await uploader.flush(), .uploaded(count: 1))
        }
    }

    func test_shareCredentialErrorsAreCaseInsensitiveAndHTTP401Or403IsUnauthorized() async throws {
        XCTAssertEqual(DexcomShareClient.loginError(code: "sso_authenticatepasswordinvalid", statusCode: 500).kind, .unauthorized)
        XCTAssertEqual(DexcomShareClient.loginError(code: "SSO_AUTHENTICATEACCOUNTNOTFOUND", statusCode: 500).kind, .unauthorized)
        XCTAssertEqual(DexcomShareClient.loginError(code: nil, statusCode: 401).kind, .unauthorized)
        XCTAssertEqual(DexcomShareClient.loginError(code: "Whatever", statusCode: 403).kind, .unauthorized)
        XCTAssertEqual(ShareErrorCode(code: "sessionnotvalid"), .sessionNotValid)
        XCTAssertNil(ShareErrorCode(code: "SessionNotValidX"))

        let forbidden = try await uploadError(scripted: [.status(403)])
        XCTAssertEqual(forbidden?.kind, .unauthorized, "30-minute backoff, not 30 s")
        let lowerCase = try await uploadError(scripted: [.json(500, ["Code": "monitoredreceivernotassigned"])])
        XCTAssertEqual(lowerCase?.kind, .configuration)
    }

    func test_credentialsChangedForgetsSessionAndBackoff() async throws {
        let share = MockShareServer()
        let clock = clock(at: 3_600)
        let credentials = InMemoryCredentialStore([
            .dexcomShareAccountName: MockShareServer.accountName,
            .dexcomSharePassword: "old-wrong-password",
        ])
        let uploader = try makeUploader(share: share, clock: clock, credentials: credentials)
        try await uploader.submit(fixture.reading(at: 3_600), session: fixture.session)
        guard case .failed(let error, _) = await uploader.flushIfDue() else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .unauthorized)
        await XCTAssertEqualAsync(await uploader.status.nextAttemptAt, clock.now().addingTimeInterval(30 * 60))

        // The user fixes the password: no 30-minute wait, and a fresh login.
        try credentials.write(MockShareServer.password, for: .dexcomSharePassword)
        await uploader.credentialsChanged()
        await XCTAssertNilAsync(await uploader.status.nextAttemptAt)
        await XCTAssertEqualAsync(await uploader.flushIfDue(), .uploaded(count: 1))
        await XCTAssertEqualAsync(await share.logins, 2)

        // A later credential change drops the cached session: the next upload logs in again.
        await uploader.credentialsChanged()
        clock.advance(by: 300)
        try await uploader.submit(fixture.reading(at: 3_900), session: fixture.session)
        await XCTAssertEqualAsync(await uploader.flush(), .uploaded(count: 1))
        await XCTAssertEqualAsync(await share.logins, 3)
    }
}
