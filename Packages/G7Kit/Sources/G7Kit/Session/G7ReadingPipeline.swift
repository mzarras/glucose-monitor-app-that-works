// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// The original file carries no copyright header of its own.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/G7/CGMG7Transmitter.swift @ 7.1.0 (0370937)
// Changes: the glucose/backfill handling of CGMG7Transmitter (processGlucose :1104-1175,
// handleBackfillValue :1569-1585, processPendingBackfillFramesIfPossible :2113-2127,
// appendBackfillMessage :2129-2140, flushBackfillDeliveringToDelegate :2142-2155) rewritten as a
// pure type with the S1-S4 rules below. Not ported: the "six identical values" filter (:1135-1141,
// see docs/g7-protocol.md "What was stripped"); Core Data / UserDefaults / delegate plumbing.

import Foundation
import GlucoseCore

/// Turns authenticated G7 messages into published readings and sensor states.
///
/// A reading is published only if ALL hold (S1-S4):
/// 1. it arrived on an authenticated connection (G7ConnectionCycle forwards nothing before);
/// 2. the sensor has reported its session length (`0x52`, requested before GetData) and it is the
///    supported 10-day length;
/// 3. `0x4E` response status is 0 (CGMG7Transmitter.swift:1031-1053; G7SensorKit G7GlucoseMessage.swift:87);
/// 4. the algorithm state is OK, 0x06 (G7SensorKit AlgorithmState.swift:104-115); for backfill the
///    record's own state byte is checked too;
/// 5. the glucose field is a value, not "no value" (0xFFFF, 0xFFFE, 0, 0x0FFF: D31, G7GlucoseRange);
/// 6. it is not display-only: that is the sensor echoing a calibration, and a calibration is never
///    a reading (S1; LoopKit stores it as `wasUserEntered`, G7SensorKit G7CGMManager.swift:408-409);
/// 7. this connection's sensor clock agrees with the session start (see "Session clock" below);
/// 8. it passes `LiveReadingGate.validate` against the session (defence in depth);
/// 9. its sensor timestamp was not published before (S3 dedupe), and a live reading is newer than
///    every published one, in sensor time and in date (monotonic).
/// LOW/HIGH stay flags (S4, G7GlucoseRange).
///
/// Session clock (S3, safety review M2). The session start is derived once per serial from the
/// first status-0 `0x4E` (receipt − sensor clock, G7SessionClock) and then kept: every reading is
/// dated `sessionStart + sensor timestamp`, so dates never jitter with transmission latency and the
/// live and backfill copies of a reading always get the same date. Each later `0x4E` is checked
/// against it: within `anchorTolerance` it agrees; beyond it, the connection's readings are withheld
/// and `.failed(sensorClockMismatch)` is reported, and only a second, agreeing anchor may replace the
/// start. A single garbled packet can therefore neither move the session nor end it.
///
/// Backfill records arriving before this connection's `0x4E` are held raw until the clock is checked;
/// undatable records are discarded at disconnect (CGMG7Transmitter.swift:656-667). Each batch is
/// published in ascending sensor-timestamp order, flagged `isBackfill`.
final class G7ReadingPipeline {
    struct Output: Equatable {
        var readings: [GlucoseReading] = []
        var state: SensorState?
    }

    /// Sensor policy (safety review M2): anchors within 30 s of the session start agree
    /// (transmission latency and slow clock drift); a larger difference is a clock problem.
    static let anchorTolerance: TimeInterval = 30

    let serial: String
    /// Reported by the sensor in `0x52`; nil until then (no reading is published without it).
    private(set) var parameters: G7SensorLifetime.Parameters?
    private(set) var isUnsupportedSensor = false
    /// Fixed per serial from the sensor clock (see type documentation); persisted by the controller.
    private(set) var sessionStart: Date?
    /// The sensor itself reported the session over (expired, failed, stopped after warm-up). The
    /// grace-period end is a time check made by the reader of the session (and LiveReadingGate), so a
    /// garbled anchor can never end a session permanently.
    private(set) var sessionEnded: Bool
    /// This connection's anchor, set only when it agrees with `sessionStart`.
    private(set) var clock: G7SessionClock?

    private var pendingAnchorStart: Date?
    private var publishedTimestamps: Set<UInt32> = []
    private var newestPublishedTimestamp: UInt32?
    private var newestLiveDate: Date?
    private var pendingBackfillFrames: [Data] = []
    private var backfillBatch: [UInt32: GlucoseReading] = [:]
    private let log: (String) -> Void

    init(
        serial: String,
        reportedParameters: G7SensorLifetime.Parameters?,
        sessionStart: Date? = nil,
        sessionEnded: Bool = false,
        log: @escaping (String) -> Void
    ) {
        self.serial = serial
        self.parameters = reportedParameters
        self.sessionStart = sessionStart
        self.sessionEnded = sessionEnded
        self.log = log
    }

    /// The session readings are checked against; nil when unknown, ended or unsupported (D28).
    var session: SensorSession? {
        guard !isUnsupportedSensor, !sessionEnded, let sessionStart, let parameters else { return nil }
        return G7SensorLifetime.session(serial: serial, start: sessionStart, parameters: parameters)
    }

