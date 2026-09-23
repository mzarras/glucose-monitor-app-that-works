// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// The original file carries no copyright header of its own.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/G7/CGMG7Transmitter.swift @ 7.1.0 (0370937)
// Changes: the calibration flow of CGMG7Transmitter (:889-937 queueing, :1644-1734
// sendCalibrationOrBoundsIfReady, :1736-1772 bounds request, :1774-1850 command response,
// :1852-1965 bounds, :1967-1974 validation, :2059-2069 requeue) without Core Data, reporting through
// GlucoseCore's CalibrationStatus. Sensor additions are marked "Sensor policy".

import Foundation
import GlucoseCore

/// One calibration at a time: queued → sent → accepted / rejected / unknown.
///
/// A calibration is never a reading (S1): nothing here produces a `GlucoseReading`, and the only
/// outputs are `CalibrationUpdate`s and diagnostic log lines.
final class G7CalibrationQueue {
    /// Fingerstick values the G7 accepts, mg/dL: CGMG7Transmitter.swift:1967-1974
    /// (`calibration.bg >= 40 && calibration.bg <= 400`, "the supported 40 to 400 mg/dL range").
    static let acceptedRange: ClosedRange<Int> = 40...400
    /// A fingerstick older than this is not sent: ConstantsDexcomG5.swift:23-24
    /// (`maxUnSentCalibrationAge = 5 min`), applied to G7 at CGMG7Transmitter.swift:1971-1972 and
    /// re-checked at transmission time (:1655-1674).
    static let maximumAgeBeforeSending: TimeInterval = 5 * 60
    /// Sensor policy (not in xDrip4iOS): stop waiting for the `0x32` record after this long, so a
    /// lost record cannot block calibration forever. xDrip4iOS waits indefinitely.
    static let maximumWaitForSensorRecord: TimeInterval = 60 * 60
    /// Sensor rejection code 8 ("not permitted"), reused when the `0x32` record says calibrations
    /// are not permitted (CGMG7Transmitter.swift:1916-1931).
    static let notPermittedCode = 8

    private enum Phase: Equatable {
        case queued
        /// `0x34` written; waiting for its 4-byte response.
        case awaitingResponse
        /// The sensor accepted the command; waiting for a matching completed `0x32` record.
        case awaitingRecord(since: Date)
    }

    private struct Tracked {
        let request: CalibrationRequest
        var phase: Phase
        /// Sensor time sent in the last `0x34` for this request.
        var sensorTime: UInt32?
    }

    struct Context {
        let isPaired: Bool
        /// A confirmed key exists and the sensor has not rejected it.
        let isAuthenticated: Bool
        /// The latest sensor-reported state (not Bluetooth states), or nil if none yet.
        let sensorState: SensorState?
    }

    private var tracked: Tracked?
    private var commandSentThisConnection = false
    private var recordRequestedThisConnection = false
    private let emit: (CalibrationUpdate) -> Void
    private let log: (String) -> Void

    init(emit: @escaping (CalibrationUpdate) -> Void, log: @escaping (String) -> Void) {
        self.emit = emit
        self.log = log
    }

    var hasCalibrationInProgress: Bool { tracked != nil }

    /// Refuses (S2) unless paired, authenticated and the sensor is running; validates the value.
    func submit(_ request: CalibrationRequest, context: Context, now: Date) throws(CalibrationRefusal) {
        guard context.isPaired else { throw .notPaired }
        guard context.isAuthenticated, let sensorState = context.sensorState else { throw .notAuthenticated }
        switch sensorState {
        case .warmingUp:
            throw .warmingUp
        case .active, .gracePeriod:
            break
        case .error(let code, _):
            // A running sensor that reports a calibration request, calibration error or temporary
            // issue may calibrate; a failed or stopped one may not.
            switch G7AlgorithmState(rawValue: UInt8(clamping: code)).category {
            case .calibrationNeeded, .calibrationError, .temporaryIssue: break
            default: throw .sessionEnded
            }
        case .expired, .failed, .notPaired, .searching, .connecting, .authenticating, .bluetoothUnavailable:
            throw .sessionEnded
        }
        guard Self.acceptedRange.contains(request.mgdl) else { throw .valueOutOfRange(accepted: Self.acceptedRange) }
        guard tracked == nil else { throw .anotherCalibrationInProgress }

        log("calibration \(request.id): submitted \(request.mgdl) mg/dL taken \(request.takenAt)")
        tracked = Tracked(request: request, phase: .queued, sensorTime: nil)
        emit(CalibrationUpdate(requestID: request.id, status: .queued))
        // Time checks mirror xDrip4iOS's `calibrationIsValid` (:1970-1972). CalibrationRefusal has no
        // case for a bad time, so the request finishes at once as `.unknown` (see OPEN QUESTIONS).
        if let problem = Self.timeProblem(takenAt: request.takenAt, now: now) {
            finish(.unknown(description: "Not sent: \(problem)"))
        }
    }

    func beginConnection() {
        commandSentThisConnection = false
        recordRequestedThisConnection = false
    }

