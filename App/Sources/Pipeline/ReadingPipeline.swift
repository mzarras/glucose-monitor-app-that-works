// The reading pipeline: one CGM source → the store → the live consumers (HANDOFF §9.3 Phase 2).
//
//   source.readings ─┐                                          ┌─ TrioBridge.publish
//                    ├─ one ordered queue ─ store.insert ─ gate ─┼─ AlertService .reading
//   source.state  ───┘       (held while inactive               ├─ uploaders submit + flushIfDue
//                             or the store is closed)            └─ widget snapshot, UI
//
// What this file guarantees (docs/architecture.md "Where each safety rule is enforced"):
// - Only readings `insert` returns — newly stored — go further, so a re-delivered reading is
//   published once (S3). Imported history never enters: importers write to the store directly (S6).
// - Every newly stored reading passes `LiveReadingGate` here, against the source's current session
//   and the pipeline clock, before any consumer sees it (S2, S6). A refusal is logged as a
//   diagnostic and counted; nothing valid is dropped silently. The consumers gate again.
//   In a DEBUG replay run the gate is `validateAllowingReplay` (D11); the Trio bridge and the
//   uploaders keep their own sensor-only gate, so replay can never reach them (S6).
// - Events are processed strictly in arrival order, one batch at a time: consecutive readings are
//   stored in one `insert`, a state change is handled on its own.
// - Nothing is dropped while the pipeline cannot deliver: until `activate()` and while the store is
//   closed (before the first unlock after a reboot) events are held in memory and processed, in
//   order, once possible (S5: `heldReadingCount` is shown).
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
    enum Event: Sendable, Equatable {
        case reading(GlucoseReading)
        case state(SensorState)
    }

    /// For diagnostics: "sensor" or "replay:<scenario>".
    let name: String
    let source: any CGMSource
    private(set) var store: (any GlucoseReadingRepository)?
    var outputs = PipelineOutputs()

    /// The newest sensor state received (updated on arrival, even while held, so the UI is current).
    private(set) var sensorState: SensorState?
    /// `source.currentSession`, re-read after every processed event.
    private(set) var sensorSession: SensorSession?
    /// The store's latest live reading, however old, and the live reading before it.
    private(set) var latestLiveReading: GlucoseReading?
    private(set) var previousLiveReading: GlucoseReading?

    // Counters for diagnostics and tests.
    private(set) var receivedReadingCount = 0
    private(set) var receivedStateCount = 0
    private(set) var storedReadingCount = 0
    private(set) var gateRefusalCount = 0
    private(set) var storeRefusalCount = 0
    /// Why the last insert failed for a reason other than a refused reading (disk, SQL); nil after
    /// the next successful insert. The readings stay held (S5).
    private(set) var storeProblem: String?

    /// Readings waiting for the store or activation.
    var heldReadingCount: Int {
        pending.reduce(0) { count, event in
            if case .reading = event { return count + 1 }
            return count
        }
    }

    /// True when nothing is queued or being processed.
    var isIdle: Bool { pending.isEmpty && !isProcessing }

    /// Called on the main actor after something the UI shows changed.
    var onChange: (@MainActor (ServiceChange) -> Void)?
    /// Called after every processed batch (a wake-up): pipeline heartbeat, clock latch, diagnostics.
    var onBatchProcessed: (@MainActor () -> Void)?

    private let diagnostics: any DiagnosticLog
    private let now: @Sendable () -> Date
    #if DEBUG
    private var acceptsReplayReadings = false
    #endif
    private var pending: [Event] = []
    private var isActive = false
    private var isProcessing = false
    private var consumers: [Task<Void, Never>] = []
    private let signals: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var worker: Task<Void, Never>?

    /// At most this many events are held. Beyond it the oldest are dropped, loudly: 10 000 readings
    /// is five weeks at the G7's 5-minute cadence, far beyond any wait for the first unlock.
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
                self?.enqueue(.reading(reading))
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

    /// Starts delivering: held events are processed in order.
    func activate() {
        isActive = true
        signal.yield(())
    }

    /// Holds events from now on (a DEBUG replay run replaced this source for a while).
    func deactivate() {
        isActive = false
    }

    /// The store is open: held readings are stored and delivered.
    func attach(store: any GlucoseReadingRepository) {
        self.store = store
        signal.yield(())
        Task { await refreshLatest() }
    }

    /// Re-runs the queue (e.g. after a transient store failure, on foreground).
    func retryHeldEvents() {
        signal.yield(())
    }

    /// Re-reads the latest live readings after a change made elsewhere (import, purge) and tells
    /// the UI.
    func storeDidChange() async {
        await refreshLatest()
        onChange?(.readings)
    }

    // MARK: - Queue

    private func enqueue(_ event: Event) {
        switch event {
        case .reading:
            receivedReadingCount += 1
        case .state(let state):
            receivedStateCount += 1
            sensorState = state
            onChange?(.sensor)
        }
        pending.append(event)
        if pending.count > Self.maximumHeldEvents {
            let dropped = pending.count - Self.maximumHeldEvents
            pending.removeFirst(dropped)
            log(.store, "held-event limit reached: dropped the \(dropped) oldest held event(s) (S5)")
        }
        if !isActive || (store == nil && heldReadingCount > 0) {
            onChange?(.storage)
        }
        signal.yield(())
    }

    /// The next batch that can be processed now: all consecutive readings at the head (if the
    /// store is open), or the one state at the head. Nil when nothing can be processed.
    private func takeNextBatch() -> [Event]? {
        guard isActive, let head = pending.first else { return nil }
        switch head {
        case .state:
            pending.removeFirst()
            return [head]
        case .reading:
            guard store != nil else { return nil }
            let count = pending.prefix { if case .reading = $0 { return true } else { return false } }.count
            let batch = Array(pending.prefix(count))
            pending.removeFirst(count)
            return batch
        }
    }

    private func drain() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        var didProcess = false
        var readingsChanged = false
        while let batch = takeNextBatch() {
            didProcess = true
            if case .state(let state) = batch[0] {
                await process(state: state)
            } else {
                let readings = batch.compactMap { event -> GlucoseReading? in
                    if case .reading(let reading) = event { return reading }
                    return nil
                }
                switch await process(readings: readings) {
                case .stored(let any):
                    readingsChanged = readingsChanged || any
                case .storeFailed:
                    // Put them back at the head, in order, and stop until the next attempt (S5).
                    pending.insert(contentsOf: batch, at: 0)
                    onChange?(.storage)
                    return
                }
            }
        }
        guard didProcess else { return }
        // Every processed batch is a wake-up: let the alert engine look at the time (repeats due,
        // missed readings) — docs/alerts.md §9 "tick on every wake".
        await outputs.alerts?.send(.tick)
        if readingsChanged {
            await refreshLatest()
            onChange?(.readings)
        }
        await publishWidget()
        onBatchProcessed?()
        if heldReadingCount == 0 { onChange?(.storage) }
    }

    // MARK: - Readings

    private enum StoreOutcome {
        case stored(anyNew: Bool)
        case storeFailed
    }

    private func process(readings: [GlucoseReading]) async -> StoreOutcome {
        guard let store else { return .storeFailed }
        let stored: [GlucoseReading]
        do {
            stored = try await insertKeepingValid(readings, into: store)
            if storeProblem != nil {
                storeProblem = nil
                onChange?(.storage)
            }
        } catch {
            storeProblem = String(describing: error)
            log(.store, "insert of \(readings.count) reading(s) failed, holding them: \(error)")
            return .storeFailed
        }
        storedReadingCount += stored.count
        if stored.count < readings.count {
            log(.store, "\(readings.count - stored.count) of \(readings.count) delivered reading(s) were already stored (re-delivery, S3) or refused")
        }
        guard !stored.isEmpty else { return .stored(anyNew: false) }

        let session = await source.currentSession
        sensorSession = session
        let gateNow = now()
        var accepted: [GlucoseReading] = []
        for reading in stored {
            if let rejection = gateRejection(reading, session: session, now: gateNow) {
                gateRefusalCount += 1
                log(.sensor, "gate refused stored reading \(reading.id) at \(reading.date.ISO8601Format()) for Trio, alerts and uploads: \(rejection)")
            } else {
                accepted.append(reading)
            }
        }
        guard !accepted.isEmpty else { return .stored(anyNew: true) }

        // 1. Trio first: its heartbeat reads at the sensor's disconnect (docs/trio-bridge.md).
        if let trio = outputs.trio {
            let result = await trio.publish(accepted, session: sessionForTrio(session))
            if let error = result.error {
                log(.bridge, "Trio publish failed: \(error)")
            }
        }
        // 2. Alerts: only readings the store newly accepted and the gate passed (docs/alerts.md §9).
        if let alerts = outputs.alerts {
            for reading in accepted {
                await alerts.send(.reading(reading, session: session))
            }
        }
        // 3. Uploads: queue, then flush in the background (network must not hold up the queue).
        if !outputs.uploaders.isEmpty {
            for uploader in outputs.uploaders {
                for reading in accepted {
                    do throws(UploadRefusal) {
                        try await uploader.submit(reading, session: session)
                    } catch {
                        log(.upload, "\(uploader.destinationName) refused \(reading.id): \(error)")
                    }
                }
            }
            outputs.flushUploads?()
        }
        return .stored(anyNew: true)
    }

    /// `insert` rejects a whole batch when one reading is refused (docs/storage.md). Then each
    /// reading is stored on its own, so one faulty reading cannot keep valid ones out; every refused
    /// one is logged. Errors other than a refusal (disk, SQL, cancellation) are rethrown and the
    /// caller holds the batch.
    private func insertKeepingValid(_ readings: [GlucoseReading], into store: any GlucoseReadingRepository) async throws -> [GlucoseReading] {
        do {
            return try await store.insert(readings)
        } catch let refusal as GlucoseReadingRepositoryError {
            guard readings.count > 1 else {
                storeRefusalCount += 1
                log(.store, "store refused reading \(readings[0].id): \(refusal)")
                return []
            }
            var stored: [GlucoseReading] = []
            for reading in readings {
                do {
                    stored += try await store.insert([reading])
                } catch let single as GlucoseReadingRepositoryError {
                    storeRefusalCount += 1
                    log(.store, "store refused reading \(reading.id): \(single)")
                }
            }
            return stored
        }
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

    /// The session handed to the Trio bridge: the source's, except in a DEBUG replay run, where it
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

    private func refreshLatest() async {
        guard let store else { return }
        do {
            let latest = try await store.latestLiveReading()
            latestLiveReading = latest
            if let latest {
                previousLiveReading = try await Self.previousLive(before: latest, in: store)
            } else {
                previousLiveReading = nil
            }
        } catch {
            log(.store, "could not read the latest reading: \(error)")
        }
    }

    /// The live reading just before `latest` within the delta window (the delta is shown only for
    /// readings ≤ 15 min apart; 30 min leaves room). Never imported history (S6).
    private static func previousLive(before latest: GlucoseReading, in store: any GlucoseReadingRepository) async throws -> GlucoseReading? {
        let candidates = try await store.readings(from: latest.date.addingTimeInterval(-30 * 60), to: latest.date)
        return candidates.last { reading in
            if case .imported = reading.source { return false }
            return reading.date < latest.date
        }
    }

    /// Writes the widget snapshot from what is stored now.
    func publishWidget() async {
        guard let widget = outputs.widget, let store else { return }
        let date = now()
        do {
            let recent = try await store.readings(from: date.addingTimeInterval(-3 * 3_600), to: date.addingTimeInterval(LiveReadingGate.futureTolerance))
            widget.publish(latestLive: latestLiveReading, previousLive: previousLiveReading, recent: recent,
                           sensorState: sensorState ?? .notPaired, now: date)
        } catch {
            log(.app, "widget snapshot not written: \(error)")
        }
    }

    private func log(_ category: DiagnosticEvent.Category, _ message: String) {
        diagnostics.record(DiagnosticEvent(date: now(), category: category, message: "pipeline[\(name)]: " + message))
    }
}
