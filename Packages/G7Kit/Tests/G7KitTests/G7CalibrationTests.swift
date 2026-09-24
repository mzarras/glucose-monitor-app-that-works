// Original to Sensor (no ported code).

import GlucoseCore
import XCTest
@testable import G7Kit

final class G7CalibrationQueueTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var updates: [CalibrationUpdate] = []
    private var queue: G7CalibrationQueue!
    private let active = SensorState.active(sessionStart: Date(timeIntervalSince1970: 1_789_800_000), expiresAt: Date(timeIntervalSince1970: 1_790_664_000))

    override func setUp() {
        super.setUp()
        updates = []
        queue = G7CalibrationQueue(emit: { [unowned self] in updates.append($0) }, log: { _ in })
    }

    private func context(paired: Bool = true, authenticated: Bool = true, state: SensorState?) -> G7CalibrationQueue.Context {
        G7CalibrationQueue.Context(isPaired: paired, isAuthenticated: authenticated, sensorState: state)
    }

    private var statuses: [CalibrationStatus] { updates.map(\.status) }

    /// The sensor clock read `sensorClock` at `now`.
    private func clock(_ sensorClock: UInt32 = 200_000) -> G7SessionClock {
        G7SessionClock(sensorClockAtReceipt: sensorClock, receivedAt: now)
    }

    func test_S2_calibrationRefusedWhenNotAuthenticatedOrWarmingUpOrExpired() {
        let request = CalibrationRequest(mgdl: 120, takenAt: now)
        func refusal(_ context: G7CalibrationQueue.Context) -> CalibrationRefusal? {
            do { try queue.submit(request, context: context, now: now); return nil } catch { return error }
        }
        XCTAssertEqual(refusal(context(paired: false, authenticated: false, state: nil)), .notPaired)
        XCTAssertEqual(refusal(context(authenticated: false, state: active)), .notAuthenticated)
        XCTAssertEqual(refusal(context(state: nil)), .notAuthenticated, "no sensor-reported state yet")
        XCTAssertEqual(refusal(context(state: .warmingUp(endsAt: now))), .warmingUp)
        XCTAssertEqual(refusal(context(state: .expired)), .sessionEnded)
        XCTAssertEqual(refusal(context(state: .failed(SensorFailure(kind: .other, message: "x")))), .sessionEnded)
        XCTAssertEqual(refusal(context(state: .error(code: 0x0B, description: "failed"))), .sessionEnded)
        XCTAssertEqual(refusal(context(state: .error(code: 0x01, description: "stopped"))), .sessionEnded)
        XCTAssertEqual(refusal(context(state: .bluetoothUnavailable(.poweredOff))), .sessionEnded)
        XCTAssertTrue(updates.isEmpty, "nothing was queued")
    }

    /// D36: a fingerstick time in the future or more than 5 minutes old is refused at submission with
    /// `invalidTime` (xDrip4iOS `calibrationIsValid`, CGMG7Transmitter.swift:1970-1972); nothing is queued.
    func test_S3_calibrationWithInvalidFingerstickTimeIsRefused() throws {
        func refusal(takenAt: Date) -> CalibrationRefusal? {
            do { try queue.submit(CalibrationRequest(mgdl: 120, takenAt: takenAt), context: context(state: active), now: now); return nil } catch { return error }
        }
        XCTAssertEqual(refusal(takenAt: now.addingTimeInterval(1)), .invalidTime, "in the future")
        XCTAssertEqual(refusal(takenAt: now.addingTimeInterval(-301)), .invalidTime, "older than 5 minutes")
        XCTAssertTrue(updates.isEmpty)
        XCTAssertFalse(queue.hasCalibrationInProgress)
        XCTAssertNil(refusal(takenAt: now.addingTimeInterval(-300)), "exactly 5 minutes is accepted")
        XCTAssertEqual(statuses, [.queued])
    }

    /// D37: while the clocks disagree the fingerstick cannot be placed in sensor time: `invalidTime`.
    func test_S3_calibrationRefusedWhileTheClocksDisagree() {
        var mismatch = context(state: active)
        mismatch.clockMismatch = true
        XCTAssertThrowsError(try queue.submit(CalibrationRequest(mgdl: 120, takenAt: now), context: mismatch, now: now)) {
            XCTAssertEqual($0 as? CalibrationRefusal, .invalidTime)
        }
        XCTAssertTrue(updates.isEmpty)
    }

    /// D36: the calibration states let a running sensor calibrate; a temporary issue does too.
    func test_calibrationStatesMayCalibrate() throws {
        for state: SensorState in [.calibrationNeeded(code: 0x07), .calibrationError(code: 0x08), .error(code: 0x12, description: "Temporary sensor issue")] {
            setUp()
            XCTAssertNoThrow(try queue.submit(CalibrationRequest(mgdl: 120, takenAt: now), context: context(state: state), now: now), "\(state)")
            XCTAssertEqual(statuses, [.queued])
        }
    }

    /// 40...400 mg/dL (CGMG7Transmitter.swift:1967-1974); a running sensor asking for a calibration
    /// (0x07) or in grace may calibrate; one at a time.
    func test_valueRangeAndOneAtATime() throws {
        XCTAssertThrowsError(try queue.submit(CalibrationRequest(mgdl: 39, takenAt: now), context: context(state: active), now: now)) {
            XCTAssertEqual($0 as? CalibrationRefusal, .valueOutOfRange(accepted: 40...400))
        }
        XCTAssertThrowsError(try queue.submit(CalibrationRequest(mgdl: 401, takenAt: now), context: context(state: active), now: now))
        try queue.submit(CalibrationRequest(mgdl: 40, takenAt: now), context: context(state: .calibrationNeeded(code: 0x07)), now: now)
        XCTAssertThrowsError(try queue.submit(CalibrationRequest(mgdl: 400, takenAt: now), context: context(state: .gracePeriod(endsAt: now)), now: now)) {
            XCTAssertEqual($0 as? CalibrationRefusal, .anotherCalibrationInProgress)
        }
        XCTAssertEqual(statuses, [.queued])
    }

    /// S3: fingerstick time → sensor time from the sensor-reported clock
    /// (DexcomG7CalibrationMessages.swift:273-288; xDrip Tests/DexcomG7CalibrationTests.swift:74-80).
    func test_S3_calibrationTimeConvertedToTransmitterTime() throws {
        let reference = G7SessionClock(sensorClockAtReceipt: 10_000, receivedAt: now)
        XCTAssertEqual(reference.sensorTime(for: now.addingTimeInterval(-90)), 9_910)
        XCTAssertEqual(reference.sensorTime(for: now.addingTimeInterval(30)), 10_030)
        XCTAssertEqual(reference.sensorTime(for: now.addingTimeInterval(-10_001)), nil, "before the session")
        XCTAssertEqual(reference.sensorTime(for: now.addingTimeInterval(-89.6)), 9_910, "rounded to whole seconds")

        try queue.submit(CalibrationRequest(mgdl: 153, takenAt: now.addingTimeInterval(-90)), context: context(state: active), now: now)
        let command = try XCTUnwrap(queue.nextCommand(clock: reference, now: now))
        // 34 | 9900 = 153 | b6260000 = 9910 | CRC
        XCTAssertEqual(command.prefix(7), Data([0x34, 0x99, 0x00, 0xB6, 0x26, 0x00, 0x00]))
        XCTAssertTrue(G7CRC16.isValid([UInt8](command)))
        XCTAssertEqual(statuses, [.queued, .sent])
    }

    /// queued → sent → (0x34 accepted) → (0x32 in progress) → (0x32 complete) → accepted.
    func test_acceptedThroughTheSensorRecord() throws {
        let request = CalibrationRequest(mgdl: 110, takenAt: now.addingTimeInterval(-60))
        try queue.submit(request, context: context(state: active), now: now)
        queue.beginConnection()
        XCTAssertNotNil(queue.nextCommand(clock: clock(), now: now))
        queue.handleCommandResponse(G7CalibrationCommandResponse(Data([0x34, 0, 0, 0]))!, now: now)
        XCTAssertEqual(queue.nextCommand(clock: clock(), now: now), Data([0x32]))
        XCTAssertNil(queue.nextCommand(clock: clock(), now: now), "one record request per connection")
        // Record for OUR calibration (110 mg/dL at sensor time 199 940), still in progress.
        queue.handleBounds(bounds(glucose: 110, time: 199_940, processing: 2))
        XCTAssertEqual(statuses, [.queued, .sent])
        queue.beginConnection()
        XCTAssertEqual(queue.nextCommand(clock: clock(200_300), now: now.addingTimeInterval(300)), Data([0x32]))
        queue.handleBounds(bounds(glucose: 110, time: 199_941, processing: 3))
        XCTAssertEqual(statuses, [.queued, .sent, .accepted])
        XCTAssertFalse(queue.hasCalibrationInProgress)
        XCTAssertEqual(Set(updates.map(\.requestID)), [request.id])
    }

    /// Every documented sensor rejection reaches the caller with its own code.
    func test_everyRejectionReasonIsReportedWithItsCode() throws {
        for code in UInt8(0)...11 where code != 3 && code != 6 {
            setUp()
            try queue.submit(CalibrationRequest(mgdl: 100, takenAt: now), context: context(state: active), now: now)
            _ = queue.nextCommand(clock: clock(), now: now)
            queue.handleCommandResponse(G7CalibrationCommandResponse(Data([0x34, 0, 2, code]))!, now: now)
            let reason = G7CalibrationRejectionReason(code: code)
            XCTAssertEqual(statuses.last, .rejected(code: Int(code), reason: reason.humanDescription))
        }
    }

    /// Duplicate / already-entered (a retried command) wait for the record (CGMG7Transmitter.swift:1833-1835).
    func test_duplicateWaitsForTheRecordAndNotPermittedIsARejection() throws {
        try queue.submit(CalibrationRequest(mgdl: 100, takenAt: now), context: context(state: active), now: now)
        _ = queue.nextCommand(clock: clock(), now: now)
        queue.handleCommandResponse(G7CalibrationCommandResponse(Data([0x34, 0, 2, 3]))!, now: now)
        XCTAssertEqual(statuses, [.queued, .sent])
        queue.beginConnection()
        _ = queue.nextCommand(clock: clock(), now: now)
        queue.handleBounds(bounds(glucose: 100, time: 200_000, processing: 2, permitted: false))
        XCTAssertEqual(statuses.last, .rejected(code: 8, reason: "Calibration not permitted now"))
    }

    func test_unknownOutcomesAreReportedAsUnknown() throws {
        // Accepted with an error detail, unrecognised primary status.
        for response in [[0x34, 0, 0, 1], [0x34, 0, 9, 7]] as [[UInt8]] {
            setUp()
            try queue.submit(CalibrationRequest(mgdl: 100, takenAt: now), context: context(state: active), now: now)
            _ = queue.nextCommand(clock: clock(), now: now)
            queue.handleCommandResponse(G7CalibrationCommandResponse(Data(response))!, now: now)
            guard case .unknown = statuses.last else { return XCTFail("\(statuses)") }
        }
        // A matching record with state "none", and a newer calibration from another device.
        for record in [bounds(glucose: 100, time: 200_000, processing: 0), bounds(glucose: 90, time: 200_100, processing: 3)] {
            setUp()
            try queue.submit(CalibrationRequest(mgdl: 100, takenAt: now), context: context(state: active), now: now)
            _ = queue.nextCommand(clock: clock(), now: now)
            queue.handleCommandResponse(G7CalibrationCommandResponse(Data([0x34, 0, 1, 0]))!, now: now)
            queue.handleBounds(record)
            guard case .unknown = statuses.last else { return XCTFail("\(statuses)") }
        }
    }

    /// A stale record for the previous calibration is ignored (xDrip Tests/DexcomG7CalibrationTests.swift:36-42).
    func test_staleRecordIsIgnoredAndWaitIsBounded() throws {
        try queue.submit(CalibrationRequest(mgdl: 100, takenAt: now), context: context(state: active), now: now)
        _ = queue.nextCommand(clock: clock(), now: now)
        queue.handleCommandResponse(G7CalibrationCommandResponse(Data([0x34, 0, 0, 0]))!, now: now)
        queue.handleBounds(bounds(glucose: 107, time: 199_000, processing: 3))
        XCTAssertEqual(statuses, [.queued, .sent])
        queue.beginConnection()
        XCTAssertNil(queue.nextCommand(clock: clock(), now: now.addingTimeInterval(3_601)))
        guard case .unknown = statuses.last else { return XCTFail("\(statuses)") }
    }

    /// Interrupted commands are retried as xDrip4iOS does (CGMG7Transmitter.swift:2059-2069, :793-807);
    /// a fingerstick older than 5 minutes is not sent (ConstantsDexcomG5.swift:24).
    func test_interruptedCommandIsRequeuedAndStaleOnesAreNotSent() throws {
        try queue.submit(CalibrationRequest(mgdl: 100, takenAt: now), context: context(state: active), now: now)
        queue.beginConnection()
        _ = queue.nextCommand(clock: clock(), now: now)
        queue.commandWriteFailed()
        XCTAssertEqual(statuses, [.queued, .sent, .queued])
        XCTAssertNil(queue.nextCommand(clock: clock(), now: now), "one command per connection")
        queue.beginConnection()
        _ = queue.nextCommand(clock: clock(), now: now.addingTimeInterval(60))
        queue.endConnection()
        XCTAssertEqual(statuses.last, .queued, "no response before disconnect")
        queue.beginConnection()
        XCTAssertNil(queue.nextCommand(clock: clock(), now: now.addingTimeInterval(301)))
        guard case .unknown(let description) = statuses.last else { return XCTFail("\(statuses)") }
        XCTAssertTrue(description.contains("older than 5 minutes"), "a queued request that went stale is not sent")
        XCTAssertFalse(queue.hasCalibrationInProgress)
    }

    private func bounds(glucose: UInt16, time: UInt32, processing: UInt8, permitted: Bool = true) -> G7CalibrationBounds {
        var bytes: [UInt8] = [0x32, 0x00, 0x01] + G7Bytes.littleEndian(UInt32(116))
        bytes += G7Bytes.littleEndian(glucose) + G7Bytes.littleEndian(time)
        bytes += [processing, permitted ? 1 : 0, 0x02] + G7Bytes.littleEndian(time + 100)
        return G7CalibrationBounds(Data(bytes))!
    }
}

