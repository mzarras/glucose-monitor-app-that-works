// Contract (HANDOFF §4.4, §4.5, S3). Implemented by GlucoseStore (WS2). Owned by the orchestrator.

import Foundation

/// Persistent reading storage as seen by the rest of the app.
public protocol GlucoseReadingRepository: Sendable {
    /// Insert-or-ignore keyed by `id` (S3 dedupe): inserting the same readings again changes nothing.
    ///
    /// Also applies HANDOFF §4.5 step 3: an `.imported` reading is skipped when a `.sensor` reading
    /// exists within ±2.5 minutes of it, and storing a `.sensor` reading removes `.imported`
    /// readings within ±2.5 minutes of it.
    ///
    /// - Returns: only the readings that were newly stored, ascending by date. The pipeline hands
    ///   exactly these to Trio, uploaders and alerts, so a re-delivered reading is never re-published.
    func insert(_ readings: [GlucoseReading]) async throws -> [GlucoseReading]

    /// Readings with `start <= date < end`, ascending by date.
    func readings(from start: Date, to end: Date) async throws -> [GlucoseReading]

    /// The most recent reading by `date`, from any source.
    func latestReading() async throws -> GlucoseReading?

    /// A new stream per call. Yields once after every committed write that changed stored rows.
    func changes() -> AsyncStream<Void>
}
