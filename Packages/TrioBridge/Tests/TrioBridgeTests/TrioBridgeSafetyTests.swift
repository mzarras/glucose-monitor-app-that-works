// Safety tests for the Trio bridge (HANDOFF §2, §8 step 4). Named test_S<n>_… for scripts/check.sh gate 3.

import Foundation
import GlucoseCore
import XCTest
@testable import TrioBridge

final class TrioBridgeSafetyTests: XCTestCase {
    private var store: InMemoryTrioStore!
    private var clock: TestClock!
    private var diagnostics: RecordingDiagnosticLog!

    override func setUp() {
        super.setUp()
        store = InMemoryTrioStore()
        clock = TestClock(Fixture.time(3_600))
        diagnostics = RecordingDiagnosticLog()
    }

    private func makeBridge(policy: OutOfRangePolicy = .doNotWrite) -> TrioBridge {
        let clock = self.clock!
        return TrioBridge(store: store, outOfRangePolicy: policy, diagnostics: diagnostics, clock: { clock.now() })
    }

    /// What Trio would read from the store right now.
    private func trioReads() throws -> [TrioReaderEmulation.Element] {
        guard let payload = store.payload else { return [] }
        let read = try TrioReaderEmulation.read(payload)
        XCTAssertEqual(read.skipped, 0, "every element the bridge writes must be accepted by Trio")
        return read.accepted
    }

    private func assertRefusedAndNothingWritten(
        _ reading: GlucoseReading,
        session: SensorSession? = Fixture.session,
        now: Date? = nil,
        because reason: TrioBridgeRefusal.Reason,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        if let now { clock.set(now) }
        let bridge = makeBridge()
        let result = await bridge.publish([reading], session: session)
        XCTAssertEqual(result.refusals.map(\.reason), [reason], file: file, line: line)
        XCTAssertEqual(result.refusals.first?.readingID, reading.id, file: file, line: line)
        XCTAssertFalse(result.didWrite, file: file, line: line)
        XCTAssertTrue(result.addedReadingIDs.isEmpty, file: file, line: line)
        XCTAssertNil(store.payload, "a refused reading is never written", file: file, line: line)
        XCTAssertTrue(store.operations.isEmpty, "the App Group is not touched: \(store.operations)", file: file, line: line)
        let status = await bridge.status
        XCTAssertEqual(status.lastRefusal?.reason, reason, file: file, line: line)
    }

    // MARK: - S6: only live sensor data reaches Trio

    func test_S6_bridgeRefusesImportedReplayAndMockReadings() async {
        for source: ReadingSource in [.imported(.nightscout), .imported(.clarityCSV), .replay, .mock] {
            store = InMemoryTrioStore()
            await assertRefusedAndNothingWritten(
                Fixture.reading(at: 3_600, source: source),
                because: .gate(.notLiveSensor(source))
            )
        }
    }

    func test_S6_mixedBatchWritesOnlySensorReadings() async throws {
        let bridge = makeBridge()
        let sensor = Fixture.reading(at: 3_300, value: .mgdl(130))
        let imported = Fixture.reading(at: 3_000, value: .mgdl(90), source: .imported(.nightscout))
        let replay = Fixture.reading(at: 3_600, value: .mgdl(91), source: .replay)
        let result = await bridge.publish([imported, sensor, replay], session: Fixture.session)
        XCTAssertEqual(result.addedReadingIDs, [sensor.id])
        XCTAssertEqual(Set(result.refusals.map(\.readingID)), [imported.id, replay.id])
        XCTAssertEqual(try trioReads().map(\.mgdl), [130])
    }

    // MARK: - S2: only authenticated, valid, plausible readings

    func test_S2_refusesReadingWithoutSession() async {
        await assertRefusedAndNothingWritten(Fixture.reading(at: 3_600), session: nil, because: .gate(.noSession))
    }

    func test_S2_refusesSerialMismatch() async {
        await assertRefusedAndNothingWritten(
            Fixture.reading(at: 3_600, serial: "OTHERSERIAL"),
            because: .gate(.serialMismatch(readingSerial: "OTHERSERIAL", sessionSerial: Fixture.serial))
        )
    }

    func test_S2_refusesWarmUpReading() async {
        await assertRefusedAndNothingWritten(Fixture.reading(at: 29 * 60), now: Fixture.time(29 * 60), because: .gate(.duringWarmUp))
    }

    func test_S2_refusesReadingBeforeSessionStart() async {
        let early = GlucoseReading(
            id: "\(Fixture.serial):early", date: Fixture.sessionStart.addingTimeInterval(-300), value: .mgdl(120),
            trendRate: 0, isBackfill: true, source: .sensor, sensorSerial: Fixture.serial
        )
        await assertRefusedAndNothingWritten(early, because: .gate(.beforeSessionStart))
    }

