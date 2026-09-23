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
/// A reading is published only if ALL hold (S2, S1, S4, S3):
/// 1. it arrived on an authenticated connection (the connection only forwards messages after
///    authentication, G7ConnectionCycle);
/// 2. `0x4E` response status is 0 (CGMG7Transmitter.swift:1031-1053; G7SensorKit G7GlucoseMessage.swift:87);
/// 3. the algorithm state is OK, 0x06 (G7SensorKit AlgorithmState.swift:104-115); for backfill the
///    record's own state byte is checked too;
/// 4. the glucose field is not the 0xFFFF "none" sentinel;
/// 5. it is not display-only: a display-only value is the sensor echoing a calibration, and a
///    calibration is never a reading (S1; LoopKit maps display-only to `wasUserEntered`,
///    G7SensorKit G7CGMManager.swift:408-409);
/// 6. its date, derived from the sensor clock (G7SessionClock, S3), passes `LiveReadingGate.validate`
///    against the session derived from the same clock (defence in depth: session bounds, warm-up,
///    grace end, future tolerance, value range, serial);
/// 7. its sensor timestamp has not been published before (S3 dedupe by sensor timestamp), and a
///    live reading is strictly newer than every reading already published (monotonic).
/// LOW/HIGH are mapped to flags, never numbers (S4, G7GlucoseRange).
///
/// Backfill records arriving before this connection's `0x4E` are held raw until the clock exists,
/// then dated; undatable records are discarded at disconnect (CGMG7Transmitter.swift:656-667).
/// Each backfill batch is published in ascending sensor-timestamp order, flagged `isBackfill`.
final class G7ReadingPipeline {
    struct Output: Equatable {
        var readings: [GlucoseReading] = []
        var state: SensorState?
    }

    let serial: String
    private(set) var parameters: G7SensorLifetime.Parameters
    private(set) var isUnsupportedSensor = false
    /// This connection's anchor; nil until its first status-0 `0x4E`.
    private(set) var clock: G7SessionClock?
    /// The latest session derived from a sensor clock (kept across connections).
    private(set) var session: SensorSession?

    private var publishedTimestamps: Set<UInt32> = []
    private var newestPublishedTimestamp: UInt32?
    private var pendingBackfillFrames: [Data] = []
    private var backfillBatch: [UInt32: GlucoseReading] = [:]
    private let log: (String) -> Void

    init(serial: String, reportedParameters: G7SensorLifetime.Parameters?, log: @escaping (String) -> Void) {
        self.serial = serial
        self.parameters = reportedParameters ?? G7SensorLifetime.defaults
        self.log = log
    }

    /// A new physical connection: the previous anchor and any raw frames belong to the old one.
    func beginConnection() {
        clock = nil
        pendingBackfillFrames.removeAll()
        backfillBatch.removeAll()
    }

    /// Handles one `0x4E` received at `receivedAt` on an authenticated connection.
    func handleGlucose(_ message: G7GlucoseMessage, receivedAt: Date) -> Output {
        let messageClock = G7SessionClock(sensorClockAtReceipt: message.sensorClock, receivedAt: receivedAt)
        let messageSession = messageClock.session(serial: serial, parameters: parameters)
        var output = Output()
        if isUnsupportedSensor {
            output.state = .failed(reason: G7FailureReason.unsupportedSensor)
            return output
        }
        output.state = G7SensorStatus.state(for: message.algorithmState, session: messageSession, now: receivedAt)

        // A non-zero response status is a status reply that may carry an old cached value: surface
        // the state, keep nothing else from it (CGMG7Transmitter.swift:1031-1053).
        guard message.responseStatus == 0 else {
            log("glucose: response status 0x\(String(message.responseStatus, radix: 16)) state \(message.algorithmState.name); not published")
            return output
        }
        clock = messageClock
        session = messageSession

        if let live = liveReading(from: message, clock: messageClock, session: messageSession, now: receivedAt) {
            publish(timestamp: live.timestamp)
            output.readings.append(live.reading)
        }
        let frames = pendingBackfillFrames
        pendingBackfillFrames.removeAll()
        for frame in frames { decodeBackfill(frame, now: receivedAt) }
        return output
    }

    /// A 9-byte record from the Backfill characteristic.
    func handleBackfillFrame(_ frame: Data, now: Date) {
        guard !isUnsupportedSensor else { return }
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
            log("backfill: discarded \(pendingBackfillFrames.count) record(s) that arrived without a sensor clock")
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
        if let clock { session = clock.session(serial: serial, parameters: reported) }
        return Output()
    }

    // MARK: - Private

    private func liveReading(from message: G7GlucoseMessage, clock: G7SessionClock, session: SensorSession, now: Date) -> (timestamp: UInt32, reading: GlucoseReading)? {
        guard message.algorithmState.category == .ok else {
            log("glucose: state \(message.algorithmState.name); not published")
            return nil
        }
        guard let raw = message.glucoseRaw else {
            log("glucose: no value (0xFFFF); not published")
            return nil
        }
        guard !message.isDisplayOnly else {
            log("glucose: display-only (calibration) value; not published (S1)")
            return nil
        }
        guard let timestamp = message.readingSensorTimestamp else {
            log("glucose: age \(message.age) exceeds sensor clock \(message.sensorClock); not published")
            return nil
        }
        guard !publishedTimestamps.contains(timestamp) else {
            log("glucose: sensor timestamp \(timestamp) already published")
            return nil
        }
        if let newest = newestPublishedTimestamp, timestamp <= newest {
            log("glucose: sensor timestamp \(timestamp) not newer than \(newest); not published")
            return nil
        }
        let reading = makeReading(raw: raw, trendRate: message.trendRate, timestamp: timestamp, clock: clock, isBackfill: false)
        guard let valid = validated(reading, session: session, now: now) else { return nil }
        return (timestamp, valid)
    }

    private func decodeBackfill(_ frame: Data, now: Date) {
        guard let clock, let session else { return }
        guard let message = G7BackfillMessage(frame) else {
            log("backfill: malformed record \(frame.hexString)")
            return
        }
        guard message.algorithmState.category == .ok, let raw = message.glucoseRaw, !message.isDisplayOnly else {
            log("backfill: record at \(message.sensorTimestamp) not valid (state \(message.algorithmState.name)); not published")
            return
        }
        let timestamp = message.sensorTimestamp
        guard !publishedTimestamps.contains(timestamp), backfillBatch[timestamp] == nil else { return }
        let reading = makeReading(raw: raw, trendRate: message.trendRate, timestamp: timestamp, clock: clock, isBackfill: true)
        if let valid = validated(reading, session: session, now: now) {
            backfillBatch[timestamp] = valid
        }
    }

    private func makeReading(raw: UInt16, trendRate: Double?, timestamp: UInt32, clock: G7SessionClock, isBackfill: Bool) -> GlucoseReading {
        GlucoseReading(
            id: GlucoseReading.sensorID(serial: serial, sensorTimestamp: timestamp),
            date: clock.date(forSensorTimestamp: timestamp),
            value: G7GlucoseRange.value(fromSensorMgdl: raw),
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
