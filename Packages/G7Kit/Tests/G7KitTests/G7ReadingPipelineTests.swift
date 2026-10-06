// Original to Sensor (no ported code). Captured vectors are cited where they are used.

import GlucoseCore
import XCTest
@testable import G7Kit

/// The 10-day timing a sensor reports in `0x52` (captured `5200c0d70d0054060002…`).
let tenDayParameters = G7SensorLifetime.parameters(reportedSessionLength: 907_200, reportedWarmUp: 1_620)!

final class G7ReadingPipelineTests: XCTestCase {
    private let serial = "DXCM4F-1A2B3C4D"
    private let receivedAt = Date(timeIntervalSince1970: 1_790_000_000)
    private var logs: [String] = []

    private func makePipeline(parameters: G7SensorLifetime.Parameters? = tenDayParameters) -> G7ReadingPipeline {
        G7ReadingPipeline(serial: serial, reportedParameters: parameters) { [weak self] in self?.logs.append($0) }
    }

    private func glucose(_ data: Data) -> G7GlucoseMessage { G7GlucoseMessage(data)! }

    /// Phone time at which a message with `sensorClock` arrives, for a session that started at `t0`.
    private func arrival(_ sensorClock: UInt32, t0: Date) -> Date { t0.addingTimeInterval(TimeInterval(sensorClock)) }

    // MARK: - S3

    /// The same physical reading received live and as backfill (LoopKit's captured pair,
    /// G7SensorKitTests/G7GlucoseMessageTests.swift:120-126 and :143-151) gets the same id AND the
    /// same date, even when the backfill copy arrives on a later connection after a relaunch.
    func test_S3_liveAndBackfillCopiesShareIdAndDate() throws {
        // Connection 1: live `0x4E`, sensor clock 154105, age 298, 143 mg/dL.
        let first = makePipeline()
        first.beginConnection()
        let live = try XCTUnwrap(first.handleGlucose(glucose(Data(hex: "4e00f9590200030200012a018f000610d9000f")), receivedAt: receivedAt).readings.first)
        XCTAssertEqual(live.id, "\(serial):153807")
        XCTAssertEqual(live.date, receivedAt.addingTimeInterval(-298), "the reading happened `age` seconds before receipt")
        XCTAssertFalse(live.isBackfill)

        // Connection 2, five minutes later (fresh pipeline, as after an app relaunch): the sensor
        // clock advanced by the same 300 s, then the backfill record of the first reading arrives.
        let second = makePipeline()
        second.beginConnection()
        let later = Fixture.glucose(sensorClock: 154_405, age: 298, glucose: 150, state: 0x06)
        _ = second.handleGlucose(glucose(later), receivedAt: receivedAt.addingTimeInterval(300))
        second.handleBackfillFrame(Data(hex: "cf5802008f00060f10"), now: receivedAt.addingTimeInterval(300))
        let backfilled = try XCTUnwrap(second.flushBackfill().readings.first)
        XCTAssertEqual(backfilled.id, live.id)
        XCTAssertEqual(backfilled.date, live.date)
        XCTAssertEqual(backfilled.value, live.value)
        XCTAssertTrue(backfilled.isBackfill)
    }

    /// Session start = receipt time − sensor clock; reading date = start + (clock − age).
    func test_S3_timestampsAreDerivedFromTheSensorClock() throws {
        let pipeline = makePipeline()
        pipeline.beginConnection()
        let message = Fixture.glucose(sensorClock: 200_000, age: 7, glucose: 120, state: 0x06, trend: 0xF6)
        let reading = try XCTUnwrap(pipeline.handleGlucose(glucose(message), receivedAt: receivedAt).readings.first)
        let session = try XCTUnwrap(pipeline.session)
        XCTAssertEqual(session.start, receivedAt.addingTimeInterval(-200_000))
        XCTAssertEqual(reading.date, session.start.addingTimeInterval(199_993))
        XCTAssertEqual(reading.id, GlucoseReading.sensorID(serial: serial, sensorTimestamp: 199_993))
        XCTAssertEqual(reading.trendRate, -1.0, "trend exactly as reported: 0xF6 = −10 tenths")
        XCTAssertEqual(session.warmUpEndsAt, session.start.addingTimeInterval(27 * 60))
        XCTAssertEqual(session.expiresAt, session.start.addingTimeInterval(10 * 86_400))
        XCTAssertEqual(session.gracePeriodEndsAt, session.start.addingTimeInterval(10.5 * 86_400))
        XCTAssertTrue(session.isWellFormed)
    }

    /// Duplicates collapse: the same `0x4E` twice, a backfill record for an already published
    /// reading, and a record repeated inside one batch each produce one reading.
    func test_S3_duplicateSensorTimestampsCollapseToOneID() throws {
        let pipeline = makePipeline()
        pipeline.beginConnection()
        let message = glucose(Fixture.glucose(sensorClock: 100_300, age: 5, glucose: 110, state: 0x06))
        XCTAssertEqual(pipeline.handleGlucose(message, receivedAt: receivedAt).readings.count, 1)
        XCTAssertEqual(pipeline.handleGlucose(message, receivedAt: receivedAt).readings.count, 0)
        pipeline.handleBackfillFrame(Fixture.backfill(timestamp: 100_295, glucose: 110), now: receivedAt)
        pipeline.handleBackfillFrame(Fixture.backfill(timestamp: 99_995, glucose: 108), now: receivedAt)
        pipeline.handleBackfillFrame(Fixture.backfill(timestamp: 99_995, glucose: 108), now: receivedAt)
        let batch = pipeline.flushBackfill().readings
        XCTAssertEqual(batch.map(\.id), ["\(serial):99995"])
        XCTAssertEqual(Set(batch.map(\.id)).count, batch.count)
    }