    func test_S2_refusesReadingAfterGracePeriod() async {
        let seconds: UInt32 = 907_260 // 10 days + 12 h grace + 60 s
        await assertRefusedAndNothingWritten(Fixture.reading(at: seconds), now: Fixture.time(seconds), because: .gate(.afterSessionEnd))
    }

    func test_S2_refusesFutureReadingBeyondToleranceAcceptsWithin() async throws {
        // Reading dated 61 s after "now": refused.
        await assertRefusedAndNothingWritten(
            Fixture.reading(at: 3_661), now: Fixture.time(3_600), because: .gate(.inFuture)
        )
        // Dated exactly `futureTolerance` (60 s) after "now": accepted and readable by Trio, which does not
        // check reading dates against its clock (docs/trio-bridge.md, "Readings dated slightly ahead").
        let bridge = makeBridge()
        let result = await bridge.publish([Fixture.reading(at: 3_660)], session: Fixture.session)
        XCTAssertTrue(result.didWrite)
        XCTAssertEqual(try trioReads().map(\.date), [Fixture.time(3_660)])
    }

    func test_S2_refusesImplausibleNumericValues() async {
        // The sensor reports what it cannot measure as LOW/HIGH, so these can only be faults. 38 in
        // particular would read as an error code to oref (determine-basal.js:418-421).
        for value in [0, 10, 38, 39, 401, 4_095] {
            store = InMemoryTrioStore()
            await assertRefusedAndNothingWritten(Fixture.reading(at: 3_600, value: .mgdl(value)), because: .gate(.implausibleValue(value)))
        }
    }

    func test_S2_refusesNonFiniteTrendRate() async {
        for rate in [Double.nan, .infinity, -.infinity] {
            store = InMemoryTrioStore()
            await assertRefusedAndNothingWritten(Fixture.reading(at: 3_600, rate: rate), because: .gate(.nonFiniteTrendRate))
        }
    }

    func test_S2_refusesEveryReadingAgainstMalformedSession() async {
        let malformed = SensorSession(
            serial: Fixture.serial, start: Fixture.sessionStart,
            warmUpEndsAt: Fixture.sessionStart.addingTimeInterval(30 * 60),
            expiresAt: Fixture.sessionStart, // expires before warm-up ends
            gracePeriodEndsAt: Fixture.sessionStart.addingTimeInterval(10 * 86_400)
        )
        await assertRefusedAndNothingWritten(Fixture.reading(at: 3_600), session: malformed, because: .gate(.malformedSession))
        let emptySerial = SensorSession(
            serial: "", start: Fixture.sessionStart, warmUpEndsAt: Fixture.sessionStart,
            expiresAt: Fixture.sessionStart.addingTimeInterval(86_400), gracePeriodEndsAt: Fixture.sessionStart.addingTimeInterval(86_400)
        )
        store = InMemoryTrioStore()
        await assertRefusedAndNothingWritten(Fixture.reading(at: 3_600, serial: ""), session: emptySerial, because: .gate(.malformedSession))
    }

    func test_S2_refusedOnlyCallLeavesTrioPayloadUntouched() async throws {
        let bridge = makeBridge()
        await bridge.publish([Fixture.reading(at: 3_000, value: .mgdl(110))], session: Fixture.session)
        let before = try XCTUnwrap(store.payload)
        clock.set(Fixture.time(3_300))
        let result = await bridge.publish([Fixture.reading(at: 3_300, source: .mock)], session: Fixture.session)
        XCTAssertFalse(result.didWrite)
        XCTAssertEqual(store.payload, before)
        XCTAssertEqual(store.readingWrites, 1)
    }

    func test_S2_everyPayloadReadingIsRecheckedBeforeEachWrite() async throws {
        // Readings of the previous sensor are already in the payload when a new sensor's first reading
        // arrives. They fail the gate for the new session and are left out of the next write.
        let bridge = makeBridge()
        clock.set(Fixture.time(4_200))
        await bridge.publish(Fixture.series(from: 3_600, count: 3), session: Fixture.session)
        XCTAssertEqual(try trioReads().count, 3)

        let newStart = Fixture.sessionStart.addingTimeInterval(11 * 86_400)
        let newSession = SensorSession(
            serial: "3MTEST0002", start: newStart, warmUpEndsAt: newStart.addingTimeInterval(1_800),
            expiresAt: newStart.addingTimeInterval(10 * 86_400), gracePeriodEndsAt: newStart.addingTimeInterval(10 * 86_400 + 43_200)
        )
        let first = Fixture.reading(at: 1_800, value: .mgdl(140), serial: "3MTEST0002", sessionStart: newStart)
        clock.set(first.date)
        let result = await bridge.publish([first], session: newSession)
        XCTAssertTrue(result.didWrite)
        XCTAssertEqual(try trioReads().map(\.mgdl), [140])
        XCTAssertTrue(diagnostics.events.contains { $0.message.contains("left 3 earlier reading(s) out") })
    }

