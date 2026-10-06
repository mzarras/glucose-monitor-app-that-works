// The reading pipeline: one CGM source → the gate → the store → the live consumers
// (HANDOFF §9.3 Phase 2; docs/architecture.md "Data flow").
//
//   source.readings ─ gate (on arrival) ─┐                              ┌─ TrioBridge.publish
//                                        ├─ one ordered queue ─ insert ─┼─ AlertService .reading
//   source.state  ───────────────────────┘                              ├─ uploaders submit + flushIfDue
//                                                                       └─ widget snapshot, UI
//   store closed or failing (D42): gate-passed readings go to Trio and alerts at once and wait
//   ("unstored") for the store; once stored they go to the uploads.
//
// What this file guarantees (docs/architecture.md "Where each safety rule is enforced"):
// - Every delivered reading passes `LiveReadingGate` when it arrives, against the source's session
//   and the pipeline clock at that moment, before it is stored (D38; S2 names storage) and before
//   any consumer sees it (S2, S6). A refused reading is never stored — not in history, charts or
//   `latestLiveReading` — and is logged and counted. The verdict is kept: a reading that waits for
//   the store is not re-judged later against a session that ended meanwhile (review minor 2).
//   In a DEBUG replay run the gate is `validateAllowingReplay` (D11); the Trio bridge and the
//   uploaders keep their own sensor-only gate, so replay can never reach them (S6).
// - With a working store, only readings `insert` returns — newly stored — go further, so a
//   re-delivered reading is published once (S3). Imported history never enters (S6).
// - A store that is closed or failing (e.g. full disk) silences nothing (D42): gate-passed readings
//   go to the Trio bridge and the alert engine at once (both deduplicate) and are held for storage;
//   once stored they go to the uploads. One failing reading never holds back the others: insert
//   falls back to one reading at a time and returns what it stored.
// - Every drain attempt is a wake: the alert engine gets `.tick` and the heartbeat is written, also
//   when nothing could be stored (D42). Held readings never block state changes.
// - Events are processed in arrival order: consecutive readings in one batch, a state on its own.
//   Nothing is processed before `activate()` (bootstrap): events wait in memory, in order.
// - The Trio bridge is written first, before alerts and uploads: Trio's heartbeat reads the App
//   Group when the sensor disconnects, seconds after delivering (docs/trio-bridge.md).
// - The pipeline never creates a reading (S1). It only moves what the source delivered.

import AlertEngine
import Foundation
import GlucoseCore
import NightscoutKit
import TrioBridge

@MainActor
final class ReadingPipeline {
    /// A reading the gate passed on arrival, with the session it was checked against.
    struct GatedReading: Sendable, Equatable {
        let reading: GlucoseReading
        let session: SensorSession?
    }

    enum Event: Sendable, Equatable {
        case reading(GatedReading)
        case state(SensorState)
    }

    /// For diagnostics: "sensor" or "replay:<scenario>".
    let name: String
    let source: any CGMSource
    private(set) var store: (any GlucoseReadingRepository)?
    var outputs = PipelineOutputs()

    /// The newest sensor state received (updated on arrival, even while held, so the UI is current).
    private(set) var sensorState: SensorState?
    /// `source.currentSession`, re-read on every arrival and processed state.
    private(set) var sensorSession: SensorSession?
    /// The latest live reading, however old, and the live reading before it: from the store, or a
    /// newer gate-passed reading still waiting for the store (D42).
    private(set) var latestLiveReading: GlucoseReading?
    private(set) var previousLiveReading: GlucoseReading?

    // Counters for diagnostics and tests.
    private(set) var receivedReadingCount = 0
    private(set) var receivedStateCount = 0
    private(set) var storedReadingCount = 0
    private(set) var gateRefusalCount = 0
    private(set) var storeRefusalCount = 0
    /// Drain attempts completed (each is a wake: storage health and tick sent).
    private(set) var completedDrainCount = 0
    /// Why the last insert failed for a reason other than a refused reading (disk, SQL); nil once
    /// every held reading is stored.
    private(set) var storeProblem: String?
    /// Since when gate-passed readings have been waiting for a store that is closed or failing;
    /// nil when none wait.
    private(set) var storageFailingSince: Date?
    /// Set by the composition root while opening the production database fails (nil once open).
    var storeOpenFailingSince: Date?

