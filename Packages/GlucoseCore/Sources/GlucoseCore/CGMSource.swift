// Contract (HANDOFF §4.3). Owned by the orchestrator; change only through PROGRESS.md.

/// A source of glucose readings: the G7 sensor (G7Kit) or, in DEBUG only, a replay (ReplayKit).
/// Everything downstream consumes this protocol, never a concrete source.
///
/// Stream rules (a lost reading is a silent failure, S5) — every implementation must:
/// - create `readings` and `state` once, with `bufferingPolicy: .unbounded`
///   (e.g. `AsyncStream.makeStream(of:bufferingPolicy:)`), and return the same instance for the
///   source's whole lifetime, so a burst of 24 h of backfill (288 readings) is never dropped;
/// - never finish either stream in `stop()`: a source can be stopped and started again and keeps
///   delivering on the same streams;
/// - have exactly one consumer per stream — the app's reading pipeline. A second iterator would
///   silently receive only some of the elements.
/// Each implementation's tests must prove the burst and stop/start rules.
public protocol CGMSource: Sendable {
    /// New and backfilled readings. Every element must already satisfy S2 at the source:
    /// authenticated session, sensor status valid, timestamp derived per S3.
    var readings: AsyncStream<GlucoseReading> { get }
    /// State changes, starting with the current state.
    var state: AsyncStream<SensorState> { get }
    /// Added in Phase 0 (not in HANDOFF §4.3): the session this source is authenticated to, or
    /// `nil`. Downstream consumers pass it to `LiveReadingGate` (S2).
    var currentSession: SensorSession? { get async }
    /// Starts scanning/connecting. `pairingCode` is the 4-digit sensor code, needed only to pair.
    func start(pairingCode: String?) async throws
    func stop() async
}