    // MARK: - S2: payload removal only on positive evidence (review m1, delta B1, PROGRESS.md D28)

    private func secondSession(startingAfterDays days: Double) -> SensorSession {
        let start = Fixture.sessionStart.addingTimeInterval(days * 86_400)
        return SensorSession(
            serial: "3MTEST0002", start: start, warmUpEndsAt: start.addingTimeInterval(1_800),
            expiresAt: start.addingTimeInterval(10 * 86_400), gracePeriodEndsAt: start.addingTimeInterval(10 * 86_400 + 43_200)
        )
    }

    func test_S2_nilSessionBetweenReadingsLeavesPayloadAndWindowUntouched() async throws {
        let bridge = makeBridge()
        clock.set(Fixture.time(3_900))
        await bridge.publish(Fixture.series(from: 3_600, count: 2), session: Fixture.session)
        let written = try XCTUnwrap(store.payload)
        let operationsBefore = store.operations

        // Nil session (with and without a reading offered): nothing in the App Group changes.
        clock.set(Fixture.time(4_000))
        let empty = await bridge.publish([], session: nil)
        let refused = await bridge.publish([Fixture.reading(at: 4_200)], session: nil)
        XCTAssertFalse(empty.didWrite || empty.didRemovePayload)
        XCTAssertFalse(refused.didWrite || refused.didRemovePayload)
        XCTAssertEqual(refused.refusals.map(\.reason), [.gate(.noSession)])
        XCTAssertEqual(store.payload, written)
        XCTAssertEqual(store.operations, operationsBefore, "no write, no removal")

        // Session back: the window is intact, nothing needs rewriting, and the next reading joins it.
        let back = await bridge.publish([], session: Fixture.session)
        XCTAssertFalse(back.didWrite || back.didRemovePayload)
        clock.set(Fixture.time(4_200))
        await bridge.publish([Fixture.reading(at: 4_200)], session: Fixture.session)
        XCTAssertEqual(try trioReads().count, 3)
    }