    /// Backfill keeps each record's own timestamp, is flagged, and comes out in ascending order.
    func test_S3_backfillKeepsOriginalTimestampsAndFlagInOrder() throws {
        let pipeline = makePipeline()
        pipeline.beginConnection()
        _ = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 50_000, age: 4, glucose: 100, state: 0x06)), receivedAt: receivedAt)
        let start = try XCTUnwrap(pipeline.sessionStart)
        for timestamp: UInt32 in [49_096, 48_496, 48_796] {
            pipeline.handleBackfillFrame(Fixture.backfill(timestamp: timestamp, glucose: 90), now: receivedAt)
        }
        let batch = pipeline.flushBackfill().readings
        XCTAssertEqual(batch.map(\.id), ["\(serial):48496", "\(serial):48796", "\(serial):49096"])
        XCTAssertEqual(batch.map(\.date), [48_496, 48_796, 49_096].map { start.addingTimeInterval($0) })
        XCTAssertTrue(batch.allSatisfy(\.isBackfill))
    }

    /// A live reading must be newer than everything already published (monotonic).
    func test_S3_liveReadingsAreMonotonic() {
        let pipeline = makePipeline()
        pipeline.beginConnection()
        XCTAssertEqual(pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 60_000, age: 5, glucose: 100, state: 0x06)), receivedAt: receivedAt).readings.count, 1)
        // Next connection, consistent clock, but the reading is older (age 400) than the one published.
        pipeline.beginConnection()
        let older = Fixture.glucose(sensorClock: 60_300, age: 400, glucose: 99, state: 0x06)
        XCTAssertTrue(pipeline.handleGlucose(glucose(older), receivedAt: receivedAt.addingTimeInterval(300)).readings.isEmpty)
        XCTAssertTrue(logs.contains { $0.contains("not newer than") })
    }

    /// Records that arrive before this connection's `0x4E` wait for its clock; without one they are
    /// discarded at disconnect, never dated with an old or assumed clock.
    func test_S3_backfillWaitsForTheConnectionsSensorClock() {
        let pipeline = makePipeline()
        pipeline.beginConnection()
        pipeline.handleBackfillFrame(Fixture.backfill(timestamp: 69_700, glucose: 95), now: receivedAt)
        XCTAssertTrue(pipeline.flushBackfill().readings.isEmpty)
        _ = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 70_000, age: 3, glucose: 97, state: 0x06)), receivedAt: receivedAt)
        XCTAssertEqual(pipeline.endConnection().readings.map(\.id), ["\(serial):69700"])

        pipeline.beginConnection()
        pipeline.handleBackfillFrame(Fixture.backfill(timestamp: 70_000, glucose: 95), now: receivedAt)
        XCTAssertTrue(pipeline.endConnection().readings.isEmpty)
        XCTAssertTrue(logs.contains { $0.contains("discarded 1 record") })
    }

    /// M2: the session start is fixed; sub-30 s anchor differences (transmission latency) change
    /// nothing — not the dates, not the session, not the state.
    func test_S3_sessionStartIsStableAcrossLatencyJitter() throws {
        let t0 = receivedAt
        let pipeline = makePipeline()
        pipeline.beginConnection()
        let first = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 100_000, age: 5, glucose: 110, state: 0x06)), receivedAt: arrival(100_000, t0: t0))
        let session = try XCTUnwrap(pipeline.session)
        for (index, jitter) in [7.0, -12, 29, -29].enumerated() {
            pipeline.beginConnection()
            let clock = UInt32(100_300 + 300 * index)
            let output = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: clock, age: 5, glucose: 111, state: 0x06)),
                                                receivedAt: arrival(clock, t0: t0).addingTimeInterval(jitter))
            let reading = try XCTUnwrap(output.readings.first, "jitter \(jitter) s")
            XCTAssertEqual(reading.date, session.start.addingTimeInterval(TimeInterval(clock - 5)))
            XCTAssertEqual(output.state, first.state, "no new .active(sessionStart:) for a sub-30 s shift")
            XCTAssertEqual(pipeline.session, session)
        }
    }

    /// Probe P4: the phone clock set back 1 h between connections. Nothing is published backwards
    /// in time; the disagreement is surfaced; the session moves only after two agreeing anchors, and
    /// readings resume only once their dates are after the last published one.
    func test_S3_phoneClockSetBackWithholdsAndSurfaces() throws {
        let t0 = receivedAt
        let pipeline = makePipeline()
        pipeline.beginConnection()
        let a = try XCTUnwrap(pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_000, age: 5, glucose: 100, state: 0x06)), receivedAt: arrival(200_000, t0: t0)).readings.first)
        let originalStart = try XCTUnwrap(pipeline.sessionStart)

        // Phone clock now reads one hour less.
        let back = t0.addingTimeInterval(-3_600)
        pipeline.beginConnection()
        let firstBack = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_300, age: 5, glucose: 101, state: 0x06)), receivedAt: arrival(200_300, t0: back))
        XCTAssertTrue(firstBack.readings.isEmpty)
        XCTAssertEqual(firstBack.state, .failed(G7FailureReason.sensorClockMismatch))
        XCTAssertEqual(pipeline.sessionStart, originalStart, "one disagreeing anchor never moves the session")

        pipeline.beginConnection()
        let secondBack = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_600, age: 5, glucose: 102, state: 0x06)), receivedAt: arrival(200_600, t0: back))
        XCTAssertEqual(pipeline.sessionStart, originalStart.addingTimeInterval(-3_600), "two agreeing anchors re-anchor")
        XCTAssertTrue(secondBack.readings.isEmpty, "its date would be before the last published reading")
        XCTAssertEqual(secondBack.state, .failed(G7FailureReason.sensorClockMismatch))

        // An hour of sensor time later, dates pass the last published one and readings resume.
        pipeline.beginConnection()
        let resumed = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 204_300, age: 5, glucose: 103, state: 0x06)), receivedAt: arrival(204_300, t0: back))
        let b = try XCTUnwrap(resumed.readings.first)
        XCTAssertGreaterThan(b.date, a.date)
        if case .active = resumed.state {} else { XCTFail("expected active again, got \(String(describing: resumed.state))") }
    }

    /// Probe P5: one garbled sensor clock (0x01030D40 ≈ 196 days) neither ends nor moves the session,
    /// and the next normal packet is accepted as before.
    func test_S2_singleGarbledSensorClockDoesNotEndOrMoveTheSession() throws {
        let t0 = receivedAt
        let pipeline = makePipeline()
        pipeline.beginConnection()
        _ = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_000, age: 5, glucose: 100, state: 0x06)), receivedAt: arrival(200_000, t0: t0))
        let session = try XCTUnwrap(pipeline.session)
        pipeline.beginConnection()
        let garbled = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 0x0103_0D40, age: 5, glucose: 101, state: 0x06)), receivedAt: arrival(200_300, t0: t0))
        XCTAssertTrue(garbled.readings.isEmpty)
        XCTAssertEqual(garbled.state, .failed(G7FailureReason.sensorClockMismatch))
        XCTAssertNotEqual(garbled.state, .expired)
        XCTAssertEqual(pipeline.session, session)
        XCTAssertFalse(pipeline.sessionEnded)
        pipeline.beginConnection()
        let next = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_600, age: 5, glucose: 102, state: 0x06)), receivedAt: arrival(200_600, t0: t0))
        XCTAssertEqual(next.readings.map(\.value), [.mgdl(102)])
        XCTAssertEqual(pipeline.session, session)
    }

    /// Probe P4 (backfill): after the phone clock was set back and the session re-anchored, a backfill
    /// record is published only if its date keeps the published readings in sensor-time order, like a
    /// live reading; the withheld ones are surfaced.
    func test_S3_backfillDuringClockMismatchKeepsSensorTimeOrder() throws {
        let t0 = receivedAt
        let back = t0.addingTimeInterval(-3_600)
        let pipeline = makePipeline()
        pipeline.beginConnection()
        var published = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_000, age: 5, glucose: 100, state: 0x06)), receivedAt: arrival(200_000, t0: t0)).readings
        var surfacedByBackfill = 0
        for step in 1...16 {
            // Each connection also backfills the previous connection's reading (clock − 305).
            let clock = UInt32(200_000 + 300 * step)
            pipeline.beginConnection()
            published += pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: clock, age: 5, glucose: 100, state: 0x06)), receivedAt: arrival(clock, t0: back)).readings
            pipeline.handleBackfillFrame(Fixture.backfill(timestamp: clock - 305, glucose: 100), now: arrival(clock, t0: back))
            let backfill = pipeline.endConnection()
            published += backfill.readings
            if backfill.state == .failed(G7FailureReason.sensorClockMismatch) { surfacedByBackfill += 1 }
        }
        let timestamps = published.map { UInt32($0.id.split(separator: ":").last!)! }
        let byTimestamp = zip(timestamps, published).sorted { $0.0 < $1.0 }.map(\.1)
        XCTAssertEqual(byTimestamp.map(\.date), published.map(\.date).sorted(), "dates follow sensor time")
        XCTAssertEqual(Set(published.map(\.date)).count, published.count, "strictly")
        XCTAssertEqual(Set(timestamps).count, published.count)
        XCTAssertGreaterThan(surfacedByBackfill, 0)
        XCTAssertTrue(logs.contains { $0.contains("out of sensor-time order") })

        // Gap filling: an older record that still fits before the published one is kept; a newer
        // record dated before the last published one is withheld and surfaced.
        let fresh = makePipeline()
        fresh.beginConnection()
        _ = fresh.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_000, age: 5, glucose: 100, state: 0x06)), receivedAt: arrival(200_000, t0: t0))
        for _ in 0..<2 {
            fresh.beginConnection()
            _ = fresh.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_600, age: 5, glucose: 100, state: 0x06)), receivedAt: arrival(200_600, t0: back))
        }
        fresh.handleBackfillFrame(Fixture.backfill(timestamp: 200_295, glucose: 104), now: arrival(200_600, t0: back))
        fresh.handleBackfillFrame(Fixture.backfill(timestamp: 199_000, glucose: 103), now: arrival(200_600, t0: back))
        let flushed = fresh.flushBackfill()
        XCTAssertEqual(flushed.readings.map(\.id), ["\(serial):199000"])
        XCTAssertEqual(flushed.state, .failed(G7FailureReason.sensorClockMismatch))
    }

    /// Probe P4 (relaunch): the newest published reading is persisted, so a relaunched pipeline whose
    /// clock is re-anchored backwards still publishes nothing dated before it.
    func test_S3_dateOrderHoldsAcrossRelaunch() throws {
        let t0 = receivedAt
        let first = makePipeline()
        first.beginConnection()
        let a = try XCTUnwrap(first.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_000, age: 5, glucose: 100, state: 0x06)), receivedAt: arrival(200_000, t0: t0)).readings.first)
        let mark = try XCTUnwrap(first.newestReading)
        XCTAssertEqual(mark, G7ReadingMark(sensorTimestamp: 199_995, date: a.date))

        let back = t0.addingTimeInterval(-3_600)
        let relaunched = G7ReadingPipeline(serial: serial, reportedParameters: tenDayParameters, sessionStart: first.sessionStart, newestReading: mark) { _ in }
        for clock: UInt32 in [200_300, 200_600, 200_900] {
            relaunched.beginConnection()
            let output = relaunched.handleGlucose(glucose(Fixture.glucose(sensorClock: clock, age: 5, glucose: 100, state: 0x06)), receivedAt: arrival(clock, t0: back))
            XCTAssertTrue(output.readings.isEmpty, "clock \(clock)")
            XCTAssertEqual(output.state, .failed(G7FailureReason.sensorClockMismatch))
            relaunched.handleBackfillFrame(Fixture.backfill(timestamp: clock - 305, glucose: 100), now: arrival(clock, t0: back))
            XCTAssertTrue(relaunched.endConnection().readings.isEmpty, "the backfill copy would be dated before the persisted newest reading")
        }
        relaunched.beginConnection()
        let resumed = relaunched.handleGlucose(glucose(Fixture.glucose(sensorClock: 203_700, age: 5, glucose: 100, state: 0x06)), receivedAt: arrival(203_700, t0: back))
        XCTAssertGreaterThan(try XCTUnwrap(resumed.readings.first).date, a.date)
    }

    // MARK: - Session end (N1)

    /// D41: `.expired` is a confirmed end (the alert engine suppresses missed readings on it), so an
    /// unconfirmed end report never produces it: the first expired report, any expired state in a
    /// non-zero-status reply (also on two connections), and a time-based expiry whose session start
    /// came only from the packet's own clock are `.error(code:description:)`. The second report from
    /// a later wake latches `.expired`.
    func test_S5_unconfirmedExpiryIsNotExpired() throws {
        let t0 = receivedAt
        for raw: UInt8 in [0x0F, 0x18, 0x1A, 0x24] {
            let pipeline = makePipeline()
            pipeline.beginConnection()
            _ = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_000, age: 5, glucose: 100, state: 0x06)), receivedAt: arrival(200_000, t0: t0))
            for clock: UInt32 in [200_300, 200_600] {
                pipeline.beginConnection()
                let reply = pipeline.handleGlucose(glucose(Fixture.glucose(status: 0x80, sensorClock: clock, age: 5, glucose: nil, state: raw)), receivedAt: arrival(clock, t0: t0))
                XCTAssertEqual(reply.state, .error(code: Int(raw), description: G7AlgorithmState(rawValue: raw).name), "status reply 0x\(String(raw, radix: 16))")
            }
            pipeline.beginConnection()
            let first = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_900, age: 5, glucose: nil, state: raw)), receivedAt: arrival(200_900, t0: t0))
            XCTAssertEqual(first.state, .error(code: Int(raw), description: G7AlgorithmState(rawValue: raw).name), "first report 0x\(String(raw, radix: 16))")
            XCTAssertFalse(pipeline.sessionEnded)
            pipeline.beginConnection()
            let second = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 201_200, age: 5, glucose: nil, state: raw)), receivedAt: arrival(201_200, t0: t0))
            XCTAssertEqual(second.state, .expired, "latched 0x\(String(raw, radix: 16))")
        }

        // A non-zero-status OK reply whose own (cached or garbled) clock is past the grace end, before
        // any anchor: not a confirmed end.
        let unanchored = makePipeline()
        unanchored.beginConnection()
        let garbled = unanchored.handleGlucose(glucose(Fixture.glucose(status: 0x80, sensorClock: 0x0103_0D40, age: 5, glucose: 100, state: 0x06)), receivedAt: t0)
        XCTAssertNotEqual(garbled.state, .expired)
        // The same garbled clock as the first status-0 packet of a pairing: not a confirmed end either.
        let firstAnchor = makePipeline()
        firstAnchor.beginConnection()
        let first = firstAnchor.handleGlucose(glucose(Fixture.glucose(sensorClock: 0x0103_0D40, age: 5, glucose: 100, state: 0x06)), receivedAt: t0)
        XCTAssertEqual(first.state, .error(code: 0x06, description: "OK, past the session end (not confirmed)"))
    }

    /// Probe P8: a non-zero-status reply carrying stopped/expired/failed never ends the session, even
    /// on two separate connections; the next OK reading is published and the session is active.
    func test_S5_statusReplyWithEndStateNeverEndsTheSession() throws {
        let t0 = receivedAt
        for state: UInt8 in [0x01, 0x18, 0x19] {
            let pipeline = makePipeline()
            pipeline.beginConnection()
            _ = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_000, age: 5, glucose: 100, state: 0x06)), receivedAt: arrival(200_000, t0: t0))
            for clock: UInt32 in [200_300, 200_600] {
                pipeline.beginConnection()
                let reply = pipeline.handleGlucose(glucose(Fixture.glucose(status: 0x80, sensorClock: clock, age: 5, glucose: 100, state: state)), receivedAt: arrival(clock, t0: t0))
                XCTAssertTrue(reply.readings.isEmpty)
                XCTAssertNotNil(reply.state, "the reported state is still shown for that connection")
            }
            XCTAssertFalse(pipeline.sessionEnded, "state 0x\(String(state, radix: 16))")
            pipeline.beginConnection()
            let later = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_900, age: 5, glucose: 101, state: 0x06)), receivedAt: arrival(200_900, t0: t0))
            XCTAssertEqual(later.readings.map(\.value), [.mgdl(101)])
            if case .active = later.state {} else { XCTFail("expected active, got \(String(describing: later.state))") }
            XCTAssertNotNil(pipeline.session)
        }
    }

    /// Probe P8b: one status-0 end report is shown, but does not end the session; the next OK
    /// reading is published and the session is active again.
    func test_S5_oneEndReportDoesNotEndTheSession() throws {
        let t0 = receivedAt
        let pipeline = makePipeline()
        pipeline.beginConnection()
        _ = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_000, age: 5, glucose: 100, state: 0x06)), receivedAt: arrival(200_000, t0: t0))
        pipeline.beginConnection()
        let stopped = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_300, age: 5, glucose: nil, state: 0x01)), receivedAt: arrival(200_300, t0: t0))
        XCTAssertEqual(stopped.state, .error(code: 1, description: "Session stopped"))
        XCTAssertFalse(pipeline.sessionEnded)
        pipeline.beginConnection()
        let later = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_600, age: 5, glucose: 125, state: 0x06)), receivedAt: arrival(200_600, t0: t0))
        XCTAssertEqual(later.readings.map(\.value), [.mgdl(125)])
        if case .active = later.state {} else { XCTFail("expected active, got \(String(describing: later.state))") }
    }

    /// N1: an end reported with status 0 on two separate connections ends the session. From then on
    /// every `0x4E`, OK or not, shows the end with its reason; nothing more is published.
    func test_S5_endReportedOnTwoConnectionsEndsTheSessionVisibly() throws {
        let t0 = receivedAt
        let pipeline = makePipeline()
        pipeline.beginConnection()
        _ = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_000, age: 5, glucose: 100, state: 0x06)), receivedAt: arrival(200_000, t0: t0))
        pipeline.beginConnection()
        XCTAssertEqual(pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_300, age: 5, glucose: nil, state: 0x19)), receivedAt: arrival(200_300, t0: t0)).state,
                       .error(code: 0x19, description: "Sensor failed"))
        XCTAssertFalse(pipeline.sessionEnded)
        pipeline.beginConnection()
        let second = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_600, age: 5, glucose: nil, state: 0x19)), receivedAt: arrival(200_600, t0: t0))
        XCTAssertEqual(second.state, .failed(G7FailureReason.sensorFailed))
        XCTAssertEqual(pipeline.sessionEnd, .sensorFailed)
        XCTAssertNil(pipeline.session)

        pipeline.beginConnection()
        let okAfterEnd = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_900, age: 5, glucose: 130, state: 0x06)), receivedAt: arrival(200_900, t0: t0))
        XCTAssertTrue(okAfterEnd.readings.isEmpty)
        XCTAssertEqual(okAfterEnd.state, .failed(G7FailureReason.sensorFailed), "never .active after a latched end")
        pipeline.handleBackfillFrame(Fixture.backfill(timestamp: 200_595, glucose: 120), now: arrival(200_900, t0: t0))
        XCTAssertTrue(pipeline.endConnection().readings.isEmpty)

        // A latched end restored from the pairing record behaves the same.
        let restored = G7ReadingPipeline(serial: serial, reportedParameters: tenDayParameters, sessionStart: pipeline.sessionStart, sessionEnd: .expired) { _ in }
        restored.beginConnection()
        let restoredOutput = restored.handleGlucose(glucose(Fixture.glucose(sensorClock: 201_200, age: 5, glucose: 130, state: 0x06)), receivedAt: arrival(201_200, t0: t0))
        XCTAssertTrue(restoredOutput.readings.isEmpty)
        XCTAssertEqual(restoredOutput.state, .expired, "a latched (confirmed) expiry")
    }

    /// N1: two end reports less than 60 s of sensor time apart (one connection), or separated by a
    /// status-0 report of a running session, do not end it; two reports from later wakes do.
    func test_S5_endNeedsASecondReportAtLeast60sOfSensorTimeLater() {
        let t0 = receivedAt
        let pipeline = makePipeline()
        func send(_ clock: UInt32, state: UInt8, newConnection: Bool = true) -> G7ReadingPipeline.Output {
            if newConnection { pipeline.beginConnection() }
            return pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: clock, age: 5, glucose: state == 0x06 ? 110 : nil, state: state)), receivedAt: arrival(clock, t0: t0))
        }
        _ = send(200_000, state: 0x06)
        _ = send(200_300, state: 0x18)
        _ = send(200_310, state: 0x18, newConnection: false)
        XCTAssertFalse(pipeline.sessionEnded, "one connection, two packets")
        _ = send(200_600, state: 0x12) // temporary issue: the session is still running
        _ = send(200_900, state: 0x18)
        XCTAssertFalse(pipeline.sessionEnded, "the first report was cleared by the running-session report")
        _ = send(201_200, state: 0x01)
        XCTAssertEqual(pipeline.sessionEnd, .stopped, "two consecutive wakes (the latest end is kept)")

        // The boundary: 59 s later does not confirm, 60 s later does; an earlier clock never does.
        let boundary = makePipeline()
        func report(_ clock: UInt32) {
            boundary.beginConnection()
            _ = boundary.handleGlucose(glucose(Fixture.glucose(sensorClock: clock, age: 5, glucose: nil, state: 0x19)), receivedAt: arrival(clock, t0: t0))
        }
        report(300_000)
        XCTAssertEqual(boundary.unconfirmedEnd, G7UnconfirmedSessionEnd(end: .sensorFailed, sensorClock: 300_000))
        report(300_059)
        XCTAssertFalse(boundary.sessionEnded, "59 s of sensor time")
        XCTAssertEqual(boundary.unconfirmedEnd?.sensorClock, 300_000, "a too-early report does not replace the first")
        report(300_060)
        XCTAssertEqual(boundary.sessionEnd, .sensorFailed, "60 s")
        XCTAssertNil(boundary.unconfirmedEnd)

        let restored = G7ReadingPipeline(serial: serial, reportedParameters: tenDayParameters, sessionStart: t0,
                                         unconfirmedEnd: G7UnconfirmedSessionEnd(end: .expired, sensorClock: 300_000)) { _ in }
        restored.beginConnection()
        _ = restored.handleGlucose(glucose(Fixture.glucose(sensorClock: 299_000, age: 5, glucose: nil, state: 0x18)), receivedAt: arrival(299_000, t0: t0))
        XCTAssertFalse(restored.sessionEnded, "a report with an earlier sensor clock never confirms")
    }

    /// Last minor: a restored first end report more than an hour of sensor time old (its clearing save
    /// may have failed) is discarded, so one later report cannot latch the end; within the hour it
    /// still confirms.
    func test_S5_staleUnconfirmedEndIsDiscarded() {
        let t0 = receivedAt
        let old = G7UnconfirmedSessionEnd(end: .sensorFailed, sensorClock: 200_000)
        func restored() -> G7ReadingPipeline {
            G7ReadingPipeline(serial: serial, reportedParameters: tenDayParameters, sessionStart: t0, unconfirmedEnd: old) { _ in }
        }
        func report(_ pipeline: G7ReadingPipeline, _ clock: UInt32) -> SensorState? {
            pipeline.beginConnection()
            return pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: clock, age: 5, glucose: nil, state: 0x19)), receivedAt: arrival(clock, t0: t0)).state
        }
        let stale = restored()
        XCTAssertEqual(report(stale, 203_601), .error(code: 0x19, description: "Sensor failed"))
        XCTAssertFalse(stale.sessionEnded, "3 601 s after the restored report")
        XCTAssertEqual(stale.unconfirmedEnd, G7UnconfirmedSessionEnd(end: .sensorFailed, sensorClock: 203_601), "the new report is the first")
        XCTAssertEqual(report(stale, 203_901), .failed(G7FailureReason.sensorFailed), "the next wake confirms")

        let recent = restored()
        _ = report(recent, 203_600)
        XCTAssertEqual(recent.sessionEnd, .sensorFailed, "exactly one hour still confirms")
    }

    /// N1 follow-up (probe P8c with relaunch): the first end report survives in the pairing record, so
    /// a report after the app was terminated and relaunched confirms it.
    func test_S5_unconfirmedEndSurvivesARelaunch() throws {
        let t0 = receivedAt
        let first = makePipeline()
        first.beginConnection()
        _ = first.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_000, age: 5, glucose: nil, state: 0x19)), receivedAt: arrival(200_000, t0: t0))
        let pending = try XCTUnwrap(first.unconfirmedEnd)

        let relaunched = G7ReadingPipeline(serial: serial, reportedParameters: tenDayParameters, sessionStart: first.sessionStart,
                                           unconfirmedEnd: pending) { _ in }
        relaunched.beginConnection()
        let output = relaunched.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_300, age: 5, glucose: nil, state: 0x19)), receivedAt: arrival(200_300, t0: t0))
        XCTAssertEqual(relaunched.sessionEnd, .sensorFailed)
        XCTAssertEqual(output.state, .failed(G7FailureReason.sensorFailed))

        // A running-session report after the relaunch clears the restored first report instead.
        let cleared = G7ReadingPipeline(serial: serial, reportedParameters: tenDayParameters, sessionStart: first.sessionStart,
                                        unconfirmedEnd: pending) { _ in }
        cleared.beginConnection()
        _ = cleared.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_300, age: 5, glucose: 120, state: 0x06)), receivedAt: arrival(200_300, t0: t0))
        XCTAssertNil(cleared.unconfirmedEnd)
        cleared.beginConnection()
        _ = cleared.handleGlucose(glucose(Fixture.glucose(sensorClock: 200_600, age: 5, glucose: nil, state: 0x19)), receivedAt: arrival(200_600, t0: t0))
        XCTAssertFalse(cleared.sessionEnded)
    }

    // MARK: - S2

    /// Warm-up readings carry numbers (G7SensorKitTests/G7GlucoseMessageTests.swift:40-66: 145, 125,
    /// 101, 78 mg/dL with state 0x02; xDrip Tests/DexcomG7CalibrationTests.swift:655-669 mentions 44,
    /// 71, 80, 93 from a field log). None may be emitted.
    func test_S2_warmUpReadingsAreNotEmitted() throws {
        let t0 = receivedAt
        let pipeline = makePipeline()
        pipeline.beginConnection()
        let vectors = [
            "4e00b6000000010000006600ffff017fffff00", "4e00cd000000030000010500ffff027fffff01",
            "4e00f90100000400000105009100027effff02", "4e00250300000500000105007d00027effff02",
            "4e0051040000060000010500650002dfffff02", "4e007d0500000700000105004e0002e7ffff02",
        ]
        var states: [SensorState] = []
        for hex in vectors {
            let message = glucose(Data(hex: hex))
            pipeline.beginConnection()
            let output = pipeline.handleGlucose(message, receivedAt: arrival(message.sensorClock, t0: t0))
            XCTAssertTrue(output.readings.isEmpty, hex)
            states.append(try XCTUnwrap(output.state))
        }
        XCTAssertTrue(states.allSatisfy { if case .warmingUp = $0 { return true } else { return false } }, "\(states)")
        XCTAssertFalse(pipeline.sessionEnded, "0x01 at activation is not a stopped session")
        // The first OK packets (sensor times 1700 and 2000) are emitted.
        let ok1 = glucose(Data(hex: "4e00ab060000080000010700540006f5ffff0e"))
        let ok2 = glucose(Data(hex: "4e00d507000009000001050061000601ffff0e"))
        pipeline.beginConnection()
        XCTAssertEqual(pipeline.handleGlucose(ok1, receivedAt: arrival(ok1.sensorClock, t0: t0)).readings.map(\.value), [.mgdl(84)])
        pipeline.beginConnection()
        let output = pipeline.handleGlucose(ok2, receivedAt: arrival(ok2.sensorClock, t0: t0))
        XCTAssertEqual(output.readings.map(\.value), [.mgdl(97)])
        if case .active = output.state {} else { XCTFail("expected active, got \(String(describing: output.state))") }
    }

    /// Every algorithm state except OK withholds the value, live and backfill.
    func test_S2_invalidAlgorithmStatesAreNotEmitted() {
        for raw in UInt8.min...UInt8.max where raw != 0x06 {
            let pipeline = makePipeline()
            pipeline.beginConnection()
            let output = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 300_000, age: 5, glucose: 120, state: raw)), receivedAt: receivedAt)
            XCTAssertTrue(output.readings.isEmpty, "state 0x\(String(raw, radix: 16))")
            XCTAssertNotNil(output.state)
            pipeline.handleBackfillFrame(Fixture.backfill(timestamp: 299_695, glucose: 118, state: raw), now: receivedAt)
            XCTAssertTrue(pipeline.flushBackfill().readings.isEmpty, "backfill state 0x\(String(raw, radix: 16))")
        }
    }

    /// Expired: the sensor's own expired state (captured 0x18, 7 h after the end) is shown as an
    /// unconfirmed `.error` and, once a second connection reports it too, ends the session as
    /// `.expired` (D41); an "OK" value whose derived time is past the grace end is refused.
    func test_S2_expiredReadingsAreNotEmitted() throws {
        let pipeline = makePipeline()
        pipeline.beginConnection()
        let captured = glucose(Data(hex: "4e004d440e00d40b0001d46b650018036a000e"))
        let expired = pipeline.handleGlucose(captured, receivedAt: receivedAt)
        XCTAssertTrue(expired.readings.isEmpty)
        XCTAssertEqual(expired.state, .error(code: 0x18, description: "Session expired"), "one report is not a confirmed end (D41)")
        XCTAssertFalse(pipeline.sessionEnded, "one report is not enough (N1)")
        pipeline.beginConnection()
        let again = Fixture.glucose(sensorClock: captured.sensorClock + 300, age: 5, glucose: nil, state: 0x18)
        XCTAssertEqual(pipeline.handleGlucose(glucose(again), receivedAt: receivedAt.addingTimeInterval(300)).state, .expired)
        XCTAssertEqual(pipeline.sessionEnd, .expired)
        XCTAssertNil(pipeline.session)

        let pastGrace = makePipeline()
        pastGrace.beginConnection()
        let afterEnd = Fixture.glucose(sensorClock: 907_200 + 600, age: 5, glucose: 120, state: 0x06)
        let output = pastGrace.handleGlucose(glucose(afterEnd), receivedAt: receivedAt)
        XCTAssertTrue(output.readings.isEmpty)
        XCTAssertEqual(output.state, .error(code: 0x06, description: "OK, past the session end (not confirmed)"),
                       "the start came from this packet's own clock")
        XCTAssertTrue(logs.contains { $0.contains("afterSessionEnd") })
        pastGrace.beginConnection()
        let later = Fixture.glucose(sensorClock: 907_200 + 900, age: 5, glucose: 121, state: 0x06)
        XCTAssertEqual(pastGrace.handleGlucose(glucose(later), receivedAt: receivedAt.addingTimeInterval(300)).state, .expired,
                       "the grace end passed by time against an established start")

        let inGrace = makePipeline()
        inGrace.beginConnection()
        let graceOutput = inGrace.handleGlucose(glucose(Fixture.glucose(sensorClock: 864_000 + 600, age: 5, glucose: 120, state: 0x06)), receivedAt: receivedAt)
        XCTAssertEqual(graceOutput.readings.count, 1, "valid during the 12 h grace period")
        if case .gracePeriod = graceOutput.state {} else { XCTFail("expected grace period") }
    }

    /// A non-zero response status carries an old cached value (xDrip Tests/DexcomG7CalibrationTests.swift:373-382).
    func test_S2_statusReplyWithCachedValueIsNotEmitted() {
        let pipeline = makePipeline()
        pipeline.beginConnection()
        let output = pipeline.handleGlucose(glucose(Data(hex: "4e80a26b0200e8010001793990001b04ab0000")), receivedAt: receivedAt)
        XCTAssertTrue(output.readings.isEmpty)
        XCTAssertEqual(output.state, .error(code: 0x1B, description: "Sensor failed"))
        XCTAssertNil(pipeline.clock, "a status reply does not anchor the clock")
        XCTAssertNil(pipeline.sessionStart)
        XCTAssertFalse(pipeline.sessionEnded, "a status reply may be cached: it never ends the session (N1)")
    }

    /// A reading with an impossible age, or no value, or a backfill record in the future is refused.
    func test_S2_implausibleTimesAndMissingValuesAreNotEmitted() {
        let first = makePipeline()
        first.beginConnection()
        XCTAssertTrue(first.handleGlucose(glucose(Fixture.glucose(sensorClock: 10, age: 20, glucose: 100, state: 0x06)), receivedAt: receivedAt).readings.isEmpty)

        let second = makePipeline()
        second.beginConnection()
        let output = second.handleGlucose(glucose(Fixture.glucose(sensorClock: 90_000, age: 5, glucose: nil, state: 0x06)), receivedAt: receivedAt)
        XCTAssertTrue(output.readings.isEmpty)
        XCTAssertEqual(output.state, .failed(G7FailureReason.noGlucoseValue), "OK without a value is surfaced (S5)")
        second.handleBackfillFrame(Fixture.backfill(timestamp: 95_000, glucose: 100), now: receivedAt)
        XCTAssertTrue(second.flushBackfill().readings.isEmpty, "a record 5 000 s after 'now' is in the future")
    }

    /// Minor 1: until the sensor has reported its session length, nothing is published and the reason
    /// is surfaced (the cycle asks `52` before GetData, so this is the fallback if it went unanswered).
    func test_S2_nothingPublishedBeforeTheSessionLengthIsReported() {
        let pipeline = makePipeline(parameters: nil)
        pipeline.beginConnection()
        let output = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 100_000, age: 5, glucose: 100, state: 0x06)), receivedAt: receivedAt)
        XCTAssertTrue(output.readings.isEmpty)
        XCTAssertEqual(output.state, .failed(G7FailureReason.sessionLengthUnknown))
        XCTAssertNil(pipeline.session)
    }

    /// A 15-day sensor (captured `0x52`) is refused: no readings, failed state (HANDOFF §1.1).
    func test_S2_unsupportedSensorEmitsNothing() {
        let pipeline = makePipeline(parameters: nil)
        pipeline.beginConnection()
        let refused = pipeline.handleExtendedVersion(G7ExtendedVersionMessage(Fixture.fifteenDayExtendedVersion)!)
        XCTAssertEqual(refused.state, .failed(G7FailureReason.unsupportedSensor))
        let output = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 100_000, age: 5, glucose: 100, state: 0x06)), receivedAt: receivedAt)
        XCTAssertTrue(output.readings.isEmpty)
        pipeline.handleBackfillFrame(Fixture.backfill(timestamp: 99_000, glucose: 100), now: receivedAt)
        XCTAssertTrue(pipeline.flushBackfill().readings.isEmpty)
        XCTAssertNil(pipeline.session)
    }

    /// Every emitted reading passes the shared gate against the session.
    func test_S2_everyEmittedReadingPassesLiveReadingGate() throws {
        let pipeline = makePipeline(parameters: nil)
        pipeline.beginConnection()
        XCTAssertNil(pipeline.handleExtendedVersion(G7ExtendedVersionMessage(Fixture.tenDayExtendedVersion)!).state)
        _ = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 400_000, age: 5, glucose: 150, state: 0x06)), receivedAt: receivedAt)
        for step in 1...20 {
            pipeline.handleBackfillFrame(Fixture.backfill(timestamp: UInt32(400_000 - 5 - 300 * step), glucose: UInt16(100 + step)), now: receivedAt)
        }
        let readings = pipeline.flushBackfill().readings
        XCTAssertEqual(readings.count, 20)
        let session = try XCTUnwrap(pipeline.session)
        for reading in readings {
            XCTAssertNoThrow(try LiveReadingGate.validate(reading, session: session, now: receivedAt))
            XCTAssertEqual(reading.source, .sensor)
            XCTAssertEqual(reading.sensorSerial, serial)
        }
    }

    // MARK: - S4 and D31

    /// A LOW (below 40) or HIGH (above 400) value stays a flag through the pipeline, live and backfill.
    func test_S4_lowAndHighFlagsArePreserved() throws {
        let pipeline = makePipeline()
        pipeline.beginConnection()
        let low = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 500_000, age: 5, glucose: 38, state: 0x06)), receivedAt: receivedAt)
        XCTAssertEqual(low.readings.map(\.value), [.belowRange])
        XCTAssertNil(low.readings.first?.value.numericMgdl, "never 40")
        pipeline.beginConnection()
        let high = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 500_300, age: 5, glucose: 425, state: 0x06)), receivedAt: receivedAt.addingTimeInterval(300))
        XCTAssertEqual(high.readings.map(\.value), [.aboveRange])
        XCTAssertNil(high.readings.first?.value.numericMgdl, "never 400")
        pipeline.handleBackfillFrame(Fixture.backfill(timestamp: 499_695, glucose: 20), now: receivedAt.addingTimeInterval(300))
        pipeline.handleBackfillFrame(Fixture.backfill(timestamp: 499_095, glucose: 40), now: receivedAt.addingTimeInterval(300))
        pipeline.handleBackfillFrame(Fixture.backfill(timestamp: 499_395, glucose: 401), now: receivedAt.addingTimeInterval(300))
        XCTAssertEqual(pipeline.flushBackfill().readings.map(\.value), [.mgdl(40), .aboveRange, .belowRange])
    }

    /// D31 / probe P3: raw 0, 0x0FFF and 0xFFFE are "no value" — withheld, logged, surfaced — never
    /// LOW/HIGH; live and backfill.
    func test_S4_noValueRawsAreWithheldNotFlags() {
        let t0 = receivedAt
        var raw = [UInt8](Fixture.glucose(sensorClock: 200_600, age: 5, glucose: 100, state: 0x06))
        raw[12] = 0xFE
        raw[13] = 0xFF
        let cases: [(String, Data, UInt32)] = [
            ("0", Fixture.glucose(sensorClock: 200_000, age: 5, glucose: 0, state: 0x06), 200_000),
            ("0x0FFF", Fixture.glucose(sensorClock: 200_300, age: 5, glucose: 0x0FFF, state: 0x06), 200_300),
            ("0xFFFE", Data(raw), 200_600),
        ]
        for (name, data, clock) in cases {
            let pipeline = makePipeline()
            pipeline.beginConnection()
            let output = pipeline.handleGlucose(glucose(data), receivedAt: arrival(clock, t0: t0))
            XCTAssertTrue(output.readings.isEmpty, name)
            XCTAssertEqual(output.state, .failed(G7FailureReason.noGlucoseValue), name)
            pipeline.handleBackfillFrame(Fixture.backfill(timestamp: clock - 305, glucose: name == "0" ? 0 : 0x0FFF), now: arrival(clock, t0: t0))
            XCTAssertTrue(pipeline.flushBackfill().readings.isEmpty, name)
        }
        XCTAssertTrue(logs.contains { $0.contains("no usable value") })
    }

    // MARK: - S1

    /// A display-only value is the sensor echoing a calibration: never a reading (live or backfill).
    func test_S1_displayOnlyCalibrationValueIsNotEmitted() {
        let pipeline = makePipeline()
        pipeline.beginConnection()
        // Captured display-only packet (G7SensorKitTests/G7GlucoseMessageTests.swift:24-31).
        let output = pipeline.handleGlucose(glucose(Data(hex: "4e000ec10d00c00b00010000680006fe63001f")), receivedAt: receivedAt)
        XCTAssertTrue(output.readings.isEmpty)
        // Clock 901 390 s (10.43 days): the sensor is running, in its grace period.
        if case .gracePeriod = output.state {} else { XCTFail("the sensor is still running, got \(String(describing: output.state))") }
        pipeline.handleBackfillFrame(Fixture.backfill(timestamp: 901_000, glucose: 100, flags: 0x1E), now: receivedAt)
        XCTAssertTrue(pipeline.flushBackfill().readings.isEmpty)
    }
}

