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
///    every published one in sensor time;
/// 10. its date keeps the published readings in sensor-time order (S3 monotonic, live and backfill):
///    it falls strictly between the dates of the published readings just before and just after it in
///    sensor time. With one fixed session start this always holds; it can fail only after a
///    re-anchor (the phone clock was changed), and such readings are withheld with
///    `.failed(sensorClockMismatch)`. Across a relaunch only the newest published reading is known
///    (persisted as G7ReadingMark), so a reading is then checked against that one mark, not against
///    every reading published before the relaunch (audit m15). Residual: after a phone clock change
///    and a re-anchor in the new process, a backfill record for a never-published sensor time before
///    the mark is dated with the new anchor and can sit up to the clock change away from its stored
///    neighbours (its id still dedupes; alerts never evaluate backfill).
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
/// Session end (D28, safety review N1). The sensor's own "expired", "failed" or "stopped after
/// warm-up" state ends the session only when two status-0 `0x4E` report it and the second one's
/// sensor clock is at least `endConfirmationInterval` and at most `endConfirmationWindow` after the
/// first one's, with no status-0 report of a continuing session in between. The sensor clock, not a connection count, tells two reports
/// apart, and the first report is persisted (`G7UnconfirmedSessionEnd`), so iOS terminating the app
/// between two wakes cannot prevent the latch. A non-zero-status reply never counts (it may carry a
/// cached state). Until then the reported state is shown for that connection only and a later OK
/// reading is used as usual. Once latched, every later `0x4E` shows the end (`G7SessionEnd.state`:
/// `.expired` or `.failed` with the reason), nothing more is published, and the controller persists
/// the end.
///
/// `.expired` means a confirmed end (D41: the alert engine then suppresses missed readings). It is
/// emitted only for the latched end and for the grace end passing by time against an established
/// session start, judged by an anchored status-0 packet (sensor-clock time). An unconfirmed end
/// report — the first expired report, any expired state in a non-zero-status reply — is
/// `.error(code:description:)` (G7SensorStatus), and a time-based expiry that is not anchored (the
/// first anchor of a pairing, whose own clock supplied the start, or any non-zero-status reply, which
/// is judged by the phone clock) is `.error` too: a garbled sensor clock or a changed phone clock must
/// not look like a confirmed end.
///
/// Backfill floor (audit m1). The app tells the pipeline the latest reading it has durably stored for
/// this serial (`backfillFloor`). A backfill record for a sensor time above that floor is published
/// again even if this pipeline already published it (it was delivered but may never have been
/// stored, e.g. a failing store and then app termination), with the same id and date as the first
/// delivery (only `isBackfill` may differ); the store and Trio dedupe by id. Everything else applies
/// unchanged (gate, session, latch). The G7 has no backfill request: it decides which records it
/// sends, so only records it sends again can be re-published (docs/g7-protocol.md §5.6).
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

    /// Sensor policy (safety review N1 follow-up): a second end report confirms the first only if its
    /// sensor clock is at least 60 s later. The G7 wakes about every 300 s, so this means a later
    /// wake, never a repeat within the same few-second connection or a re-delivered packet.
    static let endConfirmationInterval: UInt32 = 60

    /// Sensor policy (safety review, last minor): a first end report older than this much sensor time
    /// is stale and is replaced by the new report instead of confirming with it. Otherwise a report
    /// restored after a failed clearing save (a running report in between was never persisted) and a
    /// relaunch could let one later report latch the end. One hour is about 12 wakes; a real end is
    /// reported at every wake, so this delays a latch by at most one wake after a long outage.
    static let endConfirmationWindow: UInt32 = 3_600

    let serial: String
    /// Reported by the sensor in `0x52`; nil until then (no reading is published without it).
    private(set) var parameters: G7SensorLifetime.Parameters?
    private(set) var isUnsupportedSensor = false
    /// Fixed per serial from the sensor clock (see type documentation); persisted by the controller.
    private(set) var sessionStart: Date?
    /// Latched end of the session (see "Session end" above); persisted by the controller. The
    /// grace-period end is a time check made by the reader of the session (and LiveReadingGate), so a
    /// garbled anchor can never end a session permanently.
    private(set) var sessionEnd: G7SessionEnd?
    /// This connection's anchor, set only when it agrees with `sessionStart`.
    private(set) var clock: G7SessionClock?

    private var pendingAnchorStart: Date?
    /// What the app has durably stored for this serial (m1); nil until the app says.
    enum BackfillFloor: Equatable {
        /// No reading of this sensor is stored: every record the sensor backfills may be re-published.
        case nothingStored
        /// The newest stored reading has this sensor timestamp; records above it may be re-published.
        case storedThrough(sensorTimestamp: UInt32)
    }

    /// Set by the controller from the app's store (m1). nil: already-published records are never
    /// re-published (the behaviour without a store).
    var backfillFloor: BackfillFloor?
    /// Published during the current connection: never re-published in the same connection (the app
    /// has had no chance to store them yet, so the floor cannot be above them).
    private var publishedThisConnection: Set<UInt32> = []

    /// A reported end not yet confirmed by a second report; persisted by the controller.
    private(set) var unconfirmedEnd: G7UnconfirmedSessionEnd?
    /// Every reading published for this serial in this process (seeded with the persisted newest
    /// one), ascending by sensor timestamp: dedupe and the date-order rule.
    private var published: [G7ReadingMark] = []
    private var pendingBackfillFrames: [Data] = []
    private var backfillBatch: [UInt32: GlucoseReading] = [:]
    /// Backfill frames received since the last flush, for the diagnostic summary.
    private var backfillFramesReceived = 0
    private let log: (String) -> Void

    init(
        serial: String,
        reportedParameters: G7SensorLifetime.Parameters?,
        sessionStart: Date? = nil,
        sessionEnd: G7SessionEnd? = nil,
        unconfirmedEnd: G7UnconfirmedSessionEnd? = nil,
        newestReading: G7ReadingMark? = nil,
        log: @escaping (String) -> Void
    ) {
        self.serial = serial
        self.parameters = reportedParameters
        self.sessionStart = sessionStart
        self.sessionEnd = sessionEnd
        self.unconfirmedEnd = sessionEnd == nil ? unconfirmedEnd : nil
        self.published = newestReading.map { [$0] } ?? []
        self.log = log
    }

    var sessionEnded: Bool { sessionEnd != nil }

    /// Backfill may be requested on this connection: its `0x4E` set an agreeing clock, so every
    /// record the sensor sends can be dated. Without it the records would be held and discarded at
    /// disconnect, and the G7 does not send a record again once it has sent it.
    var canDateBackfill: Bool { clock != nil && !isUnsupportedSensor && !sessionEnded }

    /// The newest published reading (persisted by the controller).
    var newestReading: G7ReadingMark? { published.last }

    /// The session readings are checked against; nil when unknown, ended or unsupported (D28).
    var session: SensorSession? {
        guard !isUnsupportedSensor, !sessionEnded, let sessionStart, let parameters else { return nil }
        return G7SensorLifetime.session(serial: serial, start: sessionStart, parameters: parameters)
    }

    /// A new physical connection: the previous anchor and any raw frames belong to the old one.
    func beginConnection() {
        publishedThisConnection.removeAll()
        clock = nil
        pendingBackfillFrames.removeAll()
        backfillBatch.removeAll()
        backfillFramesReceived = 0
    }

    /// The connection turned out not to be ours (a `05` rejection after authenticating, safety review
    /// N2): drop everything from it that was not published yet.
    func discardConnection() {
        let dropped = pendingBackfillFrames.count + backfillBatch.count
        if dropped > 0 { log("backfill: \(dropped) record(s) of a rejected connection discarded") }
        pendingBackfillFrames.removeAll()
        backfillBatch.removeAll()
        backfillFramesReceived = 0
        clock = nil
    }

    /// Handles one `0x4E` received at `receivedAt` on an authenticated connection.
    func handleGlucose(_ message: some G7GlucoseReport, receivedAt: Date) -> Output {
        var output = Output()
        if isUnsupportedSensor {
            output.state = .failed(G7FailureReason.unsupportedSensor)
            return output
        }
        if let sessionEnd {
            // Latched: an OK packet after the end is never shown as active and never published.
            log("glucose: the session has ended (\(sessionEnd.rawValue)); nothing used")
            output.state = sessionEnd.state
            return output
        }
        guard let parameters else {
            log("glucose: the sensor has not reported its session length; nothing used")
            output.state = .failed(G7FailureReason.sessionLengthUnknown)
            return output
        }
        let anchor = G7SessionClock(sensorClockAtReceipt: message.sensorClock, receivedAt: receivedAt)

        // A non-zero response status is a status reply that may carry an old cached value: surface
        // the state for this connection, keep nothing else from it, never let it move the clock, and
        // never let it end the session (CGMG7Transmitter.swift:1031-1053; safety review N1).
        guard message.responseStatus == 0 else {
            // Its time is not anchored: `receivedAt` is the phone clock, which may have been changed
            // (review n1), and the reply's own clock may be cached. Never a time-based `.expired`.
            let mapped = sensorState(message.algorithmState, start: sessionStart ?? anchor.sessionStart, parameters: parameters, now: receivedAt)
            output.state = confirmedExpiryOnly(mapped, message.algorithmState, anchored: false)
            log("glucose: response status 0x\(String(message.responseStatus, radix: 16)) state \(message.algorithmState.name); not published")
            return output
        }
        let startEstablished = sessionStart != nil
        guard acceptAnchor(anchor.sessionStart), let start = sessionStart else {
            output.state = .failed(G7FailureReason.sensorClockMismatch)
            return output
        }
        clock = anchor
        let mapped = sensorState(message.algorithmState, start: start, parameters: parameters, now: receivedAt)
        // Anchored: this packet's sensor clock agrees with a start established before it, so
        // `receivedAt` is sensor-clock time and a time-based `.expired` is confirmed.
        let state = confirmedExpiryOnly(mapped, message.algorithmState, anchored: startEstablished)
        output.state = state
        if let end = G7SensorStatus.sessionEnd(for: state, algorithmState: message.algorithmState) {
            noteReportedEnd(end, sensorClock: message.sensorClock)
            if let sessionEnd {
                output.state = sessionEnd.state
                return output
            }
        } else if let unconfirmed = unconfirmedEnd {
            log("sensor reported \(message.algorithmState.name) after an unconfirmed end (\(unconfirmed.end.rawValue)); the session continues")
            unconfirmedEnd = nil
        }
        guard let session else { return output }

        switch liveReading(from: message, start: start, session: session, now: receivedAt) {
        case .published(let timestamp, let reading):
            record(G7ReadingMark(sensorTimestamp: timestamp, date: reading.date))
            output.readings.append(reading)
        case .withheld(let surfacedReason):
            if let surfacedReason { output.state = .failed(surfacedReason) }
        }
        let frames = pendingBackfillFrames
        pendingBackfillFrames.removeAll()
        for frame in frames { decodeBackfill(frame, now: receivedAt) }
        return output
    }

    /// A 9-byte record from the Backfill characteristic.
    func handleBackfillFrame(_ frame: Data, now: Date) {
        guard !isUnsupportedSensor, !sessionEnded else { return }
        backfillFramesReceived += 1
        if clock == nil {
            pendingBackfillFrames.append(frame)
        } else {
            decodeBackfill(frame, now: now)
        }
    }

    /// `0x59` backfill finished: publish the batch in ascending order. A record whose date would break
    /// the sensor-time order of what is already published (only possible after a re-anchor) is
    /// withheld and `.failed(sensorClockMismatch)` reported, as for a live reading.
    func flushBackfill() -> Output {
        var output = Output()
        var outOfOrder = 0
        var republished = 0
        for timestamp in backfillBatch.keys.sorted() {
            guard let reading = backfillBatch[timestamp] else { continue }
            if let earlier = publishedMark(at: timestamp) {
                // m1: published before, possibly never stored. Only above the floor, and only with the
                // date it was first published with (an anchor change since would re-date it).
                guard mayRepublish(timestamp), earlier.date == reading.date else { continue }
                publishedThisConnection.insert(timestamp)
                republished += 1
                output.readings.append(reading)
                continue
            }
            guard fitsPublishedOrder(timestamp: timestamp, date: reading.date) else {
                outOfOrder += 1
                continue
            }
            record(G7ReadingMark(sensorTimestamp: timestamp, date: reading.date))
            output.readings.append(reading)
        }
        backfillBatch.removeAll()
        if backfillFramesReceived > 0 {
            log("backfill: \(backfillFramesReceived) record(s) received, \(output.readings.count) published")
            backfillFramesReceived = 0
        }
        if republished > 0 {
            log("backfill: \(republished) record(s) above the stored floor published again (m1)")
        }
        if outOfOrder > 0 {
            log("backfill: \(outOfOrder) record(s) would be dated out of sensor-time order (phone clock changed); not published")
            output.state = .failed(G7FailureReason.sensorClockMismatch)
        }
        return output
    }

    /// Disconnect: publish what could be dated, discard the rest (CGMG7Transmitter.swift:656-667).
    func endConnection() -> Output {
        if !pendingBackfillFrames.isEmpty {
            log("backfill: discarded \(pendingBackfillFrames.count) record(s) without an agreeing sensor clock")
            pendingBackfillFrames.removeAll()
        }
        let output = flushBackfill()
        clock = nil
        return output
    }

    /// `0x52`: adopt reported timing, or refuse the sensor (non-goal products).
    func handleExtendedVersion(_ message: G7ExtendedVersionMessage) -> Output {
        guard let reported = G7SensorLifetime.parameters(reportedSessionLength: message.sessionLength, reportedWarmUp: message.warmUpDuration) else {
            isUnsupportedSensor = true
            backfillBatch.removeAll()
            pendingBackfillFrames.removeAll()
            log("extended version: unsupported session length \(message.sessionLength) s / warm-up \(message.warmUpDuration) s")
            return Output(readings: [], state: .failed(G7FailureReason.unsupportedSensor))
        }
        parameters = reported
        return Output()
    }

    // MARK: - Private

    private enum LiveOutcome {
        case published(timestamp: UInt32, reading: GlucoseReading)
        /// `surfacedReason` is reported as `.failed(_:)` (S5); nil for normal non-publication.
        case withheld(surfacedReason: SensorFailure?)
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

    /// Maps the reported state; never ends the session by itself (see `noteReportedEnd`).
    private func sensorState(_ algorithmState: G7AlgorithmState, start: Date, parameters: G7SensorLifetime.Parameters, now: Date) -> SensorState {
        let session = G7SensorLifetime.session(serial: serial, start: start, parameters: parameters)
        return G7SensorStatus.state(for: algorithmState, session: session, now: now)
    }

    /// D41: a time-based `.expired` counts only from an anchored status-0 packet, i.e. in sensor-clock
    /// time against a session start established before it. Otherwise — this packet's own clock
    /// supplied the start, or it is a non-zero-status reply judged by the phone clock (review n1: a
    /// phone clock moved forward must not expire the session) — it is an unconfirmed `.error` (the raw
    /// state byte, e.g. 0x06 for OK, and why).
    private func confirmedExpiryOnly(_ state: SensorState, _ algorithmState: G7AlgorithmState, anchored: Bool) -> SensorState {
        guard state == .expired, !anchored else { return state }
        log("glucose: past the session end without an anchored sensor clock; not a confirmed end")
        return .error(code: Int(algorithmState.rawValue), description: "\(algorithmState.name), past the session end (not confirmed)")
    }

    /// Safety review N1: one packet never ends a session. A status-0 end report is latched only when a
    /// second one arrives at least `endConfirmationInterval` of sensor time after the first (any
    /// status-0 report of a continuing session in between clears the first one, in `handleGlucose`).
    /// A second report sooner than that (same connection, re-delivered packet) or with an earlier
    /// sensor clock neither confirms nor replaces the first; a first report more than
    /// `endConfirmationWindow` older is discarded and the new report becomes the first.
    private func noteReportedEnd(_ end: G7SessionEnd, sensorClock: UInt32) {
        if let stale = unconfirmedEnd, sensorClock >= stale.sensorClock,
           sensorClock - stale.sensorClock > Self.endConfirmationWindow {
            log("first end report at sensor time \(stale.sensorClock) is older than \(Self.endConfirmationWindow) s; discarded")
            unconfirmedEnd = nil
        }
        guard let first = unconfirmedEnd else {
            unconfirmedEnd = G7UnconfirmedSessionEnd(end: end, sensorClock: sensorClock)
            log("sensor reported the session over (\(end.rawValue)) at sensor time \(sensorClock); it ends if a later wake reports it again")
            return
        }
        guard sensorClock >= first.sensorClock, sensorClock - first.sensorClock >= Self.endConfirmationInterval else {
            log("sensor reported the session over again at sensor time \(sensorClock), not \(Self.endConfirmationInterval) s after \(first.sensorClock); not yet confirmed")
            return
        }
        sessionEnd = end
        unconfirmedEnd = nil
        backfillBatch.removeAll()
        pendingBackfillFrames.removeAll()
        log("session ended (\(end.rawValue)): reported at sensor times \(first.sensorClock) and \(sensorClock)")
    }

    private func liveReading(from message: some G7GlucoseReport, start: Date, session: SensorSession, now: Date) -> LiveOutcome {
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
            log("glucose: age \(message.readingAge) exceeds sensor clock \(message.sensorClock); not published")
            return .withheld(surfacedReason: nil)
        }
        guard !isPublished(timestamp) else {
            log("glucose: sensor timestamp \(timestamp) already published")
            return .withheld(surfacedReason: nil)
        }
        if let newest = published.last, timestamp <= newest.sensorTimestamp {
            log("glucose: sensor timestamp \(timestamp) not newer than \(newest.sensorTimestamp); not published")
            return .withheld(surfacedReason: nil)
        }
        let reading = makeReading(value: value, trendRate: message.trendRate, timestamp: timestamp, start: start, isBackfill: false)
        guard fitsPublishedOrder(timestamp: timestamp, date: reading.date) else {
            log("glucose: date \(reading.date) not after the last published \(published.last.map { "\($0.date)" } ?? "-"); not published")
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
        guard backfillBatch[timestamp] == nil else { return }
        if isPublished(timestamp), !mayRepublish(timestamp) { return }
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

    /// First index in `published` whose sensor timestamp is not below `timestamp`.
    private func insertionIndex(for timestamp: UInt32) -> Int {
        var low = 0, high = published.count
        while low < high {
            let middle = (low + high) / 2
            if published[middle].sensorTimestamp < timestamp { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func isPublished(_ timestamp: UInt32) -> Bool {
        publishedMark(at: timestamp) != nil
    }

    private func publishedMark(at timestamp: UInt32) -> G7ReadingMark? {
        let index = insertionIndex(for: timestamp)
        guard index < published.count, published[index].sensorTimestamp == timestamp else { return nil }
        return published[index]
    }

    /// m1: an already-published record may be published again when the app has not stored it, but
    /// not in the connection that first published it.
    private func mayRepublish(_ timestamp: UInt32) -> Bool {
        guard !publishedThisConnection.contains(timestamp) else { return false }
        switch backfillFloor {
        case nil: return false
        case .nothingStored: return true
        case .storedThrough(let stored): return timestamp > stored
        }
    }

    /// S3 monotonic: `date` lies strictly between the dates of the published neighbours in sensor time.
    private func fitsPublishedOrder(timestamp: UInt32, date: Date) -> Bool {
        let index = insertionIndex(for: timestamp)
        if index > 0, date <= published[index - 1].date { return false }
        if index < published.count, date >= published[index].date { return false }
        return true
    }

    private func record(_ mark: G7ReadingMark) {
        publishedThisConnection.insert(mark.sensorTimestamp)
        let index = insertionIndex(for: mark.sensorTimestamp)
        guard index == published.count || published[index].sensorTimestamp != mark.sensorTimestamp else { return }
        published.insert(mark, at: index)
    }
}