    /// A new physical connection: the previous anchor and any raw frames belong to the old one.
    func beginConnection() {
        clock = nil
        pendingBackfillFrames.removeAll()
        backfillBatch.removeAll()
    }

    /// Handles one `0x4E` received at `receivedAt` on an authenticated connection.
    func handleGlucose(_ message: G7GlucoseMessage, receivedAt: Date) -> Output {
        var output = Output()
        if isUnsupportedSensor {
            output.state = .failed(reason: G7FailureReason.unsupportedSensor)
            return output
        }
        guard let parameters else {
            log("glucose: the sensor has not reported its session length; nothing used")
            output.state = .failed(reason: G7FailureReason.sessionLengthUnknown)
            return output
        }
        let anchor = G7SessionClock(sensorClockAtReceipt: message.sensorClock, receivedAt: receivedAt)

        // A non-zero response status is a status reply that may carry an old cached value: surface
        // the state, keep nothing else from it, and never let it move the clock (CGMG7Transmitter.swift:1031-1053).
        guard message.responseStatus == 0 else {
            output.state = sensorState(message.algorithmState, start: sessionStart ?? anchor.sessionStart, parameters: parameters, now: receivedAt)
            log("glucose: response status 0x\(String(message.responseStatus, radix: 16)) state \(message.algorithmState.name); not published")
            return output
        }
        guard acceptAnchor(anchor.sessionStart), let start = sessionStart else {
            output.state = .failed(reason: G7FailureReason.sensorClockMismatch)
            return output
        }
        clock = anchor
        output.state = sensorState(message.algorithmState, start: start, parameters: parameters, now: receivedAt)
        guard !sessionEnded, let session else { return output }

        switch liveReading(from: message, start: start, session: session, now: receivedAt) {
        case .published(let timestamp, let reading):
            publish(timestamp: timestamp)
            newestLiveDate = reading.date
            output.readings.append(reading)
        case .withheld(let surfacedReason):
            if let surfacedReason { output.state = .failed(reason: surfacedReason) }
        }
        let frames = pendingBackfillFrames
        pendingBackfillFrames.removeAll()
        for frame in frames { decodeBackfill(frame, now: receivedAt) }
        return output
    }

    /// A 9-byte record from the Backfill characteristic.
    func handleBackfillFrame(_ frame: Data, now: Date) {
        guard !isUnsupportedSensor, !sessionEnded else { return }
        if clock == nil {
            pendingBackfillFrames.append(frame)
        } else {
            decodeBackfill(frame, now: now)
        }
    }

    /// `0x59` backfill finished: publish the batch in ascending order.
    func flushBackfill() -> [GlucoseReading] {
        let timestamps = backfillBatch.keys.sorted()
        let batch = timestamps.compactMap { backfillBatch[$0] }
        backfillBatch.removeAll()
        for timestamp in timestamps { publish(timestamp: timestamp) }
        return batch
    }

    /// Disconnect: publish what could be dated, discard the rest (CGMG7Transmitter.swift:656-667).
    func endConnection() -> [GlucoseReading] {
        if !pendingBackfillFrames.isEmpty {
            log("backfill: discarded \(pendingBackfillFrames.count) record(s) without an agreeing sensor clock")
            pendingBackfillFrames.removeAll()
        }
        let batch = flushBackfill()
        clock = nil
        return batch
    }

    /// `0x52`: adopt reported timing, or refuse the sensor (non-goal products).
    func handleExtendedVersion(_ message: G7ExtendedVersionMessage) -> Output {
        guard let reported = G7SensorLifetime.parameters(reportedSessionLength: message.sessionLength, reportedWarmUp: message.warmUpDuration) else {
            isUnsupportedSensor = true
            backfillBatch.removeAll()
            pendingBackfillFrames.removeAll()
            log("extended version: unsupported session length \(message.sessionLength) s / warm-up \(message.warmUpDuration) s")
            return Output(readings: [], state: .failed(reason: G7FailureReason.unsupportedSensor))
        }
        parameters = reported
        return Output()
    }

    // MARK: - Private

    private enum LiveOutcome {
        case published(timestamp: UInt32, reading: GlucoseReading)
        /// `surfacedReason` is reported as `.failed(reason:)` (S5); nil for normal non-publication.
        case withheld(surfacedReason: String?)
    }

    /// Establishes the session start, confirms it, or (after two agreeing anchors) replaces it.
    /// Returns false when this anchor disagrees: the connection's readings are withheld.
    private func acceptAnchor(_ anchorStart: Date) -> Bool {
        guard let established = sessionStart else {
            sessionStart = anchorStart
            log("session start derived from the sensor clock")
            return true
        }
        let difference = anchorStart.timeIntervalSince(established)
        if abs(difference) <= Self.anchorTolerance {
            pendingAnchorStart = nil
            if abs(difference) > 5 { log("sensor clock anchor differs by \(Int(difference)) s (within tolerance)") }
            return true
        }
        if let pending = pendingAnchorStart, abs(anchorStart.timeIntervalSince(pending)) <= Self.anchorTolerance {
            sessionStart = anchorStart
            pendingAnchorStart = nil
            log("session start re-anchored by \(Int(difference)) s after two agreeing sensor clocks")
            return true
        }
        pendingAnchorStart = anchorStart
        log("sensor clock disagrees with the session start by \(Int(difference)) s; readings withheld")
        return false
    }