final class G7CalibrationEndToEndTests: XCTestCase {
    /// S1: submitting and completing a calibration never produces a GlucoseReading, and the
    /// display-only value the sensor reports after it is not published either.
    func test_S1_calibrationIsNeverEmittedAsReading() throws {
        let harness = ControllerHarness()
        try harness.pair(glucose: harness.currentGlucose(123))
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(123)])

        let request = CalibrationRequest(mgdl: 187, takenAt: harness.clock.now)
        try harness.controller.submitCalibration(request)
        harness.clock.advance(120)
        let sensorTime = harness.sensorClock - 120
        harness.sensor.calibrationResponse = Data([0x34, 0x00, 0x00, 0x00])
        var record: [UInt8] = [0x32, 0x00, 0x01] + G7Bytes.littleEndian(UInt32(116)) + G7Bytes.littleEndian(UInt16(187))
        record += G7Bytes.littleEndian(sensorTime) + [0x03, 0x01, 0x02] + G7Bytes.littleEndian(sensorTime + 60)
        harness.sensor.boundsResponse = Data(record)
        let link = harness.connection(glucose: harness.currentGlucose(126))
        XCTAssertEqual(harness.calibrations.map(\.status), [.queued, .sent, .accepted])
        XCTAssertTrue(harness.sensor.controlWrites.contains { $0.first == 0x34 })
        XCTAssertTrue(link.allWrites.contains { $0.data == Data([0x32]) })

        // The next reading is display-only (the sensor echoing the calibration).
        harness.clock.advance(180)
        harness.connection(glucose: harness.currentGlucose(187, flags: 0x1F))
        XCTAssertEqual(harness.readings.map(\.value), [.mgdl(123), .mgdl(126)])
        XCTAssertFalse(harness.readings.contains { $0.value == .mgdl(187) })
    }

    func test_calibrationRefusedBeforePairingAndDuringWarmUp() throws {
        let unpaired = ControllerHarness()
        XCTAssertThrowsError(try unpaired.controller.submitCalibration(CalibrationRequest(mgdl: 100, takenAt: unpaired.clock.now))) {
            XCTAssertEqual($0 as? CalibrationRefusal, .notPaired)
        }
        let warming = ControllerHarness(sessionAge: 10 * 60)
        try warming.pair(glucose: warming.currentGlucose(nil, state: 0x02))
        XCTAssertThrowsError(try warming.controller.submitCalibration(CalibrationRequest(mgdl: 100, takenAt: warming.clock.now))) {
            XCTAssertEqual($0 as? CalibrationRefusal, .warmingUp)
        }
    }
}