    func test_S2_firstCallWithNilSessionLeavesLeftoverPayloadInPlace() async throws {
        // A payload left by an earlier process. This process has no evidence about it.
        let leftover = Data(#"[{"DT":"/Date(1)/","ST":"/Date(1)/","Trend":4,"Value":100,"direction":"Flat"}]"#.utf8)
        store.setData(leftover, forKey: "latestReadings")
        let bridge = makeBridge()
        let result = await bridge.publish([Fixture.reading(at: 3_600)], session: nil)
        XCTAssertFalse(result.didWrite || result.didRemovePayload)
        XCTAssertEqual(store.payload, leftover)
        XCTAssertEqual(store.operations, ["setData latestReadings"], "only the setup write")
    }

    func test_S2_firstCallWithLiveSessionAndNothingPassingLeavesLeftoverPayload() async throws {
        let leftover = Data("[]".utf8)
        store.setData(leftover, forKey: "latestReadings")
        let bridge = makeBridge()
        await bridge.publish([Fixture.reading(at: 3_600, source: .mock)], session: Fixture.session)
        XCTAssertEqual(store.payload, leftover)
        // The first write replaces it.
        await bridge.publish([Fixture.reading(at: 3_600)], session: Fixture.session)
        XCTAssertEqual(try trioReads().count, 1)
    }

    func test_S2_newSessionWithoutReadingsRemovesPreviousSessionPayload() async throws {
        let bridge = makeBridge()
        await bridge.publish([Fixture.reading(at: 3_600)], session: Fixture.session)
        let newSession = secondSession(startingAfterDays: 5) // first sensor replaced before it expired
        clock.set(newSession.start.addingTimeInterval(600)) // new sensor warming up, no reading yet
        let result = await bridge.publish([], session: newSession)
        XCTAssertTrue(result.didRemovePayload)
        XCTAssertNil(store.payload)
        XCTAssertTrue(diagnostics.events.contains { $0.message.contains("removed latestReadings: session 3MTEST0002 replaced") })
        // Its first valid reading is written alone.
        let first = Fixture.reading(at: 1_800, value: .mgdl(140), serial: "3MTEST0002", sessionStart: newSession.start)
        clock.set(first.date)
        await bridge.publish([first], session: newSession)
        XCTAssertEqual(try trioReads().map(\.mgdl), [140])
    }

    func test_S2_gracePeriodEndRemovesPayloadEvenWithNilSession() async throws {
        let bridge = makeBridge()
        let lastSeconds: UInt32 = 907_200 // exactly at the end of the grace period (10 d + 12 h)
        clock.set(Fixture.time(lastSeconds))
        await bridge.publish([Fixture.reading(at: lastSeconds)], session: Fixture.session)
        XCTAssertNotNil(store.payload)

        // Grace period over; the source now reports no session (D28). That nil is not the evidence — the
        // ended session of the payload is.
        clock.set(Fixture.time(lastSeconds + 60))
        let result = await bridge.publish([], session: nil)
        XCTAssertTrue(result.didRemovePayload)
        XCTAssertNil(store.payload)
        XCTAssertTrue(diagnostics.events.contains { $0.message.contains("removed latestReadings: session 3MTEST0001 ended") })

        // A caller still passing the ended session cannot bring it back.
        let late = await bridge.publish([Fixture.reading(at: lastSeconds - 300, backfill: true)], session: Fixture.session)
        XCTAssertEqual(late.refusals.map(\.reason), [.sessionEnded])
        XCTAssertFalse(late.didWrite)
        XCTAssertNil(store.payload)
        let status = await bridge.status
        XCTAssertEqual(status.lastGateRefusal?.reason, .sessionEnded)
    }

    func test_S2_sensorStoppedEarlyPayloadStaysUntilNextSensorGraceEndOrClear() async throws {
        // The first sensor is stopped (or fails) on day 2, long before its grace end (day 10.5). From then on
        // the source reports no session (D28). A nil session is not evidence, so the payload stays; it goes
        // only on the next sensor's first write/removal, the stopped session's grace end, or clear().
        let stoppedAt: UInt32 = 2 * 86_400
        func payloadWrittenThenSensorStopped() async -> TrioBridge {
            store = InMemoryTrioStore()
            clock.set(Fixture.time(stoppedAt))
            let bridge = makeBridge()
            await bridge.publish([Fixture.reading(at: stoppedAt)], session: Fixture.session)
            clock.set(Fixture.time(stoppedAt + 86_400)) // a day later, still no session
            let idle = await bridge.publish([], session: nil)
            XCTAssertFalse(idle.didWrite || idle.didRemovePayload)
            XCTAssertNotNil(store.payload, "stays while there is no session")
            return bridge
        }

        // (a) The next sensor's first valid reading replaces it.
        var bridge = await payloadWrittenThenSensorStopped()
        let next = secondSession(startingAfterDays: 3)
        let first = Fixture.reading(at: 1_800, value: .mgdl(150), serial: "3MTEST0002", sessionStart: next.start)
        clock.set(first.date)
        let replaced = await bridge.publish([first], session: next)
        XCTAssertTrue(replaced.didWrite)
        XCTAssertEqual(try trioReads().map(\.mgdl), [150])

        // (a') Before that reading, the next sensor's session alone (warming up) removes it.
        bridge = await payloadWrittenThenSensorStopped()
        clock.set(next.start.addingTimeInterval(600))
        let removedForNewSession = await bridge.publish([], session: next)
        XCTAssertTrue(removedForNewSession.didRemovePayload)
        XCTAssertNil(store.payload)

        // (b) With no new sensor, the stopped session's grace end removes it.
        bridge = await payloadWrittenThenSensorStopped()
        clock.set(Fixture.session.gracePeriodEndsAt)
        let atGraceEnd = await bridge.publish([], session: nil)
        XCTAssertFalse(atGraceEnd.didRemovePayload, "not before the grace period is over")
        clock.set(Fixture.session.gracePeriodEndsAt.addingTimeInterval(1))
        let afterGraceEnd = await bridge.publish([], session: nil)
        XCTAssertTrue(afterGraceEnd.didRemovePayload)
        XCTAssertNil(store.payload)

        // (c) clear() removes it at any time.
        bridge = await payloadWrittenThenSensorStopped()
        try await bridge.clear()
        XCTAssertNil(store.payload)
    }

    func test_S2_failedRemovalIsReportedAndRetriedEvenWithNilSession() async throws {
        let bridge = makeBridge()
        await bridge.publish([Fixture.reading(at: 3_600)], session: Fixture.session)
        let newSession = secondSession(startingAfterDays: 5)
        clock.set(newSession.start.addingTimeInterval(600))
        store.dropsRemovals = true
        let failed = await bridge.publish([], session: newSession)
        XCTAssertEqual(failed.error, .readBackMismatch)
        XCTAssertNotNil(store.payload)
        let failing = await bridge.status
        XCTAssertEqual(failing.consecutiveFailures, 1)
        // The evidence was established; the retry does not need the session again.
        store.dropsRemovals = false
        let retried = await bridge.publish([], session: nil)
        XCTAssertTrue(retried.didRemovePayload)
        XCTAssertNil(store.payload)
        let recovered = await bridge.status
        XCTAssertEqual(recovered.consecutiveFailures, 0)
    }

    func test_S2_failedWriteIsNotRetriedWithNilSession() async throws {
        let bridge = makeBridge()
        store.dropsDataWrites = true
        await bridge.publish([Fixture.reading(at: 3_600)], session: Fixture.session)
        store.dropsDataWrites = false
        let withoutSession = await bridge.publish([], session: nil)
        XCTAssertFalse(withoutSession.didWrite || withoutSession.didRemovePayload)
        XCTAssertNil(store.payload)
        let withSession = await bridge.publish([], session: Fixture.session)
        XCTAssertTrue(withSession.didWrite)
        XCTAssertEqual(try trioReads().count, 1)
    }

    func test_S2_capRefusalDoesNotMaskGateRefusal() async throws {
        // One call: a serial-mismatch reading (gate) and 61 valid readings, the oldest of which falls outside
        // the 60-reading window (benign). `lastRefusal` ends on the benign one; `lastGateRefusal` keeps the
        // safety-relevant one.
        let bridge = makeBridge()
        let valid = Fixture.series(from: 3_600, count: 61)
        clock.set(valid.last!.date)
        let foreign = Fixture.reading(at: 3_900, serial: "OTHERSERIAL")
        let result = await bridge.publish([foreign] + valid, session: Fixture.session)
        XCTAssertEqual(result.refusals.map(\.reason), [
            .gate(.serialMismatch(readingSerial: "OTHERSERIAL", sessionSerial: Fixture.serial)),
            .olderThanPayloadWindow,
        ])
        let status = await bridge.status
        XCTAssertEqual(status.lastRefusal?.reason, .olderThanPayloadWindow)
        XCTAssertEqual(status.lastGateRefusal?.readingID, foreign.id)
        XCTAssertEqual(status.lastGateRefusal?.reason, .gate(.serialMismatch(readingSerial: "OTHERSERIAL", sessionSerial: Fixture.serial)))
    }

    // MARK: - S3: derived timestamps, monotonic order, dedupe, backfill

    func test_S3_payloadIsNewestFirstWithStrictlyDecreasingTimestamps() async throws {
        let bridge = makeBridge()
        clock.set(Fixture.time(3_600 + 11 * 300))
        await bridge.publish(Fixture.series(from: 3_600, count: 12).shuffled(), session: Fixture.session)
        let dates = try trioReads().map(\.date)
        XCTAssertEqual(dates.count, 12)
        XCTAssertEqual(dates, dates.sorted(by: >))
        XCTAssertEqual(Set(dates).count, dates.count, "no two elements share a timestamp")
    }

    func test_S3_duplicateIDKeepsTheCopyAlreadyWritten() async throws {
        let bridge = makeBridge()
        let live = Fixture.reading(at: 3_600, value: .mgdl(120))
        await bridge.publish([live], session: Fixture.session)
        // Same sensor timestamp (same id) re-delivered through backfill with a slightly different derived
        // date and value: ignored, the written timestamp and value stay.
        let backfillCopy = GlucoseReading(
            id: live.id, date: live.date.addingTimeInterval(2), value: .mgdl(121), trendRate: 0.2,
            isBackfill: true, source: .sensor, sensorSerial: Fixture.serial
        )
        let result = await bridge.publish([backfillCopy, live], session: Fixture.session)
        XCTAssertEqual(result.duplicateReadingIDs, [live.id, live.id])
        XCTAssertFalse(result.didWrite, "nothing new, nothing rewritten")
        XCTAssertEqual(try trioReads(), [TrioReaderEmulation.Element(mgdl: 120, date: live.date, direction: "Flat")])
    }

    func test_S3_backfillKeepsOriginalTimestampAndSlotsIntoOrder() async throws {
        let bridge = makeBridge()
        clock.set(Fixture.time(5_400))
        await bridge.publish([Fixture.reading(at: 5_400, value: .mgdl(150))], session: Fixture.session)
        // Backfill for a 25-minute gap arrives after the newest reading.
        let backfill = [3_900, 4_200, 4_500, 4_800, 5_100].map {
            Fixture.reading(at: UInt32($0), value: .mgdl(100 + $0 / 300), backfill: true)
        }
        let result = await bridge.publish(backfill, session: Fixture.session)
        XCTAssertEqual(result.addedReadingIDs.count, 5)
        let read = try trioReads()
        XCTAssertEqual(read.map(\.date), [5_400, 5_100, 4_800, 4_500, 4_200, 3_900].map { Fixture.time(UInt32($0)) })
        XCTAssertEqual(read.map(\.mgdl), [150, 117, 116, 115, 114, 113])
    }

    func test_S3_timestampsAreWrittenToTheMillisecond() async throws {
        let bridge = makeBridge()
        let reading = Fixture.reading(at: 3_600)
        await bridge.publish([reading], session: Fixture.session)
        let date = try XCTUnwrap(trioReads().first?.date)
        XCTAssertEqual(GlucoseReading.epochMilliseconds(date), GlucoseReading.epochMilliseconds(reading.date))
        XCTAssertEqual(GlucoseReading.epochMilliseconds(date) % 1_000, 123)
    }

    func test_S3_keepsTheNewestSixtyAndReportsOlderOnes() async throws {
        let bridge = makeBridge()
        let readings = Fixture.series(from: 3_600, count: 70)
        clock.set(readings.last!.date)
        let result = await bridge.publish(readings, session: Fixture.session)
        let read = try trioReads()
        XCTAssertEqual(read.count, TrioAppGroupContract.maxReadings)
        XCTAssertEqual(read.first?.date, readings.last?.date)
        XCTAssertEqual(read.last?.date, readings[10].date)
        XCTAssertEqual(result.addedReadingIDs.count, 60)
        XCTAssertEqual(result.refusals.map(\.readingID), readings.prefix(10).reversed().map(\.id))
        XCTAssertTrue(result.refusals.allSatisfy { $0.reason == .olderThanPayloadWindow })
    }

    // MARK: - S4: LOW/HIGH stay out of range

    func test_S4_defaultPolicyWritesNeitherLowNorHigh() async throws {
        let bridge = makeBridge()
        XCTAssertEqual(bridge.outOfRangePolicy, .doNotWrite)
        for value in [GlucoseValue.belowRange, .aboveRange] {
            store = InMemoryTrioStore()
            await assertRefusedAndNothingWritten(Fixture.reading(at: 3_600, value: value), because: .outOfRangeWithheld(value))
        }
        // The default of the initializer is the same policy.
        let defaulted = TrioBridge(store: InMemoryTrioStore())
        XCTAssertEqual(defaulted.outOfRangePolicy, OutOfRangePolicy(low: .doNotWrite, high: .doNotWrite))
    }

    func test_S4_withheldLowIsVisibleInStatusAndDiagnostics() async throws {
        let bridge = makeBridge()
        await bridge.publish([Fixture.reading(at: 3_300, value: .mgdl(60))], session: Fixture.session)
        clock.set(Fixture.time(3_600))
        let result = await bridge.publish([Fixture.reading(at: 3_600, value: .belowRange)], session: Fixture.session)
        XCTAssertFalse(result.didWrite)
        let status = await bridge.status
        XCTAssertEqual(status.lastOutOfRangeWithheldAt, Fixture.time(3_600))
        XCTAssertEqual(status.lastRefusal?.reason, .outOfRangeWithheld(.belowRange))
        XCTAssertEqual(try trioReads().map(\.mgdl), [60], "Trio keeps only the last numeric reading")
        XCTAssertTrue(diagnostics.events.contains { $0.category == .bridge && $0.message.contains("outOfRangeWithheld") })
    }

    func test_S4_flagsAreNeverWrittenAs40Or400() async throws {
        let batch = [
            Fixture.reading(at: 3_000, value: .belowRange),
            Fixture.reading(at: 3_300, value: .mgdl(120)),
            Fixture.reading(at: 3_600, value: .aboveRange),
        ]
        for policy in [OutOfRangePolicy.doNotWrite, OutOfRangePolicy(low: .writeSentinel, high: .writeSentinel),
                       OutOfRangePolicy(low: .writeSentinel, high: .doNotWrite), OutOfRangePolicy(low: .doNotWrite, high: .writeSentinel)] {
            store = InMemoryTrioStore()
            let bridge = makeBridge(policy: policy)
            await bridge.publish(batch, session: Fixture.session)
            let values = try trioReads().map(\.mgdl)
            XCTAssertFalse(values.contains(40), "\(policy)")
            XCTAssertFalse(values.contains(400), "\(policy)")
            XCTAssertTrue(values.contains(120), "\(policy)")
        }
    }

    func test_S4_sentinelPolicyWrites39ForLowAnd401ForHigh() async throws {
        let bridge = makeBridge(policy: OutOfRangePolicy(low: .writeSentinel, high: .writeSentinel))
        let result = await bridge.publish([
            Fixture.reading(at: 3_300, value: .belowRange, rate: -0.5),
            Fixture.reading(at: 3_600, value: .aboveRange, rate: nil),
        ], session: Fixture.session)
        XCTAssertTrue(result.refusals.isEmpty)
        XCTAssertEqual(try trioReads(), [
            TrioReaderEmulation.Element(mgdl: 401, date: Fixture.time(3_600), direction: "NOT COMPUTABLE"),
            TrioReaderEmulation.Element(mgdl: 39, date: Fixture.time(3_300), direction: "Flat"),
        ])
        XCTAssertEqual(TrioAppGroupContract.lowSentinelMgdl, 39)
        XCTAssertEqual(TrioAppGroupContract.highSentinelMgdl, 401)
    }

    func test_S4_realFortyAndFourHundredPassUnchanged() async throws {
        let bridge = makeBridge()
        await bridge.publish([Fixture.reading(at: 3_300, value: .mgdl(40)), Fixture.reading(at: 3_600, value: .mgdl(400))], session: Fixture.session)
        XCTAssertEqual(try trioReads().map(\.mgdl), [400, 40])
    }

    // MARK: - S5: failures are loud

    func test_S5_failingWriteSurfacesInStatusAndRecovers() async throws {
        let bridge = makeBridge()
        let updates = await bridge.statusUpdates()
        var iterator = updates.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, TrioBridgeStatus())

        store.dropsDataWrites = true
        let first = await bridge.publish([Fixture.reading(at: 3_600)], session: Fixture.session)
        XCTAssertEqual(first.error, .readBackMismatch)
        XCTAssertFalse(first.didWrite)
        let failing = await iterator.next()
        XCTAssertEqual(failing?.consecutiveFailures, 1)
        XCTAssertEqual(failing?.isFailing, true)
        XCTAssertEqual(failing?.lastError, .readBackMismatch)
        XCTAssertEqual(failing?.lastErrorAt, Fixture.time(3_600))
        XCTAssertNil(failing?.lastSuccessfulWriteAt)

        clock.set(Fixture.time(3_900))
        await bridge.publish([Fixture.reading(at: 3_900)], session: Fixture.session)
        let stillFailing = await bridge.status
        XCTAssertEqual(stillFailing.consecutiveFailures, 2)

        // Storage works again: a retry without new readings writes everything still pending.
        store.dropsDataWrites = false
        clock.set(Fixture.time(3_960))
        let retry = await bridge.publish([], session: Fixture.session)
        XCTAssertTrue(retry.didWrite)
        XCTAssertEqual(try trioReads().map(\.date), [Fixture.time(3_900), Fixture.time(3_600)])
        let recovered = await bridge.status
        XCTAssertEqual(recovered.consecutiveFailures, 0)
        XCTAssertFalse(recovered.isFailing)
        XCTAssertEqual(recovered.lastSuccessfulWriteAt, Fixture.time(3_960))
        XCTAssertEqual(recovered.newestReadingWrittenAt, Fixture.time(3_900))
        XCTAssertEqual(recovered.readingsInLastWrite, 2)
        XCTAssertEqual(recovered.lastError, .readBackMismatch, "kept for diagnostics")
        XCTAssertTrue(diagnostics.events.contains { $0.message.contains("write FAILED (2 in a row)") })
    }