final class G7SensorStatusTests: XCTestCase {
    private let session = SensorSession(
        serial: "S", start: Date(timeIntervalSince1970: 0), warmUpEndsAt: Date(timeIntervalSince1970: 1_620),
        expiresAt: Date(timeIntervalSince1970: 864_000), gracePeriodEndsAt: Date(timeIntervalSince1970: 907_200)
    )

    func test_S5_bluetoothStatesAreSurfaced() {
        XCTAssertEqual(G7SensorStatus.state(for: .poweredOff), .bluetoothUnavailable(.poweredOff))
        XCTAssertEqual(G7SensorStatus.state(for: .unauthorized), .bluetoothUnavailable(.unauthorized))
        XCTAssertEqual(G7SensorStatus.state(for: .unsupported), .bluetoothUnavailable(.unsupported))
        XCTAssertEqual(G7SensorStatus.state(for: .resetting), .bluetoothUnavailable(.resetting))
        XCTAssertNil(G7SensorStatus.state(for: .poweredOn))
        XCTAssertNil(G7SensorStatus.state(for: .unknown))
    }

    func test_algorithmStatesMapToSensorStates() {
        let early = Date(timeIntervalSince1970: 600)
        let mid = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(G7SensorStatus.state(for: .ok, session: session, now: mid), .active(sessionStart: session.start, expiresAt: session.expiresAt))
        XCTAssertEqual(G7SensorStatus.state(for: .ok, session: session, now: Date(timeIntervalSince1970: 900_000)), .gracePeriod(endsAt: session.gracePeriodEndsAt))
        XCTAssertEqual(G7SensorStatus.state(for: .ok, session: session, now: Date(timeIntervalSince1970: 907_201)), .expired)
        XCTAssertEqual(G7SensorStatus.state(for: .warmUp, session: session, now: early), .warmingUp(endsAt: session.warmUpEndsAt))
        XCTAssertEqual(G7SensorStatus.state(for: G7AlgorithmState(rawValue: 0x01), session: session, now: early), .warmingUp(endsAt: session.warmUpEndsAt))
        XCTAssertEqual(G7SensorStatus.state(for: G7AlgorithmState(rawValue: 0x01), session: session, now: mid), .error(code: 1, description: "Session stopped"))
        XCTAssertEqual(G7SensorStatus.state(for: G7AlgorithmState(rawValue: 0x0F), session: session, now: mid), .error(code: 0x0F, description: "Session expired"),
                       "a single expired report is unconfirmed (D41)")
        for raw: UInt8 in [0x04, 0x05, 0x07, 0x0E] {
            XCTAssertEqual(G7SensorStatus.state(for: G7AlgorithmState(rawValue: raw), session: session, now: mid), .calibrationNeeded(code: Int(raw)))
        }
        for raw: UInt8 in [0x08, 0x09, 0x0A, 0x0D] {
            XCTAssertEqual(G7SensorStatus.state(for: G7AlgorithmState(rawValue: raw), session: session, now: mid), .calibrationError(code: Int(raw)))
        }
        XCTAssertEqual(G7SensorStatus.state(for: G7AlgorithmState(rawValue: 0x12), session: session, now: mid), .error(code: 0x12, description: "Temporary sensor issue"))
    }

