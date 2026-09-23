import XCTest
@testable import GlucoseCore

final class LiveReadingGateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_758_000_000)
    private var session: SensorSession {
        SensorSession(
            serial: "3M1234",
            start: start,
            warmUpEndsAt: start.addingTimeInterval(30 * 60),
            expiresAt: start.addingTimeInterval(10 * 86_400),
            gracePeriodEndsAt: start.addingTimeInterval(10 * 86_400 + 12 * 3_600)
        )
    }

    private func reading(at offset: TimeInterval, source: ReadingSource = .sensor, serial: String = "3M1234") -> GlucoseReading {
        GlucoseReading(
            id: GlucoseReading.sensorID(serial: serial, sensorTimestamp: UInt32(max(0, offset))),
            date: start.addingTimeInterval(offset), value: .mgdl(110), trendRate: 0.2,
            isBackfill: false, source: source, sensorSerial: serial
        )
    }

    private func rejection(_ r: GlucoseReading, session: SensorSession?, now: Date) -> LiveReadingGate.Rejection? {
        do { try LiveReadingGate.validate(r, session: session, now: now); return nil } catch { return error }
    }

    func test_acceptsValidSensorReading() {
        let r = reading(at: 3_600)
        XCTAssertNil(rejection(r, session: session, now: r.date))
    }

    func test_S6_refusesEveryNonSensorSource() {
        for source: ReadingSource in [.imported(.nightscout), .imported(.clarityCSV), .replay, .mock] {
            let r = reading(at: 3_600, source: source)
            XCTAssertEqual(rejection(r, session: session, now: r.date), .notLiveSensor(source))
        }
    }

    func test_S2_refusesWithoutSession() {
        let r = reading(at: 3_600)
        XCTAssertEqual(rejection(r, session: nil, now: r.date), .noSession)
    }

    func test_S2_refusesSerialMismatch() {
        let r = reading(at: 3_600, serial: "OTHER")
        XCTAssertEqual(rejection(r, session: session, now: r.date), .serialMismatch(readingSerial: "OTHER", sessionSerial: "3M1234"))
    }

    func test_S2_refusesWarmUpReading() {
        let r = reading(at: 29 * 60)
        XCTAssertEqual(rejection(r, session: session, now: r.date), .duringWarmUp)
        let first = reading(at: 30 * 60)
        XCTAssertNil(rejection(first, session: session, now: first.date), "warm-up end is inclusive")
    }

    func test_S2_refusesReadingBeforeSessionStart() {
        let r = reading(at: -300)
        XCTAssertEqual(rejection(r, session: session, now: start), .beforeSessionStart)
    }

    func test_S2_acceptsGracePeriodRefusesAfterIt() {
        let inGrace = reading(at: 10 * 86_400 + 3_600)
        XCTAssertNil(rejection(inGrace, session: session, now: inGrace.date))
        let after = reading(at: 10 * 86_400 + 12 * 3_600 + 1)
        XCTAssertEqual(rejection(after, session: session, now: after.date), .afterSessionEnd)
    }

    func test_S2_refusesFutureReadingBeyondTolerance() {
        let r = reading(at: 3_600)
        XCTAssertNil(rejection(r, session: session, now: r.date.addingTimeInterval(-LiveReadingGate.futureTolerance)))
        XCTAssertEqual(rejection(r, session: session, now: r.date.addingTimeInterval(-LiveReadingGate.futureTolerance - 1)), .inFuture)
    }

    #if DEBUG
    func test_S6_replayVariantAcceptsReplayButNotImportedOrMock() throws {
        let replay = reading(at: 3_600, source: .replay)
        XCTAssertNoThrow(try LiveReadingGate.validateAllowingReplay(replay, session: session, now: replay.date))
        for source: ReadingSource in [.imported(.nightscout), .mock] {
            let r = reading(at: 3_600, source: source)
            XCTAssertThrowsError(try LiveReadingGate.validateAllowingReplay(r, session: session, now: r.date))
        }
    }
    #endif
}