    func test_S5_missingAppGroupAccessIsAWriteFailure() async {
        let bridge = makeBridge()
        let error = TrioBridgeError.appGroupUnavailable(groupID: "group.org.nightscout.ABCDE12345.trio.trio-app-group", reason: .notEntitled)
        store.accessError = error
        let result = await bridge.publish([Fixture.reading(at: 3_600)], session: Fixture.session)
        XCTAssertEqual(result.error, error)
        XCTAssertEqual(store.readingWrites, 0, "nothing is written into a suite Trio cannot see")
        let status = await bridge.status
        XCTAssertEqual(status.consecutiveFailures, 1)
        XCTAssertEqual(status.lastError, error)
    }

    // MARK: - S5: Trio starving (review m3)

    /// Offers one live reading every 5 minutes from `startSeconds` for `count` readings and returns whether
    /// the bridge reports Trio as starving after each call.
    private func starvingAfterEach(
        _ bridge: TrioBridge, from startSeconds: UInt32, count: Int,
        session: SensorSession? = Fixture.session, make: (UInt32) -> GlucoseReading
    ) async -> [Bool] {
        var starving: [Bool] = []
        for step in 0..<count {
            let seconds = startSeconds + UInt32(step) * 300
            clock.set(Fixture.time(seconds))
            await bridge.publish([make(seconds)], session: session)
            starving.append(await bridge.status.isStarving())
        }
        return starving
    }

