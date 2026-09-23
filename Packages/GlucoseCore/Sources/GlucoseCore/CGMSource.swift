// Contract (HANDOFF §4.3). Owned by the orchestrator; change only through PROGRESS.md.

/// A source of glucose readings: the G7 sensor (G7Kit) or, in DEBUG only, a replay (ReplayKit).
/// Everything downstream consumes this protocol, never a concrete source.
public protocol CGMSource: Sendable {
    /// New and backfilled readings. Every element must already satisfy S2 at the source:
    /// authenticated session, sensor status valid, timestamp derived per S3.
    /// Single consumer: the app's reading pipeline.
    var readings: AsyncStream<GlucoseReading> { get }
    /// State changes, starting with the current state. Single consumer: the app's pipeline.
    var state: AsyncStream<SensorState> { get }
    /// Added in Phase 0 (not in HANDOFF §4.3): the session this source is authenticated to, or
    /// `nil`. Downstream consumers pass it to `LiveReadingGate` (S2).
    var currentSession: SensorSession? { get async }
    /// Starts scanning/connecting. `pairingCode` is the 4-digit sensor code, needed only to pair.
    func start(pairingCode: String?) async throws
    func stop() async
}
