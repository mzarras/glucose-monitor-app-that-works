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

    private func reading(
        at offset: TimeInterval, source: ReadingSource = .sensor, serial: String = "3M1234",
        value: GlucoseValue = .mgdl(110), trendRate: Double? = 0.2
    ) -> GlucoseReading {
        GlucoseReading(
            id: GlucoseReading.sensorID(serial: serial, sensorTimestamp: UInt32(max(0, offset))),
            date: start.addingTimeInterval(offset), value: value, trendRate: trendRate,
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

    func test_S2_refusesNumericValuesOutsideTheSensorRange() {
        for (value, expected) in [(39, LiveReadingGate.Rejection?.some(.implausibleValue(39))), (40, nil), (400, nil),
                                  (401, .implausibleValue(401)), (0, .implausibleValue(0)), (-5, .implausibleValue(-5)),
                                  (4095, .implausibleValue(4095))] {
            let r = reading(at: 3_600, value: .mgdl(value))
            XCTAssertEqual(rejection(r, session: session, now: r.date), expected, "\(value)")
        }
    }

    func test_S4_acceptsLowAndHighFlags() {
        for value: GlucoseValue in [.belowRange, .aboveRange] {
            let r = reading(at: 3_600, value: value)
            XCTAssertNil(rejection(r, session: session, now: r.date), "\(value)")
        }
    }

    func test_S2_refusesNonFiniteTrendRate() {
        for rate in [Double.nan, .infinity, -.infinity] {
            let r = reading(at: 3_600, trendRate: rate)
            XCTAssertEqual(rejection(r, session: session, now: r.date), .nonFiniteTrendRate, "\(rate)")
        }
        let noRate = reading(at: 3_600, trendRate: nil)
        XCTAssertNil(rejection(noRate, session: session, now: noRate.date), "a missing rate is allowed")
    }

    func test_S2_refusesMalformedSession() {
        let s = session
        let malformed = [
            SensorSession(serial: "", start: s.start, warmUpEndsAt: s.warmUpEndsAt, expiresAt: s.expiresAt, gracePeriodEndsAt: s.gracePeriodEndsAt),
            SensorSession(serial: "3M1234", start: s.warmUpEndsAt, warmUpEndsAt: s.start, expiresAt: s.expiresAt, gracePeriodEndsAt: s.gracePeriodEndsAt),
            SensorSession(serial: "3M1234", start: s.start, warmUpEndsAt: s.warmUpEndsAt, expiresAt: s.gracePeriodEndsAt, gracePeriodEndsAt: s.expiresAt),
        ]
        let r = reading(at: 3_600)
        for bad in malformed {
            XCTAssertFalse(bad.isWellFormed)
            XCTAssertEqual(rejection(r, session: bad, now: r.date), .malformedSession)
        }
        XCTAssertTrue(s.isWellFormed)
    }

    func test_S2_sensorReadingWithEmptySerialNeverMatches() {
        let r = reading(at: 3_600, serial: "")
        XCTAssertEqual(rejection(r, session: session, now: r.date), .serialMismatch(readingSerial: "", sessionSerial: "3M1234"))
    }

    func test_S2_exactBoundariesAreInclusive() {
        let atStart = GlucoseReading(id: "x", date: start, value: .mgdl(100), trendRate: nil, isBackfill: true, source: .sensor, sensorSerial: "3M1234")
        let noWarmUp = SensorSession(serial: "3M1234", start: start, warmUpEndsAt: start, expiresAt: session.expiresAt, gracePeriodEndsAt: session.gracePeriodEndsAt)
        XCTAssertNil(rejection(atStart, session: noWarmUp, now: start), "session start is inclusive")
        let atGraceEnd = reading(at: 10 * 86_400 + 12 * 3_600)
        XCTAssertNil(rejection(atGraceEnd, session: session, now: atGraceEnd.date), "grace-period end is inclusive")
    }

    func test_S6_sourceIsCheckedBeforeEverythingElse() {
        let r = reading(at: 3_600, source: .imported(.nightscout), value: .mgdl(0))
        XCTAssertEqual(rejection(r, session: nil, now: r.date), .notLiveSensor(.imported(.nightscout)))
    }

    #if DEBUG
    func test_S6_replayVariantAcceptsReplayButNotImportedOrMock() throws {
        let replay = reading(at: 3_600, source: .replay)
        XCTAssertNoThrow(try LiveReadingGate.validateAllowingReplay(replay, session: session, now: replay.date))
        for source: ReadingSource in [.imported(.nightscout), .imported(.clarityCSV), .mock] {
            let r = reading(at: 3_600, source: source)
            XCTAssertThrowsError(try LiveReadingGate.validateAllowingReplay(r, session: session, now: r.date))
        }
    }

    func test_S2_replayVariantStillAppliesSessionAndValueChecks() {
        func replayRejection(_ r: GlucoseReading, _ s: SensorSession?) -> LiveReadingGate.Rejection? {
            do { try LiveReadingGate.validateAllowingReplay(r, session: s, now: r.date); return nil } catch { return error }
        }
        XCTAssertEqual(replayRejection(reading(at: 3_600, source: .replay), nil), .noSession)
        XCTAssertEqual(replayRejection(reading(at: 29 * 60, source: .replay), session), .duringWarmUp)
        XCTAssertEqual(replayRejection(reading(at: 3_600, source: .replay, value: .mgdl(0)), session), .implausibleValue(0))
    }
    #endif
}