    func test_S5_starvingWhenGateRefusesLiveReadingsFor15Minutes() async {
        let bridge = makeBridge()
        await bridge.publish([Fixture.reading(at: 3_600)], session: Fixture.session)
        let starving = await starvingAfterEach(bridge, from: 3_900, count: 3) {
            Fixture.reading(at: $0, value: .mgdl(4_095)) // implausible → gate refusal
        }
        XCTAssertEqual(starving, [false, false, true], "5, 10, 15 min behind")
        let status = await bridge.status
        XCTAssertEqual(status.trioLag, 900)
        XCTAssertEqual(status.newestReadingWrittenAt, Fixture.time(3_600))
    }

    func test_S5_starvingWhenSessionIsNil() async {
        let bridge = makeBridge()
        await bridge.publish([Fixture.reading(at: 3_600)], session: Fixture.session)
        let starving = await starvingAfterEach(bridge, from: 3_900, count: 3, session: nil) { Fixture.reading(at: $0) }
        XCTAssertEqual(starving, [false, false, true])
    }

    func test_S5_starvingWhenLowIsWithheldButNotUnderTheD21Policy() async {
        let withholding = makeBridge()
        await withholding.publish([Fixture.reading(at: 3_600)], session: Fixture.session)
        let withheld = await starvingAfterEach(withholding, from: 3_900, count: 3) { Fixture.reading(at: $0, value: .belowRange) }
        XCTAssertEqual(withheld, [false, false, true])

        store = InMemoryTrioStore()
        let d21 = makeBridge(policy: OutOfRangePolicy(low: .writeSentinel, high: .writeSentinel))
        await d21.publish([Fixture.reading(at: 3_600)], session: Fixture.session)
        let sent = await starvingAfterEach(d21, from: 3_900, count: 3) { Fixture.reading(at: $0, value: .belowRange) }
        XCTAssertEqual(sent, [false, false, false])
    }

