// Hands valid live sensor readings to Trio through Trio's App Group (HANDOFF §8, S2 S3 S4 S5 S6).
//
// Contract written (docs/trio-bridge.md): UserDefaults suite = Trio's App Group ID, key `latestReadings`,
// value = JSON array of `TrioSharedReading`, newest first, at most 60 elements. Trio polls that key and
// stores every element whose timestamp it does not already have (Trio `FetchGlucoseManager.swift:243-287`,
// `GlucoseStorage.swift:77-126`), so the array is a sliding window: each write carries the newest readings
// again, and a reading Trio missed while suspended is still there on its next poll.

import Foundation
import GlucoseCore

/// Writes valid live sensor readings into Trio's App Group and reports its own health.
public actor TrioBridge {
    /// LOW/HIGH handling for this bridge instance (S4). Default: neither is written.
    public nonisolated let outOfRangePolicy: OutOfRangePolicy

    private let store: any TrioSharedStore
    private let diagnostics: any DiagnosticLog
    private let clock: @Sendable () -> Date

    /// Readings accepted into Trio's payload: newest first, unique by `id`, at most `maxReadings`.
    /// Memory only. After a relaunch the app re-seeds it by publishing its recent stored sensor readings;
    /// each one passes the gate again.
    private var window: [GlucoseReading] = []
    /// True from the moment the payload changes until a write of it succeeds.
    private var writePending = false
    /// Current health. Every change is delivered through `statusUpdates()`.
    public private(set) var status = TrioBridgeStatus() {
        didSet {
            guard status != oldValue else { return }
            for continuation in observers.values {
                continuation.yield(status)
            }
        }
    }
    private var observers: [UUID: AsyncStream<TrioBridgeStatus>.Continuation] = [:]

    /// - Parameters:
    ///   - store: Trio's App Group suite (`AppGroupUserDefaultsStore(appGroupID:)` in the app).
    ///   - outOfRangePolicy: keep the default until Michael decides (docs/trio-bridge.md, "LOW and HIGH").
    ///   - diagnostics: receives one event per write, failure and refusal (category `.bridge`).
    ///   - clock: the current time; injected so tests never sleep.
    public init(
        store: any TrioSharedStore,
        outOfRangePolicy: OutOfRangePolicy = .doNotWrite,
        diagnostics: any DiagnosticLog = NullDiagnosticLog(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.outOfRangePolicy = outOfRangePolicy
        self.diagnostics = diagnostics
        self.clock = clock
    }

    // MARK: - Publishing

    /// Adds `readings` to Trio's payload and writes it.
    ///
    /// Every reading, new or already in the payload, passes `LiveReadingGate.validate(_:session:now:)`
    /// immediately before each write (S2, S6), and LOW/HIGH follow `outOfRangePolicy` (S4). A refused reading
    /// is never written. Readings keep their own timestamps; a reading whose `id` is already in the payload
    /// is ignored so the copy Trio already has is never replaced (S3). Nothing is written when no reading was
    /// added and no earlier write is pending, so a refused-only call leaves Trio's payload untouched.
    ///
    /// - Parameters:
    ///   - readings: new or backfilled readings, in any order.
    ///   - session: the session the CGM source is authenticated to now (`CGMSource.currentSession`).
    @discardableResult
    public func publish(_ readings: [GlucoseReading], session: SensorSession?) -> TrioPublishResult {
        let now = clock()
        var result = TrioPublishResult()

        // 1. Screen the given readings: dedupe by id (S3), then the gate and the value rules.
        var knownIDs = Set(window.map(\.id))
        var accepted: [GlucoseReading] = []
        for reading in readings {
            guard !knownIDs.contains(reading.id) else {
                result.duplicateReadingIDs.append(reading.id)
                continue
            }
            switch decide(reading, session: session, now: now) {
            case .write:
                accepted.append(reading)
                knownIDs.insert(reading.id)
            case .refuse(let reason):
                result.refusals.append(TrioBridgeRefusal(readingID: reading.id, readingDate: reading.date, reason: reason, refusedAt: now))
            }
        }

        // 2. Nothing new and nothing pending: Trio already has the current payload.
        guard !accepted.isEmpty || writePending else {
            record(result, now: now)
            return result
        }

        // 3. The new window: newest first, capped at what Trio reads (`AppGroupSource.swift:61`).
        let acceptedIDs = Set(accepted.map(\.id))
        let merged = (window + accepted).sorted(by: Self.newestFirst)
        window = Array(merged.prefix(TrioAppGroupContract.maxReadings))
        for reading in merged.dropFirst(TrioAppGroupContract.maxReadings) where acceptedIDs.contains(reading.id) {
            result.refusals.append(TrioBridgeRefusal(readingID: reading.id, readingDate: reading.date, reason: .olderThanPayloadWindow, refusedAt: now))
        }
        writePending = true

        // 4. Immediately before writing, every reading in the window passes the gate again against the
        //    current session and clock (S2, S6). Readings of an earlier session fail here and are left out.
        var elements: [TrioSharedReading] = []
        var included: [GlucoseReading] = []
        for reading in window {
            if case .write(let mgdl) = decide(reading, session: session, now: now) {
                elements.append(TrioSharedReading(mgdl: mgdl, date: reading.date, trendRate: reading.trendRate))
                included.append(reading)
            }
        }
        if included.count < window.count {
            log("left \(window.count - included.count) earlier reading(s) out of the payload: refused for the current session", at: now)
        }
        guard !elements.isEmpty else {
            // Only reachable when retrying a pending write without a valid session: keep the last payload.
            record(result, now: now)
            return result
        }

        // 5. Write and verify.
        do {
            try write(elements)
            writePending = false
            result.didWrite = true
            result.addedReadingIDs = included.map(\.id).filter { acceptedIDs.contains($0) }
            var next = status
            next.lastSuccessfulWriteAt = now
            next.newestReadingWrittenAt = included.first?.date
            next.readingsInLastWrite = elements.count
            next.consecutiveFailures = 0
            status = next
            log("wrote \(elements.count) reading(s) to Trio, newest \(Self.iso(included[0].date)), \(result.addedReadingIDs.count) new", at: now)
        } catch {
            result.error = error
            var next = status
            next.consecutiveFailures += 1
            next.lastError = error
            next.lastErrorAt = now
            status = next
            log("write FAILED (\(next.consecutiveFailures) in a row): \(error)", at: now)
        }
        record(result, now: now)
        return result
    }

    /// Removes this app's readings from Trio's App Group and forgets the payload (e.g. when the Trio bridge
    /// is turned off in Settings). Trio then has no App Group readings at all (`AppGroupSource.swift:48-50`).
    public func clear() throws(TrioBridgeError) {
        try store.checkAccess()
        store.removeValue(forKey: TrioAppGroupContract.readingsKey)
        window = []
        writePending = false
        log("cleared latestReadings", at: clock())
    }

    // MARK: - Heartbeat (optional)

    /// Writes (or with `nil` removes) the peripheral Trio should use as its background heartbeat.
    ///
    /// Order matters. Trio remembers the address as soon as it sees a new one and builds its connection only
    /// if both UUID keys are already present, without retrying later (`HeartBeatManager.swift:33-42, :47-70`).
    /// So the UUIDs are written before the address, and on removal the address goes first.
    public func setHeartbeatPeripheral(_ peripheral: TrioHeartbeatPeripheral?) throws(TrioBridgeError) {
        try store.checkAccess()
        if let peripheral {
            store.setString(peripheral.serviceUUID, forKey: TrioAppGroupContract.heartbeatServiceUUIDKey)
            store.setString(peripheral.receiveCharacteristicUUID, forKey: TrioAppGroupContract.heartbeatReceiveUUIDKey)
            store.setString(peripheral.peripheralIdentifier.uuidString, forKey: TrioAppGroupContract.heartbeatDeviceAddressKey)
            log("heartbeat peripheral set to \(peripheral.peripheralIdentifier.uuidString)", at: clock())
        } else {
            store.removeValue(forKey: TrioAppGroupContract.heartbeatDeviceAddressKey)
            store.removeValue(forKey: TrioAppGroupContract.heartbeatServiceUUIDKey)
            store.removeValue(forKey: TrioAppGroupContract.heartbeatReceiveUUIDKey)
            log("heartbeat peripheral removed", at: clock())
        }
    }

    // MARK: - Status

    /// A new stream per call. Yields the current status first, then every change. Only the newest
    /// unread status is buffered.
    public func statusUpdates() -> AsyncStream<TrioBridgeStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: TrioBridgeStatus.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        continuation.yield(status)
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    /// Number of live status streams. For tests.
    var observerCount: Int { observers.count }

    // MARK: - Private

    private enum Decision {
        case write(mgdl: Int)
        case refuse(TrioBridgeRefusal.Reason)
    }

    /// The single place that decides whether, and as what number, a reading reaches Trio.
    private func decide(_ reading: GlucoseReading, session: SensorSession?, now: Date) -> Decision {
        // S2 + S6: the shared live gate (never the DEBUG replay-accepting variant). Besides source,
        // session and time it refuses a number outside 40...400 (`.implausibleValue`) and a non-finite
        // trend rate, so a bare 38 (oref's CGM error code) can never be written.
        do throws(LiveReadingGate.Rejection) {
            try LiveReadingGate.validate(reading, session: session, now: now)
        } catch {
            return .refuse(.gate(error))
        }
        // S4: LOW/HIGH stay flags unless Michael chooses the sentinel codes; never 40/400.
        switch reading.value {
        case .mgdl(let mgdl):
            return .write(mgdl: mgdl)
        case .belowRange:
            switch outOfRangePolicy.low {
            case .doNotWrite: return .refuse(.outOfRangeWithheld(.belowRange))
            case .writeSentinel: return .write(mgdl: TrioAppGroupContract.lowSentinelMgdl)
            }
        case .aboveRange:
            switch outOfRangePolicy.high {
            case .doNotWrite: return .refuse(.outOfRangeWithheld(.aboveRange))
            case .writeSentinel: return .write(mgdl: TrioAppGroupContract.highSentinelMgdl)
            }
        }
    }

    private func write(_ elements: [TrioSharedReading]) throws(TrioBridgeError) {
        try store.checkAccess()
        let data: Data
        do {
            data = try TrioPayloadEncoder.encode(elements)
        } catch {
            throw .encodingFailed(description: String(describing: error))
        }
        store.setData(data, forKey: TrioAppGroupContract.readingsKey)
        guard store.data(forKey: TrioAppGroupContract.readingsKey) == data else {
            throw .writeNotPersisted
        }
    }

    /// Logs refusals and duplicates and updates the refusal fields of the status.
    private func record(_ result: TrioPublishResult, now: Date) {
        var next = status
        for refusal in result.refusals {
            log("refused \(refusal.readingID) (\(Self.iso(refusal.readingDate))): \(refusal.reason)", at: now)
            next.lastRefusal = refusal
            if case .outOfRangeWithheld = refusal.reason {
                next.lastOutOfRangeWithheldAt = now
            }
        }
        if !result.duplicateReadingIDs.isEmpty {
            log("ignored \(result.duplicateReadingIDs.count) reading(s) already in the payload", at: now)
        }
        status = next
    }

    private func log(_ message: String, at date: Date) {
        diagnostics.record(DiagnosticEvent(date: date, category: .bridge, message: "Trio bridge: " + message))
    }

    /// Newest first; ties (impossible for one sensor, whose ids are serial + sensor time) broken by id so
    /// the order is always the same.
    private static func newestFirst(_ lhs: GlucoseReading, _ rhs: GlucoseReading) -> Bool {
        lhs.date != rhs.date ? lhs.date > rhs.date : lhs.id < rhs.id
    }

    private static func iso(_ date: Date) -> String {
        date.ISO8601Format()
    }
}