    /// The next calibration command for this connection, once the sensor clock is known:
    /// `0x34` for a queued request, else `0x32` while waiting for the record
    /// (CGMG7Transmitter.swift:1644-1734). At most one of each per connection.
    func nextCommand(clock: G7SessionClock, now: Date) -> Data? {
        guard var current = tracked else { return nil }
        switch current.phase {
        case .queued:
            guard !commandSentThisConnection else { return nil }
            if let problem = Self.timeProblem(takenAt: current.request.takenAt, now: now) {
                finish(.unknown(description: "Not sent: \(problem) when the sensor next connected"))
                return nil
            }
            guard let sensorTime = clock.sensorTime(for: current.request.takenAt) else {
                finish(.unknown(description: "Not sent: the fingerstick is earlier than the sensor session"))
                return nil
            }
            commandSentThisConnection = true
            current.phase = .awaitingResponse
            current.sensorTime = sensorTime
            tracked = current
            log("calibration \(current.request.id): sending \(current.request.mgdl) mg/dL at sensor time \(sensorTime)")
            emit(CalibrationUpdate(requestID: current.request.id, status: .sent))
            return G7CalibrationCommand(glucose: UInt16(current.request.mgdl), sensorTime: sensorTime).data
        case .awaitingRecord(let since):
            if now.timeIntervalSince(since) > Self.maximumWaitForSensorRecord {
                finish(.unknown(description: "The sensor accepted the calibration but never reported the result"))
                return nil
            }
            guard !recordRequestedThisConnection else { return nil }
            recordRequestedThisConnection = true
            return G7ControlRequest.calibrationBounds
        case .awaitingResponse:
            return nil
        }
    }

    /// CoreBluetooth refused the `0x34` write: back to queued for the next connection (:787-807).
    func commandWriteFailed() {
        guard var current = tracked, current.phase == .awaitingResponse else { return }
        current.phase = .queued
        tracked = current
        log("calibration \(current.request.id): write failed; queued for the next connection")
        emit(CalibrationUpdate(requestID: current.request.id, status: .queued))
    }

    /// The immediate `0x34` response (CGMG7Transmitter.swift:1774-1850).
    func handleCommandResponse(_ response: G7CalibrationCommandResponse, now: Date) {
        guard var current = tracked, current.phase == .awaitingResponse else {
            log("calibration: response \(response.status) with no command in flight; ignored")
            return
        }
        log("calibration \(current.request.id): response \(response.status)")
        switch response.status {
        case .acceptedHigh(.accepted), .acceptedLow(.accepted), .factoryCalibrated:
            current.phase = .awaitingRecord(since: now)
            tracked = current
        case .acceptedHigh(let detail), .acceptedLow(let detail):
            finish(.unknown(description: "The sensor acknowledged the calibration with error detail \(detail)"))
        case .rejected(let reason) where reason.meansAlreadyProcessing:
            // An earlier copy (e.g. a retry after a lost response) is already being processed.
            current.phase = .awaitingRecord(since: now)
            tracked = current
        case .rejected(let reason):
            finish(.rejected(code: Int(reason.code), reason: reason.humanDescription))
        case .unknown(let primary, let secondary):
            finish(.unknown(description: "Unrecognised calibration response (primary \(primary), secondary \(secondary))"))
        }
    }

    /// The `0x32` record (CGMG7Transmitter.swift:1852-1965).
    func handleBounds(_ record: G7CalibrationBounds) {
        guard let current = tracked, case .awaitingRecord = current.phase, let sensorTime = current.sensorTime else {
            log("calibration: record for \(record.glucose) mg/dL at \(record.calibrationTime) with nothing awaiting it; ignored")
            return
        }
        guard record.matches(glucose: UInt16(current.request.mgdl), sensorTime: sensorTime) else {
            if record.calibrationTime > sensorTime + 2 {
                // Sensor policy: a newer calibration (another display) replaced ours; it will never match.
                finish(.unknown(description: "Replaced on the sensor by a newer calibration from another device"))
            } else {
                log("calibration \(current.request.id): record for an earlier calibration; waiting")
            }
            return
        }
        guard record.calibrationsPermitted else {
            finish(.rejected(code: Self.notPermittedCode, reason: G7CalibrationRejectionReason.notPermitted.humanDescription))
            return
        }
        switch record.processingState {
        case .inProgress:
            log("calibration \(current.request.id): sensor still processing")
        case .completeHigh, .completeLow:
            finish(.accepted)
        case .noCalibration, .factoryCalibrated, nil:
            finish(.unknown(description: "Sensor calibration record state \(record.processingRawValue)"))
        }
    }

    /// A `0x34` without its response is re-queued for the next connection (:2059-2069).
    func endConnection() {
        guard var current = tracked, current.phase == .awaitingResponse else { return }
        current.phase = .queued
        tracked = current
        log("calibration \(current.request.id): no response before disconnect; queued again")
        emit(CalibrationUpdate(requestID: current.request.id, status: .queued))
    }

    /// Forget sensor: an unfinished calibration ends as unknown.
    func cancelAll(reason: String) {
        if tracked != nil { finish(.unknown(description: reason)) }
    }

    private func finish(_ status: CalibrationStatus) {
        guard let current = tracked else { return }
        tracked = nil
        log("calibration \(current.request.id): \(status)")
        emit(CalibrationUpdate(requestID: current.request.id, status: status))
    }

    /// xDrip4iOS `calibrationIsValid` time rule: 0 ≤ age ≤ 5 min (CGMG7Transmitter.swift:1971-1972).
    static func timeProblem(takenAt: Date, now: Date) -> String? {
        let age = now.timeIntervalSince(takenAt)
        if age < 0 { return "the fingerstick time is in the future" }
        if age > maximumAgeBeforeSending { return "the fingerstick is older than 5 minutes" }
        return nil
    }
}