    func test_S5_starvingWhenWritesFailAndRecoversOnWrite() async {
        let bridge = makeBridge()
        await bridge.publish([Fixture.reading(at: 3_600)], session: Fixture.session)
        store.dropsDataWrites = true
        let starving = await starvingAfterEach(bridge, from: 3_900, count: 3) { Fixture.reading(at: $0) }
        XCTAssertEqual(starving, [false, false, true])
        store.dropsDataWrites = false
        await bridge.publish([], session: Fixture.session)
        let recovered = await bridge.status
        XCTAssertFalse(recovered.isStarving())
        XCTAssertEqual(recovered.trioLag, 0)
    }

    func test_S5_starvingEvenIfNothingWasEverWritten() async {
        let bridge = makeBridge()
        let starving = await starvingAfterEach(bridge, from: 3_600, count: 4, session: nil) { Fixture.reading(at: $0) }
        XCTAssertEqual(starving, [false, false, false, true], "counted from the first live reading offered")
        let status = await bridge.status
        XCTAssertNil(status.newestReadingWrittenAt)
        XCTAssertEqual(status.firstLiveReadingOfferedAt, Fixture.time(3_600))
    }

    func test_S5_starvationIgnoresGapsBackfillAndNonLiveSourcesButCountsFutureDatedReadingsUpToNow() async {
        let bridge = makeBridge()
        let initial = await bridge.status
        XCTAssertNil(initial.trioLag, "nothing offered yet")
        XCTAssertFalse(initial.isStarving())
        await bridge.publish([Fixture.reading(at: 3_600)], session: Fixture.session)
        // No readings for an hour (sensor gap): the missed-readings alert's job, not this signal.
        clock.set(Fixture.time(7_200))
        await bridge.publish([], session: Fixture.session)
        // Imported history and an old backfilled reading do not move "newest offered" forward.
        await bridge.publish([Fixture.reading(at: 7_200, source: .imported(.nightscout)), Fixture.reading(at: 1_800, backfill: true)], session: nil)
        var status = await bridge.status
        XCTAssertEqual(status.trioLag, 0)
        XCTAssertFalse(status.isStarving())
        // A reading dated an hour ahead (clock fault) is refused, but it is a live reading Trio did not get:
        // it counts, capped at the bridge's clock, so Trio is reported starving (fail loud).
        await bridge.publish([Fixture.reading(at: 10_800)], session: Fixture.session)
        status = await bridge.status
        XCTAssertEqual(status.newestLiveReadingOfferedAt, Fixture.time(7_200))
        XCTAssertEqual(status.lastGateRefusal?.reason, .gate(.inFuture))
        XCTAssertEqual(status.trioLag, 3_600)
        XCTAssertTrue(status.isStarving())
        XCTAssertEqual(TrioBridgeStatus.starvationThreshold, 15 * 60)
    }

