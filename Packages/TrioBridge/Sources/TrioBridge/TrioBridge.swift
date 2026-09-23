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
    /// LOW/HIGH handling for this bridge instance (S4). The package default withholds both; the app sets
    /// the policy Michael chose (PROGRESS.md D21: LOW → 39, HIGH → 401) explicitly in its wiring.
    public nonisolated let outOfRangePolicy: OutOfRangePolicy

    private let store: any TrioSharedStore
    private let diagnostics: any DiagnosticLog
    private let clock: @Sendable () -> Date

    /// Readings accepted into Trio's payload: newest first, unique by `id`, at most `maxReadings`.
    /// Memory only. After a relaunch the app re-seeds it by publishing its recent stored sensor readings;
    /// each one passes the gate again. Readings that no longer pass the gate stay here (so a transient
    /// `nil` session loses nothing) but are never written.
    private var window: [GlucoseReading] = []
    /// IDs of the readings in the App Group as this bridge last set it, newest first; empty = key removed.
    private var payloadIDs: [String] = []
    /// False until this process has set the key once, and after any failed attempt: the next `publish`
    /// then writes or removes the key even if `payloadIDs` looks current.
    private var payloadInSync = false

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
    ///   - outOfRangePolicy: defaults to withholding LOW and HIGH; the app passes D21's policy explicitly.
    ///   - diagnostics: receives one summary event per `publish` call, plus clear/heartbeat events
    ///     (category `.bridge`).
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

    /// Adds `readings` to the window and makes Trio's App Group show exactly the window readings that pass
    /// the gate for `session` now.
    ///
    /// Every reading, new or already in the window, passes `LiveReadingGate.validate(_:session:now:)`
    /// immediately before each write (S2, S6), and LOW/HIGH follow `outOfRangePolicy` (S4). A refused reading
    /// is never written. Readings keep their own timestamps; a reading whose `id` is already in the window is
    /// ignored so the copy Trio already has is never replaced (S3).
    ///
    /// The App Group is changed only when that set differs from what this bridge last put there (or the last
    /// attempt failed, or this process has not set it yet). So a new sensor session or a `nil` session
    /// (sensor expired or failed) rewrites the payload with only the readings that still pass, or removes
    /// the key when none do; no previous-session payload lingers. Call with an empty array to retry or
    /// re-check without new readings.
    ///
    /// - Parameters:
    ///   - readings: new or backfilled readings, in any order.
    ///   - session: the session the CGM source is authenticated to now (`CGMSource.currentSession`).
    @discardableResult
    public func publish(_ readings: [GlucoseReading], session: SensorSession?) -> TrioPublishResult {
        let now = clock()
        var result = TrioPublishResult()
        var next = status
        noteLiveReadingsOffered(readings, now: now, in: &next)

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

        // 2. The window: newest first, capped at what Trio reads (`AppGroupSource.swift:61`).
        let acceptedIDs = Set(accepted.map(\.id))
        if !accepted.isEmpty {
            let merged = (window + accepted).sorted(by: Self.newestFirst)
            window = Array(merged.prefix(TrioAppGroupContract.maxReadings))
            for reading in merged.dropFirst(TrioAppGroupContract.maxReadings) where acceptedIDs.contains(reading.id) {
                result.refusals.append(TrioBridgeRefusal(readingID: reading.id, readingDate: reading.date, reason: .olderThanPayloadWindow, refusedAt: now))
            }
        }

        // 3. What Trio should see now: every window reading that passes the gate again, against the current
        //    session and clock, immediately before any write (S2, S6).
        var elements: [TrioSharedReading] = []
        var included: [GlucoseReading] = []
        for reading in window {
            if case .write(let mgdl) = decide(reading, session: session, now: now) {
                elements.append(TrioSharedReading(mgdl: mgdl, date: reading.date, trendRate: reading.trendRate))
                included.append(reading)
            }
        }
        let includedIDs = included.map(\.id)

        // 4. Bring the App Group in line: write, remove, or leave it.
        if !payloadInSync || includedIDs != payloadIDs {
            do throws(TrioBridgeError) {
                if elements.isEmpty {
                    try removePayload()
                    result.didRemovePayload = true
                    log("removed latestReadings: no reading passes the gate for the current session", at: now)
                } else {
                    try write(elements)
                    result.didWrite = true
                    result.addedReadingIDs = includedIDs.filter { acceptedIDs.contains($0) }
                    if let newest = included.first?.date {
                        next.newestReadingWrittenAt = max(next.newestReadingWrittenAt ?? newest, newest)
                    }
                    log("wrote \(elements.count) reading(s) to Trio, newest \(Self.iso(included[0].date)), \(result.addedReadingIDs.count) new", at: now)
                }
                if included.count < window.count {
                    log("left \(window.count - included.count) earlier reading(s) out: refused for the current session", at: now)
                }
                payloadIDs = includedIDs
                payloadInSync = true
                next.lastSuccessfulWriteAt = now
                next.readingsInLastWrite = elements.count
                next.consecutiveFailures = 0
            } catch {
                payloadInSync = false
                result.error = error
                next.consecutiveFailures += 1
                next.lastError = error
                next.lastErrorAt = now
                log("write FAILED (\(next.consecutiveFailures) in a row): \(error)", at: now)
            }
        }

        record(refusals: result.refusals, duplicates: result.duplicateReadingIDs.count, now: now, in: &next)
        status = next
        return result
    }

    /// Removes this app's readings from Trio's App Group, forgets the window, and resets the starvation
    /// signal (e.g. when the Trio bridge is turned off in Settings). Trio then has no App Group readings
    /// (`AppGroupSource.swift:48-50`). A failure is reported in `status` and thrown.
    public func clear() throws(TrioBridgeError) {
        let now = clock()
        var next = status
        do throws(TrioBridgeError) {
            try removePayload()
        } catch {
            payloadInSync = false
            next.consecutiveFailures += 1
            next.lastError = error
            next.lastErrorAt = now
            status = next
            log("clear FAILED: \(error)", at: now)
            throw error
        }
        window = []
        payloadIDs = []
        payloadInSync = true
        next.lastSuccessfulWriteAt = now
        next.readingsInLastWrite = 0
        next.consecutiveFailures = 0
        next.newestReadingWrittenAt = nil
        next.newestLiveReadingOfferedAt = nil
        next.firstLiveReadingOfferedAt = nil
        status = next
        log("cleared latestReadings", at: now)
    }

    // MARK: - Heartbeat (optional)

    /// Writes the peripheral Trio should use as its background heartbeat, or with `nil` removes the three
    /// heartbeat keys — including stale ones a previous xDrip4iOS install left behind, which would otherwise
    /// make Trio keep connecting to that old transmitter.
    ///
    /// Order matters. Trio remembers the address as soon as it sees a new one and builds its connection only
    /// if both UUID keys are already present, without retrying later (`HeartBeatManager.swift:33-42, :47-70`).
    /// So the UUIDs are written before the address, and on removal the address goes first; Trio then drops
    /// its heartbeat connection on its next poll (`HeartBeatManager.swift:33-42`, `BluetoothTransmitter.swift:71-76`).
    /// Each key is read back afterwards (a same-process check; `checkAccess()` is the real guard).
    public func setHeartbeatPeripheral(_ peripheral: TrioHeartbeatPeripheral?) throws(TrioBridgeError) {
        try store.checkAccess()
        let serviceKey = TrioAppGroupContract.heartbeatServiceUUIDKey
        let receiveKey = TrioAppGroupContract.heartbeatReceiveUUIDKey
        let addressKey = TrioAppGroupContract.heartbeatDeviceAddressKey
        if let peripheral {
            let address = peripheral.peripheralIdentifier.uuidString
            store.setString(peripheral.serviceUUID, forKey: serviceKey)
            store.setString(peripheral.receiveCharacteristicUUID, forKey: receiveKey)
            store.setString(address, forKey: addressKey)
            guard store.string(forKey: serviceKey) == peripheral.serviceUUID,
                  store.string(forKey: receiveKey) == peripheral.receiveCharacteristicUUID,
                  store.string(forKey: addressKey) == address
            else { throw .readBackMismatch }
            log("heartbeat peripheral set to \(address)", at: clock())
        } else {
            store.removeValue(forKey: addressKey)
            store.removeValue(forKey: serviceKey)
            store.removeValue(forKey: receiveKey)
            guard [addressKey, serviceKey, receiveKey].allSatisfy({ store.string(forKey: $0) == nil }) else {
                throw .readBackMismatch
            }
            log("heartbeat keys removed", at: clock())
        }
    }

    /// The heartbeat address currently in Trio's App Group, whoever wrote it (e.g. a stale xDrip4iOS entry),
    /// or nil. For the Settings screen and the setup check in docs/trio-bridge.md.
    public func heartbeatAddressInAppGroup() -> String? {
        store.string(forKey: TrioAppGroupContract.heartbeatDeviceAddressKey)
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
        // S4: LOW/HIGH stay flags unless the policy asks for the 39/401 codes; never 40/400.
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

    /// Checks access, writes, and reads the key back. The read-back only sees this process's view of the
    /// suite, so it catches a store that drops the value but cannot prove Trio's process sees it; the real
    /// guard is `checkAccess()` (group ID format and entitlement).
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
            throw .readBackMismatch
        }
    }

    /// Checks access, removes the key, and reads it back (same caveat as `write`).
    private func removePayload() throws(TrioBridgeError) {
        try store.checkAccess()
        store.removeValue(forKey: TrioAppGroupContract.readingsKey)
        guard store.data(forKey: TrioAppGroupContract.readingsKey) == nil else {
            throw .readBackMismatch
        }
    }

    /// Feeds the starvation signal (`TrioBridgeStatus.trioLag`): the newest live (`.sensor`) reading offered,
    /// capped at `now` so a reading with a bad clock cannot push it into the future.
    private func noteLiveReadingsOffered(_ readings: [GlucoseReading], now: Date, in next: inout TrioBridgeStatus) {
        guard let newest = readings.filter({ $0.source.isLiveSensor }).map({ min($0.date, now) }).max() else { return }
        next.newestLiveReadingOfferedAt = max(next.newestLiveReadingOfferedAt ?? newest, newest)
        if next.newestReadingWrittenAt == nil, next.firstLiveReadingOfferedAt == nil {
            next.firstLiveReadingOfferedAt = newest
        }
    }

    /// Updates the refusal fields of the status and logs one summary line per call: count per reason with
    /// the first and last reading time.
    private func record(refusals: [TrioBridgeRefusal], duplicates: Int, now: Date, in next: inout TrioBridgeStatus) {
        for refusal in refusals {
            next.lastRefusal = refusal
            switch refusal.reason {
            case .gate: next.lastGateRefusal = refusal
            case .outOfRangeWithheld: next.lastOutOfRangeWithheldAt = now
            case .olderThanPayloadWindow: break
            }
        }
        if !refusals.isEmpty {
            log("refused \(refusals.count) reading(s): " + Self.summary(of: refusals), at: now)
        }
        if duplicates > 0 {
            log("ignored \(duplicates) reading(s) already in the payload", at: now)
        }
    }

    /// "gate(noSession) ×3 [first … last]; outOfRangeWithheld(belowRange) ×1 [t]", reasons in order of
    /// first appearance.
    private static func summary(of refusals: [TrioBridgeRefusal]) -> String {
        var order: [String] = []
        var groups: [String: [Date]] = [:]
        for refusal in refusals {
            let key = String(describing: refusal.reason)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(refusal.readingDate)
        }
        return order.map { key in
            let dates = groups[key] ?? []
            let first = dates.min().map(iso) ?? "?"
            let last = dates.max().map(iso) ?? "?"
            let span = first == last ? first : "\(first) … \(last)"
            return "\(key) ×\(dates.count) [\(span)]"
        }.joined(separator: "; ")
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