    private func sensorState(_ algorithmState: G7AlgorithmState, start: Date, parameters: G7SensorLifetime.Parameters, now: Date) -> SensorState {
        let session = G7SensorLifetime.session(serial: serial, start: start, parameters: parameters)
        let state = G7SensorStatus.state(for: algorithmState, session: session, now: now)
        if !sessionEnded, G7SensorStatus.endsSession(state, algorithmState: algorithmState) {
            sessionEnded = true
            backfillBatch.removeAll()
            pendingBackfillFrames.removeAll()
            log("session ended: \(state)")
        }
        return state
    }

    private func liveReading(from message: G7GlucoseMessage, start: Date, session: SensorSession, now: Date) -> LiveOutcome {
        guard message.algorithmState.category == .ok else {
            log("glucose: state \(message.algorithmState.name); not published")
            return .withheld(surfacedReason: nil)
        }
        let value: GlucoseValue
        switch G7GlucoseRange.classify(field: message.glucoseField) {
        case .noValue(let field):
            log("glucose: no usable value (field 0x\(String(field, radix: 16))); not published")
            return .withheld(surfacedReason: G7FailureReason.noGlucoseValue)
        case .value(let classified):
            value = classified
        }
        guard !message.isDisplayOnly else {
            log("glucose: display-only (calibration) value; not published (S1)")
            return .withheld(surfacedReason: nil)
        }
        guard let timestamp = message.readingSensorTimestamp else {
            log("glucose: age \(message.age) exceeds sensor clock \(message.sensorClock); not published")
            return .withheld(surfacedReason: nil)
        }
        guard !publishedTimestamps.contains(timestamp) else {
            log("glucose: sensor timestamp \(timestamp) already published")
            return .withheld(surfacedReason: nil)
        }
        if let newest = newestPublishedTimestamp, timestamp <= newest {
            log("glucose: sensor timestamp \(timestamp) not newer than \(newest); not published")
            return .withheld(surfacedReason: nil)
        }
        let reading = makeReading(value: value, trendRate: message.trendRate, timestamp: timestamp, start: start, isBackfill: false)
        if let newestLiveDate, reading.date <= newestLiveDate {
            log("glucose: date \(reading.date) not after the last published \(newestLiveDate); not published")
            return .withheld(surfacedReason: G7FailureReason.sensorClockMismatch)
        }
        guard let valid = validated(reading, session: session, now: now) else { return .withheld(surfacedReason: nil) }
        return .published(timestamp: timestamp, reading: valid)
    }

    private func decodeBackfill(_ frame: Data, now: Date) {
        guard clock != nil, let start = sessionStart, let session else { return }
        guard let message = G7BackfillMessage(frame) else {
            log("backfill: malformed record \(frame.hexString)")
            return
        }
        guard message.algorithmState.category == .ok else {
            log("backfill: record at \(message.sensorTimestamp) in state \(message.algorithmState.name); not published")
            return
        }
        guard case .value(let value) = G7GlucoseRange.classify(field: message.glucoseField) else {
            log("backfill: record at \(message.sensorTimestamp) has no usable value (field 0x\(String(message.glucoseField, radix: 16))); not published")
            return
        }
        guard !message.isDisplayOnly else {
            log("backfill: record at \(message.sensorTimestamp) is display-only; not published (S1)")
            return
        }
        let timestamp = message.sensorTimestamp
        guard !publishedTimestamps.contains(timestamp), backfillBatch[timestamp] == nil else { return }
        let reading = makeReading(value: value, trendRate: message.trendRate, timestamp: timestamp, start: start, isBackfill: true)
        if let valid = validated(reading, session: session, now: now) {
            backfillBatch[timestamp] = valid
        }
    }

    private func makeReading(value: GlucoseValue, trendRate: Double?, timestamp: UInt32, start: Date, isBackfill: Bool) -> GlucoseReading {
        GlucoseReading(
            id: GlucoseReading.sensorID(serial: serial, sensorTimestamp: timestamp),
            date: start.addingTimeInterval(TimeInterval(timestamp)),
            value: value,
            trendRate: trendRate,
            isBackfill: isBackfill,
            source: .sensor,
            sensorSerial: serial
        )
    }

    /// Final assertion (S2, defence in depth): anything the shared gate refuses is dropped and logged.
    private func validated(_ reading: GlucoseReading, session: SensorSession, now: Date) -> GlucoseReading? {
        do {
            try LiveReadingGate.validate(reading, session: session, now: now)
            return reading
        } catch {
            log("reading \(reading.id) refused by LiveReadingGate: \(error)")
            return nil
        }
    }

    private func publish(timestamp: UInt32) {
        publishedTimestamps.insert(timestamp)
        if newestPublishedTimestamp.map({ timestamp > $0 }) ?? true {
            newestPublishedTimestamp = timestamp
        }
    }
}
