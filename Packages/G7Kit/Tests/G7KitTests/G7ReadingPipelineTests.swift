// Original to Sensor (no ported code). Captured vectors are cited where they are used.

import GlucoseCore
import XCTest
@testable import G7Kit

final class G7ReadingPipelineTests: XCTestCase {
    private let serial = "DXCM4F-1A2B3C4D"
    private let receivedAt = Date(timeIntervalSince1970: 1_790_000_000)
    private var logs: [String] = []

    private func makePipeline(parameters: G7SensorLifetime.Parameters? = nil) -> G7ReadingPipeline {
        G7ReadingPipeline(serial: serial, reportedParameters: parameters) { [weak self] in self?.logs.append($0) }
    }

    private func glucose(_ data: Data) -> G7GlucoseMessage { G7GlucoseMessage(data)! }

    // MARK: - S3

    /// The same physical reading received live and as backfill (LoopKit's captured pair,
    /// G7SensorKitTests/G7GlucoseMessageTests.swift:120-126 and :143-151) gets the same id AND the
    /// same date, even when the backfill copy arrives on a later connection.
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
        let backfilled = try XCTUnwrap(second.flushBackfill().first)
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
        let batch = pipeline.flushBackfill()
        XCTAssertEqual(batch.map(\.id), ["\(serial):99995"])
        XCTAssertEqual(Set(batch.map(\.id)).count, batch.count)
    }

    /// Backfill keeps each record's own timestamp, is flagged, and comes out in ascending order.
    func test_S3_backfillKeepsOriginalTimestampsAndFlagInOrder() throws {
        let pipeline = makePipeline()
        pipeline.beginConnection()
        _ = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 50_000, age: 4, glucose: 100, state: 0x06)), receivedAt: receivedAt)
        let clock = try XCTUnwrap(pipeline.clock)
        for timestamp: UInt32 in [49_096, 48_496, 48_796] {
            pipeline.handleBackfillFrame(Fixture.backfill(timestamp: timestamp, glucose: 90), now: receivedAt)
        }
        let batch = pipeline.flushBackfill()
        XCTAssertEqual(batch.map(\.id), ["\(serial):48496", "\(serial):48796", "\(serial):49096"])
        XCTAssertEqual(batch.map(\.date), [48_496, 48_796, 49_096].map { clock.sessionStart.addingTimeInterval($0) })
        XCTAssertTrue(batch.allSatisfy(\.isBackfill))
    }

    /// A live reading must be newer than everything already published (monotonic).
    func test_S3_liveReadingsAreMonotonic() {
        let pipeline = makePipeline()
        pipeline.beginConnection()
        XCTAssertEqual(pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 60_000, age: 5, glucose: 100, state: 0x06)), receivedAt: receivedAt).readings.count, 1)
        let older = Fixture.glucose(sensorClock: 59_700, age: 5, glucose: 99, state: 0x06)
        XCTAssertTrue(pipeline.handleGlucose(glucose(older), receivedAt: receivedAt).readings.isEmpty)
    }

    /// Records that arrive before this connection's `0x4E` wait for its clock; without one they are
    /// discarded at disconnect, never dated with an old or assumed clock.
    func test_S3_backfillWaitsForTheConnectionsSensorClock() {
        let pipeline = makePipeline()
        pipeline.beginConnection()
        pipeline.handleBackfillFrame(Fixture.backfill(timestamp: 69_700, glucose: 95), now: receivedAt)
        XCTAssertTrue(pipeline.flushBackfill().isEmpty)
        _ = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 70_000, age: 3, glucose: 97, state: 0x06)), receivedAt: receivedAt)
        XCTAssertEqual(pipeline.endConnection().map(\.id), ["\(serial):69700"])

        pipeline.beginConnection()
        pipeline.handleBackfillFrame(Fixture.backfill(timestamp: 70_000, glucose: 95), now: receivedAt)
        XCTAssertTrue(pipeline.endConnection().isEmpty)
        XCTAssertTrue(logs.contains { $0.contains("discarded 1 record") })
    }

    // MARK: - S2

    /// Warm-up readings carry numbers (G7SensorKitTests/G7GlucoseMessageTests.swift:40-66: 145, 125,
    /// 101, 78 mg/dL with state 0x02; xDrip Tests/DexcomG7CalibrationTests.swift:655-669 mentions 44,
    /// 71, 80, 93 from a field log). None may be emitted.
    func test_S2_warmUpReadingsAreNotEmitted() throws {
        let pipeline = makePipeline()
        pipeline.beginConnection()
        let vectors = [
            "4e00b6000000010000006600ffff017fffff00", "4e00cd000000030000010500ffff027fffff01",
            "4e00f90100000400000105009100027effff02", "4e00250300000500000105007d00027effff02",
            "4e0051040000060000010500650002dfffff02", "4e007d0500000700000105004e0002e7ffff02",
        ]
        var states: [SensorState] = []
        for (index, hex) in vectors.enumerated() {
            let output = pipeline.handleGlucose(glucose(Data(hex: hex)), receivedAt: receivedAt.addingTimeInterval(Double(index) * 300))
            XCTAssertTrue(output.readings.isEmpty, hex)
            states.append(try XCTUnwrap(output.state))
        }
        XCTAssertTrue(states.allSatisfy { if case .warmingUp = $0 { return true } else { return false } }, "\(states)")
        // The first OK packets (sensor times 1700 and 2000) are emitted.
        let ok1 = pipeline.handleGlucose(glucose(Data(hex: "4e00ab060000080000010700540006f5ffff0e")), receivedAt: receivedAt.addingTimeInterval(1_800))
        let ok2 = pipeline.handleGlucose(glucose(Data(hex: "4e00d507000009000001050061000601ffff0e")), receivedAt: receivedAt.addingTimeInterval(2_100))
        XCTAssertEqual(ok1.readings.map(\.value), [.mgdl(84)])
        XCTAssertEqual(ok2.readings.map(\.value), [.mgdl(97)])
        if case .active = ok2.state {} else { XCTFail("expected active, got \(String(describing: ok2.state))") }
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
            XCTAssertTrue(pipeline.flushBackfill().isEmpty, "backfill state 0x\(String(raw, radix: 16))")
        }
    }

    /// Expired: the sensor's own expired state (captured 0x18, 7 h after the end), and an "OK" value
    /// whose derived time is past the grace period, are both refused.
    func test_S2_expiredReadingsAreNotEmitted() throws {
        let pipeline = makePipeline()
        pipeline.beginConnection()
        let expired = pipeline.handleGlucose(glucose(Data(hex: "4e004d440e00d40b0001d46b650018036a000e")), receivedAt: receivedAt)
        XCTAssertTrue(expired.readings.isEmpty)
        XCTAssertEqual(expired.state, .expired)

        let pastGrace = makePipeline()
        pastGrace.beginConnection()
        let afterEnd = Fixture.glucose(sensorClock: 907_200 + 600, age: 5, glucose: 120, state: 0x06)
        let output = pastGrace.handleGlucose(glucose(afterEnd), receivedAt: receivedAt)
        XCTAssertTrue(output.readings.isEmpty)
        XCTAssertEqual(output.state, .expired)
        XCTAssertTrue(logs.contains { $0.contains("afterSessionEnd") })

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
    }

    /// A reading dated in the future (sensor clock behind the reading) or with no value is refused.
    func test_S2_implausibleTimesAndMissingValuesAreNotEmitted() {
        let pipeline = makePipeline()
        pipeline.beginConnection()
        XCTAssertTrue(pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 10, age: 20, glucose: 100, state: 0x06)), receivedAt: receivedAt).readings.isEmpty)
        XCTAssertTrue(pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 90_000, age: 5, glucose: nil, state: 0x06)), receivedAt: receivedAt).readings.isEmpty)
        pipeline.handleBackfillFrame(Fixture.backfill(timestamp: 95_000, glucose: 100), now: receivedAt)
        XCTAssertTrue(pipeline.flushBackfill().isEmpty, "a record 5 000 s after 'now' is in the future")
    }

    /// A 15-day sensor (captured `0x52`) is refused: no readings, failed state (HANDOFF §1.1).
    func test_S2_unsupportedSensorEmitsNothing() {
        let pipeline = makePipeline()
        pipeline.beginConnection()
        let refused = pipeline.handleExtendedVersion(G7ExtendedVersionMessage(Fixture.fifteenDayExtendedVersion)!)
        XCTAssertEqual(refused.state, .failed(reason: G7FailureReason.unsupportedSensor))
        let output = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 100_000, age: 5, glucose: 100, state: 0x06)), receivedAt: receivedAt)
        XCTAssertTrue(output.readings.isEmpty)
        pipeline.handleBackfillFrame(Fixture.backfill(timestamp: 99_000, glucose: 100), now: receivedAt)
        XCTAssertTrue(pipeline.flushBackfill().isEmpty)
    }

    /// The reported 10-day warm-up replaces the default; every emitted reading passes the shared gate.
    func test_S2_everyEmittedReadingPassesLiveReadingGate() throws {
        let pipeline = makePipeline()
        pipeline.beginConnection()
        _ = pipeline.handleGlucose(glucose(Fixture.glucose(sensorClock: 400_000, age: 5, glucose: 150, state: 0x06)), receivedAt: receivedAt)
        XCTAssertEqual(pipeline.handleExtendedVersion(G7ExtendedVersionMessage(Fixture.tenDayExtendedVersion)!).state, nil)
        for step in 1...20 {
            pipeline.handleBackfillFrame(Fixture.backfill(timestamp: UInt32(400_000 - 5 - 300 * step), glucose: UInt16(100 + step)), now: receivedAt)
        }
        let readings = pipeline.flushBackfill()
        XCTAssertEqual(readings.count, 20)
        let session = try XCTUnwrap(pipeline.session)
        for reading in readings {
            XCTAssertNoThrow(try LiveReadingGate.validate(reading, session: session, now: receivedAt))
            XCTAssertEqual(reading.source, .sensor)
            XCTAssertEqual(reading.sensorSerial, serial)
        }
    }

    // MARK: - S4

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
        XCTAssertEqual(pipeline.flushBackfill().map(\.value), [.mgdl(40), .aboveRange, .belowRange])
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
        XCTAssertTrue(pipeline.flushBackfill().isEmpty)
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
        XCTAssertEqual(G7SensorStatus.state(for: G7AlgorithmState(rawValue: 0x0F), session: session, now: mid), .expired)
        XCTAssertEqual(G7SensorStatus.state(for: G7AlgorithmState(rawValue: 0x07), session: session, now: mid), .error(code: 7, description: "Calibration needed"))
        XCTAssertEqual(G7SensorStatus.state(for: G7AlgorithmState(rawValue: 0x12), session: session, now: mid), .error(code: 0x12, description: "Temporary sensor issue"))
    }
}