    func test_S5_statusStreamsAreIndependentAndStopWhenCancelled() async {
        let bridge = makeBridge()
        let a = await bridge.statusUpdates()
        let b = await bridge.statusUpdates()
        store.dropsDataWrites = true
        await bridge.publish([Fixture.reading(at: 3_600)], session: Fixture.session)
        var iteratorA = a.makeAsyncIterator()
        var iteratorB = b.makeAsyncIterator()
        // Only the newest status is buffered, so each stream yields the failing status.
        let fromA = await iteratorA.next()
        let fromB = await iteratorB.next()
        XCTAssertEqual(fromA?.consecutiveFailures, 1)
        XCTAssertEqual(fromB?.consecutiveFailures, 1)

        // Cancelling a consumer removes its continuation; the bridge keeps working for the other.
        let observersBefore = await bridge.observerCount
        XCTAssertEqual(observersBefore, 2)
        let consumer = Task { for await _ in a {} }
        consumer.cancel()
        await consumer.value
        for _ in 0..<1_000 where await bridge.observerCount > 1 { await Task.yield() }
        let observersAfter = await bridge.observerCount
        XCTAssertEqual(observersAfter, 1)
        store.dropsDataWrites = false
        await bridge.publish([], session: Fixture.session)
        let recovered = await iteratorB.next()
        XCTAssertEqual(recovered?.consecutiveFailures, 0)
    }
}