    /// The storage-failure alert input (D42): failing since the first failure of the current run
    /// (opening the database, or storing a reading), the same date for as long as it lasts.
    var storageHealth: StorageHealth {
        let since = [storeOpenFailingSince, storageFailingSince].compactMap { $0 }.min()
        return since.map { .failing(since: $0) } ?? .ok
    }

    /// Readings not yet stored: waiting for activation, or (gate-passed, already delivered to
    /// Trio and alerts) waiting for the store.
    var heldReadingCount: Int {
        unstored.count + pending.reduce(0) { count, event in
            if case .reading = event { return count + 1 }
            return count
        }
    }

    /// True when nothing is queued or being processed (readings may still wait for the store).
    var isIdle: Bool { pending.isEmpty && !isProcessing }

    /// Called on the main actor after something the UI shows changed.
    var onChange: (@MainActor (ServiceChange) -> Void)?
    /// Called after every drain attempt (a wake-up): pipeline heartbeat, clock latch, storage status.
    var onBatchProcessed: (@MainActor () -> Void)?

    private let diagnostics: any DiagnosticLog
    private let now: @Sendable () -> Date
    #if DEBUG
    private var acceptsReplayReadings = false
    #endif
    /// Events in arrival order, not yet processed.
    private var pending: [Event] = []
    /// Gate-passed readings delivered to Trio and alerts, waiting for the store (oldest first).
    private var unstored: [GatedReading] = []
    private var isActive = false
    private var isProcessing = false
    private var consumers: [Task<Void, Never>] = []
    private let signals: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var worker: Task<Void, Never>?

    /// At most this many readings wait (each queue). Beyond it the oldest are dropped, loudly:
    /// 10 000 readings is five weeks at the G7's 5-minute cadence.
    static let maximumHeldEvents = 10_000