    /// D28: only the sensor's own status reports an end; time past grace is checked where read.
    func test_whichStatesEndTheSession() {
        let mid = Date(timeIntervalSince1970: 100_000)
        func end(_ raw: UInt8, _ now: Date = mid) -> G7SessionEnd? {
            let algorithm = G7AlgorithmState(rawValue: raw)
            return G7SensorStatus.sessionEnd(for: G7SensorStatus.state(for: algorithm, session: session, now: now), algorithmState: algorithm)
        }
        XCTAssertEqual(end(0x19), .sensorFailed)
        XCTAssertEqual(end(0x0B), .sensorFailed)
        XCTAssertEqual(end(0x0F), .expired)
        XCTAssertEqual(end(0x18), .expired)
        XCTAssertEqual(end(0x01), .stopped, "stopped after warm-up")
        XCTAssertNil(end(0x01, Date(timeIntervalSince1970: 600)), "stopped at activation")
        XCTAssertNil(end(0x06, Date(timeIntervalSince1970: 1_000_000)), "OK past grace is a time check, not an end")
        XCTAssertNil(end(0x12), "temporary issue")
        XCTAssertNil(end(0x07), "calibration needed")
        XCTAssertNil(end(0x02), "warm-up")
    }

    /// D36: every failure G7Kit emits carries the agreed kind, so the alert engine raises the sensor
    /// alert only for "replace the sensor" and "pair again", never for transient conditions such as a
    /// clock mismatch or another app on the phone. Messages stay distinct and non-empty.
    func test_S5_failureKindsMatchTheContract() {
        let expected: [(SensorFailure, SensorFailure.Kind)] = [
            (G7FailureReason.pairingCodeRejected, .pairingRejected),
            (G7FailureReason.savedKeyRejected, .pairingRejected),
            (G7FailureReason.bluetoothPairingNotCompleted, .bluetoothPairingIncomplete),
            (G7FailureReason.bondRemovedBySensor, .bondRemoved),
            (G7FailureReason.unsupportedSensor, .unsupportedSensor),
            (G7FailureReason.authenticationFailed, .authenticationFailed),
            (G7FailureReason.pairingCodeNeeded, .pairingCodeNeeded),
            (G7FailureReason.sensorClockMismatch, .clockMismatch),
            (G7FailureReason.noGlucoseValue, .noGlucoseValue),
            (G7FailureReason.sessionLengthUnknown, .sessionLengthUnknown),
            (G7FailureReason.sensorFailed, .sensorFailed),
            (G7FailureReason.sessionStopped, .sessionStopped),
            (G7FailureReason.rejectedAfterAuthentication, .rejectedAfterAuthentication),
            (G7FailureReason.otherAppRejected, .otherAppRejected),
            (G7FailureReason.credentialsUnavailable, .credentialsUnavailable),
        ]
        for (failure, kind) in expected { XCTAssertEqual(failure.kind, kind, failure.message) }
        XCTAssertEqual(G7FailureReason.previousSensorRejectedCode(sensorName: "DXCM4F").kind, .pairingRejected)
        XCTAssertEqual(Set(expected.map(\.0.message)).count, expected.count)
        XCTAssertTrue(expected.allSatisfy { !$0.0.message.isEmpty })
        let alerting = Set(expected.filter { $0.0.raisesSensorAlert }.map(\.1))
        XCTAssertEqual(alerting, [.pairingRejected, .bondRemoved, .unsupportedSensor, .pairingCodeNeeded, .sensorFailed, .sessionStopped])
    }

    /// N1: a latched end is always visible, with its reason.
    func test_S5_latchedEndStatesAreVisible() {
        XCTAssertEqual(G7SessionEnd.expired.state, .expired)
        XCTAssertEqual(G7SessionEnd.sensorFailed.state, .failed(G7FailureReason.sensorFailed))
        XCTAssertEqual(G7SessionEnd.stopped.state, .failed(G7FailureReason.sessionStopped))
    }
}
