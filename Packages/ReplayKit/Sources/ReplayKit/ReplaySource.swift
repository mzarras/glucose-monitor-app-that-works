// Plays a ReplayTimeline as a CGMSource. DEBUG only (S6): compiled out of Release.
#if DEBUG
import Foundation
import GlucoseCore

/// A `CGMSource` that delivers a `ReplayTimeline` (a scripted scenario or a Nightscout export)
/// against a `ReplayClock`. Every reading it emits has `source == .replay` (checked at init, S6).
///
/// Follows the `CGMSource` stream rules: `readings` and `state` are created once, unbounded, and
/// never finished — not by `stop()`, and not when the timeline runs out. Single consumer each.
///
/// Lifecycle: `start` begins (or resumes) playback; `stop` pauses it and returns only once the
/// playback task has ended, so nothing is delivered while stopped. Starting again continues with
/// the next undelivered event; events whose time passed while stopped are delivered at once, in
/// order, with their original dates (like a sensor delivering on reconnect).
///
/// The app runs a replay source against a DEBUG replay store (`GlucoseStore.replay()`), never
/// the production database (PROGRESS.md D20).
public actor ReplaySource: CGMSource {
    public nonisolated let timeline: ReplayTimeline
    public nonisolated let readings: AsyncStream<GlucoseReading>
    public nonisolated let state: AsyncStream<SensorState>

    private let readingsContinuation: AsyncStream<GlucoseReading>.Continuation
    private let stateContinuation: AsyncStream<SensorState>.Continuation
    private let clock: any ReplayClock
    private var nextEventIndex = 0
    private var playback: Task<Void, Never>?
    private var hasStarted = false
    /// Set when the timeline delivers a state that ends the session (`.expired`, `.failed`).
    private var sessionEnded = false

    /// Everything put on the streams so far, in order. `emit` and `deliver(state:)` are the only
    /// places that yield, and they append here first, so tests can prove the streams carry exactly
    /// the script and nothing else (S1).
    private(set) var emittedReadings: [GlucoseReading] = []
    private(set) var emittedStates: [SensorState]

    public init(timeline: ReplayTimeline, clock: any ReplayClock) {
        precondition(
            timeline.readingsInDeliveryOrder.allSatisfy { $0.source == .replay },
            "ReplaySource \(timeline.name): every reading must have source .replay (S6)"
        )
        let (readings, readingsContinuation) = AsyncStream.makeStream(of: GlucoseReading.self, bufferingPolicy: .unbounded)
        let (state, stateContinuation) = AsyncStream.makeStream(of: SensorState.self, bufferingPolicy: .unbounded)
        self.timeline = timeline
        self.clock = clock
        self.readings = readings
        self.readingsContinuation = readingsContinuation
        self.state = state
        self.stateContinuation = stateContinuation
        // "State changes, starting with the current state" (CGMSource).
        self.emittedStates = [timeline.initialState]
        stateContinuation.yield(timeline.initialState)
    }

    /// The CGMSource lifetime rule: nil before the first `start` (a real source knows its session
    /// only once authenticated); then the timeline's session, unchanged across `stop`/`start`
    /// (a routine disconnect); nil again once the session has ended — the timeline delivered
    /// `.expired` or `.failed`, or replay time is past `gracePeriodEndsAt`.
    ///
    /// A replay run is not persisted: after an app relaunch a new source starts a new run, so the
    /// relaunch part of the rule does not apply.
    public var currentSession: SensorSession? {
        get async {
            guard hasStarted, !sessionEnded else { return nil }
            guard await clock.now() <= timeline.session.gracePeriodEndsAt else { return nil }
            return timeline.session
        }
    }

    /// Begins or resumes playback. `pairingCode` is ignored. Calling it while playing does nothing.
    public func start(pairingCode: String?) async throws {
        hasStarted = true
        guard playback == nil else { return }
        playback = Task { await self.play() }
    }

    /// Pauses playback. Returns after the playback task has ended; the streams stay open.
    public func stop() async {
        guard let task = playback else { return }
        playback = nil
        task.cancel()
        await task.value
    }

    /// Waits until the current playback has delivered every event (or was stopped). With a
    /// `ManualReplayClock` this waits until the clock is advanced past the last event.
    public func waitForPlayback() async {
        await playback?.value
    }

    private func play() async {
        while nextEventIndex < timeline.events.count {
            let event = timeline.events[nextEventIndex]
            do {
                try await clock.sleep(until: timeline.deliveryDate(of: event))
            } catch {
                return // cancelled by stop()
            }
            // stop() may have run while this task was suspended; never deliver after it.
            guard !Task.isCancelled else { return }
            deliver(event.kind)
            nextEventIndex += 1
        }
    }

    private func deliver(_ kind: ReplayEvent.Kind) {
        switch kind {
        case .reading(let reading):
            emit(reading)
        case .backfill(let batch):
            for reading in batch {
                emit(reading)
            }
        case .state(let newState):
            switch newState {
            case .expired, .failed: sessionEnded = true
            default: break
            }
            emittedStates.append(newState)
            stateContinuation.yield(newState)
        }
    }

    private func emit(_ reading: GlucoseReading) {
        emittedReadings.append(reading)
        readingsContinuation.yield(reading)
    }
}
#endif