    /// - Parameters:
    ///   - now: the pipeline clock (the gate's `now`); a DEBUG replay run passes the replay clock.
    init(name: String, source: any CGMSource, diagnostics: any DiagnosticLog, now: @escaping @Sendable () -> Date) {
        self.name = name
        self.source = source
        self.diagnostics = diagnostics
        self.now = now
        (signals, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    #if DEBUG
    /// DEBUG replay run (PROGRESS D11): the pipeline's gate also accepts `.replay` readings, so the
    /// alert engine (configured with `acceptsReplayReadings`) sees them. The Trio bridge and the
    /// uploaders still refuse them with their own sensor-only gate (S6), and the Trio bridge is
    /// given no session, so a replay run can never change Trio's App Group (D28: a nil session
    /// never touches it).
    init(replayName: String, source: any CGMSource, diagnostics: any DiagnosticLog, now: @escaping @Sendable () -> Date) {
        self.name = replayName
        self.source = source
        self.diagnostics = diagnostics
        self.now = now
        self.acceptsReplayReadings = true
        (signals, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }
    #endif

    // MARK: - Lifecycle

    /// Starts consuming the source's two streams. Call once. The G7 source's streams are consumed
    /// for the whole process: dropping an `AsyncStream` iterator would end the stream (CGMSource).
    func startConsuming() {
        guard consumers.isEmpty else { return }
        let signals = self.signals
        worker = Task { [weak self] in
            for await _ in signals {
                await self?.drain()
            }
        }
        let readings = source.readings
        let states = source.state
        consumers.append(Task { [weak self] in
            for await reading in readings {
                await self?.arrived(reading)
            }
        })
        consumers.append(Task { [weak self] in
            for await state in states {
                self?.enqueue(.state(state))
            }
        })
    }

    /// Ends consumption for good (a DEBUG replay run being discarded). Never for the G7 source.
    func stopConsuming() {
        for task in consumers { task.cancel() }
        consumers = []
        worker?.cancel()
        signal.finish()
    }

    /// Starts delivering: waiting events are processed in order.
    func activate() {
        isActive = true
        signal.yield(())
    }

    /// Holds events from now on (a DEBUG replay run replaced this source for a while).
    func deactivate() {
        isActive = false
    }

    /// The store is open: waiting readings are stored.
    func attach(store: any GlucoseReadingRepository) {
        self.store = store
        signal.yield(())
        Task { await refreshLatest() }
    }

    /// A wake without new events (foreground, retry): processes what waits and ticks the alerts.
    func retryHeldEvents() {
        signal.yield(())
    }

    /// Re-reads the latest live readings after a change made elsewhere (import, purge) and tells
    /// the UI.
    func storeDidChange() async {
        await refreshLatest()
        onChange?(.readings)
    }

    // MARK: - Arrival and the gate

    /// The gate, once, on arrival (D38): refused readings are never queued, stored or delivered.
    private func arrived(_ reading: GlucoseReading) async {
        let session = await source.currentSession
        sensorSession = session
        receivedReadingCount += 1
        if let rejection = gateRejection(reading, session: session, now: now()) {
            gateRefusalCount += 1
            log(.sensor, "gate refused reading \(reading.id) at \(reading.date.ISO8601Format()); not stored, not published: \(rejection)")
            return
        }
        enqueue(.reading(GatedReading(reading: reading, session: session)))
    }

    private func enqueue(_ event: Event) {
        if case .state(let state) = event {
            receivedStateCount += 1
            sensorState = state
            onChange?(.sensor)
        }
        pending.append(event)
        if pending.count > Self.maximumHeldEvents {
            let dropped = pending.count - Self.maximumHeldEvents
            pending.removeFirst(dropped)
            log(.store, "held-event limit reached: dropped the \(dropped) oldest waiting event(s) (S5)")
        }
        if !isActive { onChange?(.storage) }
        signal.yield(())
    }

    /// The pipeline's gate: `validate` (sensor only), or in a DEBUG replay run
    /// `validateAllowingReplay` (D11). Returns the refusal, or nil when the reading passes.
    private func gateRejection(_ reading: GlucoseReading, session: SensorSession?, now: Date) -> LiveReadingGate.Rejection? {
        do throws(LiveReadingGate.Rejection) {
            #if DEBUG
            if acceptsReplayReadings {
                try LiveReadingGate.validateAllowingReplay(reading, session: session, now: now)
                return nil
            }
            #endif
            try LiveReadingGate.validate(reading, session: session, now: now)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Draining

    private enum Batch {
        case state(SensorState)
        case readings([GatedReading])
    }

    /// The next batch in arrival order: the one state at the head, or every consecutive reading.
    private func takeNextBatch() -> Batch? {
        guard let head = pending.first else { return nil }
        if case .state(let state) = head {
            pending.removeFirst()
            return .state(state)
        }
        let readings = pending.prefix { if case .reading = $0 { return true } else { return false } }
            .compactMap { event -> GatedReading? in
                if case .reading(let gated) = event { return gated }
                return nil
            }
        pending.removeFirst(readings.count)
        return .readings(readings)
    }

    private func drain() async {
        guard isActive, !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        let heldBefore = heldReadingCount
        let failingBefore = storageFailingSince
        var readingsChanged = await storeUnstoredReadings()
        while let batch = takeNextBatch() {
            switch batch {
            case .state(let state):
                await process(state: state)
            case .readings(let readings):
                let changed = await process(readings: readings)
                readingsChanged = readingsChanged || changed
            }
        }
        // Every drain attempt is a wake-up, whether or not anything could be stored (D42): the
        // alert engine gets the storage health and looks at the time (repeats due, missed
        // readings; docs/alerts.md §9).
        if let alerts = outputs.alerts {
            await alerts.send(.storage(storageHealth))
            await alerts.send(.tick)
        }
        if readingsChanged {
            await refreshLatest()
            onChange?(.readings)
        }
        await publishWidget()
        onBatchProcessed?()
        if heldReadingCount != heldBefore || storageFailingSince != failingBefore {
            onChange?(.storage)
        }
        completedDrainCount += 1
    }

    // MARK: - Readings

    /// New gate-passed readings. Returns whether the latest readings may have changed.
    private func process(readings: [GatedReading]) async -> Bool {
        guard let store, unstored.isEmpty else {
            // The store is closed, or failed for earlier readings this wake: hold these too. Only
            // readings not already waiting go to Trio and alerts (they had the others).
            let added = hold(readings, reason: store == nil ? "the reading database is not open" : storeProblem ?? "earlier readings are still waiting")
            await deliverToTrioAndAlerts(added)
            return !added.isEmpty
        }
        let result = await insert(readings, into: store)
        if !result.stored.isEmpty {
            // Consumers act on what `insert` returned: newly stored, gate-passed (S2, S3).
            await deliverToTrioAndAlerts(result.stored)
            await submitToUploads(result.stored)
        }
        if !result.unstored.isEmpty {
            let added = hold(result.unstored, reason: result.problem ?? "insert failed")
            await deliverToTrioAndAlerts(added)
        }
        return !result.stored.isEmpty || !result.unstored.isEmpty
    }

    /// Readings that wait for the store (already delivered to Trio and alerts) are stored first on
    /// every wake; once stored they go to the uploads (D42). Returns whether any was stored.
    private func storeUnstoredReadings() async -> Bool {
        guard let store, !unstored.isEmpty else { return false }
        let waiting = unstored
        unstored = []
        let result = await insert(waiting, into: store)
        unstored = result.unstored
        if !result.stored.isEmpty {
            log(.store, "stored \(result.stored.count) reading(s) that were waiting for the database")
            await submitToUploads(result.stored)
        }
        if unstored.isEmpty {
            if storageFailingSince != nil { log(.store, "every waiting reading is stored; storage recovered") }
            storageFailingSince = nil
            storeProblem = nil
        }
        return !result.stored.isEmpty
    }

    /// Adds readings to the ones waiting for the store, in arrival order, skipping any whose id is
    /// already waiting (a re-delivery while the store fails must not count twice or eat into the
    /// cap; review n2). Returns the readings newly held.
    @discardableResult
    private func hold(_ readings: [GatedReading], reason: String) -> [GatedReading] {
        var waitingIDs = Set(unstored.map(\.reading.id))
        let added = readings.filter { waitingIDs.insert($0.reading.id).inserted }
        if added.count < readings.count {
            log(.store, "\(readings.count - added.count) re-delivered reading(s) already waiting for the database (S3)")
        }
        guard !added.isEmpty else { return [] }
        unstored += added
        if unstored.count > Self.maximumHeldEvents {
            let dropped = unstored.count - Self.maximumHeldEvents
            unstored.removeFirst(dropped)
            log(.store, "waiting-reading limit reached: dropped the \(dropped) oldest unstored reading(s) (S5)")
        }
        if storageFailingSince == nil {
            storageFailingSince = now()
        }
        log(.store, "holding \(added.count) reading(s) for the database (\(reason)); Trio and alerts get them now (D42)")
        return added
    }

    private struct InsertResult {
        var stored: [GatedReading] = []
        /// Not stored for a reason other than a refusal (disk, SQL, cancellation): to retry.
        var unstored: [GatedReading] = []
        var problem: String?
    }

    /// Stores `readings`. `insert` rejects a whole batch when one reading is refused, and a failing
    /// write stores nothing (docs/storage.md); then each reading is stored on its own, so what can
    /// be stored is stored and returned (and so published), refused readings are logged, and only
    /// the rest waits (review minor 1).
    private func insert(_ readings: [GatedReading], into store: any GlucoseReadingRepository) async -> InsertResult {
        var result = InsertResult()
        do {
            result.stored = Self.match(try await store.insert(readings.map(\.reading)), in: readings)
        } catch {
            for gated in readings {
                do {
                    result.stored += Self.match(try await store.insert([gated.reading]), in: [gated])
                } catch let refusal as GlucoseReadingRepositoryError {
                    storeRefusalCount += 1
                    log(.store, "store refused reading \(gated.reading.id): \(refusal)")
                } catch {
                    result.unstored.append(gated)
                    result.problem = String(describing: error)
                }
            }
        }
        storedReadingCount += result.stored.count
        if let problem = result.problem {
            storeProblem = problem
            log(.store, "\(result.unstored.count) reading(s) could not be stored: \(problem)")
        }
        return result
    }

    /// `insert` returns the newly stored readings exactly as passed; keep their gate sessions.
    private static func match(_ stored: [GlucoseReading], in gated: [GatedReading]) -> [GatedReading] {
        let byID = Dictionary(gated.map { ($0.reading.id, $0) }, uniquingKeysWith: { first, _ in first })
        return stored.compactMap { byID[$0.id] }
    }

    /// Trio first (its heartbeat reads at the sensor's disconnect, docs/trio-bridge.md), then the
    /// alert engine (docs/alerts.md §9). Both deduplicate by reading.
    private func deliverToTrioAndAlerts(_ readings: [GatedReading]) async {
        guard !readings.isEmpty else { return }
        if let trio = outputs.trio {
            let result = await trio.publish(readings.map(\.reading), session: sessionForTrio(readings.last?.session))
            if let error = result.error {
                log(.bridge, "Trio publish failed: \(error)")
            }
        }
        if let alerts = outputs.alerts {
            for gated in readings {
                await alerts.send(.reading(gated.reading, session: gated.session))
            }
        }
    }

    /// Queues stored readings for upload, then flushes in the background (the network must not hold
    /// up the queue). Each uploader gates again against the reading's own session.
    private func submitToUploads(_ readings: [GatedReading]) async {
        let uploaders = outputs.uploaders?() ?? []
        guard !readings.isEmpty, !uploaders.isEmpty else { return }
        for uploader in uploaders {
            for gated in readings {
                do throws(UploadRefusal) {
                    try await uploader.submit(gated.reading, session: gated.session)
                } catch {
                    log(.upload, "\(uploader.destinationName) refused \(gated.reading.id): \(error)")
                }
            }
        }
        outputs.flushUploads?()
    }

    /// The session handed to the Trio bridge: the reading's, except in a DEBUG replay run, where it
    /// is nil so the bridge never writes or removes anything in Trio's App Group (D28).
    private func sessionForTrio(_ session: SensorSession?) -> SensorSession? {
        #if DEBUG
        if acceptsReplayReadings { return nil }
        #endif
        return session
    }

    // MARK: - States

    private func process(state: SensorState) async {
        await outputs.alerts?.send(.sensorState(state))
        let session = await source.currentSession
        sensorSession = session
        // Session handling (D28): the bridge removes Trio's payload only on positive evidence (a
        // new session, the session ended); a nil session leaves it alone. Also retries a failed write.
        if let trio = outputs.trio {
            await trio.publish([], session: sessionForTrio(session))
        }
        outputs.sensorStateProcessed?(state)
    }

    // MARK: - Latest readings and the widget

    /// The newest live reading and the one before it, among the store's and those waiting for it.
    private func refreshLatest() async {
        var candidates = unstored.map(\.reading)
        if let store {
            do {
                if let latest = try await store.latestLiveReading() {
                    candidates.append(latest)
                    if let previous = try await Self.previousLive(before: latest, in: store) {
                        candidates.append(previous)
                    }
                }
            } catch {
                log(.store, "could not read the latest reading: \(error)")
                if candidates.isEmpty { return }
            }
        }
        let ordered = candidates.filter { !Self.isImported($0) }.sorted { $0.date < $1.date }
        latestLiveReading = ordered.last
        previousLiveReading = ordered.last.flatMap { latest in ordered.last { $0.date < latest.date } }
    }

    /// The live reading just before `latest` within the delta window (the delta is shown only for
    /// readings ≤ 15 min apart; 30 min leaves room). Never imported history (S6).
    private static func previousLive(before latest: GlucoseReading, in store: any GlucoseReadingRepository) async throws -> GlucoseReading? {
        let candidates = try await store.readings(from: latest.date.addingTimeInterval(-30 * 60), to: latest.date)
        return candidates.last { !isImported($0) && $0.date < latest.date }
    }

    private static func isImported(_ reading: GlucoseReading) -> Bool {
        if case .imported = reading.source { return true }
        return false
    }

    /// Writes the widget snapshot from what is stored now, plus readings waiting for the store.
    func publishWidget() async {
        guard let widget = outputs.widget else { return }
        let date = now()
        let windowStart = date.addingTimeInterval(-3 * 3_600)
        let windowEnd = date.addingTimeInterval(LiveReadingGate.futureTolerance)
        var recent = unstored.map(\.reading).filter { $0.date >= windowStart && $0.date < windowEnd }
        if let store {
            do {
                recent += try await store.readings(from: windowStart, to: windowEnd)
            } catch {
                log(.app, "widget chart readings not read: \(error)")
            }
        }
        widget.publish(latestLive: latestLiveReading, previousLive: previousLiveReading, recent: recent.sorted { $0.date < $1.date },
                       sensorState: sensorState ?? .notPaired, now: date)
    }

    private func log(_ category: DiagnosticEvent.Category, _ message: String) {
        diagnostics.record(DiagnosticEvent(date: now(), category: category, message: "pipeline[\(name)]: " + message))
    }
}
