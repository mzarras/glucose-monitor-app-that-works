// Contract (HANDOFF §4.4, §4.5, S3). Implemented by GlucoseStore (WS2). Owned by the orchestrator.

import Foundation

/// Persistent reading storage as seen by the rest of the app.
public protocol GlucoseReadingRepository: Sendable {
    /// Insert-or-ignore keyed by `id` (S3 dedupe): inserting the same readings again changes nothing.
    ///
    /// Also applies HANDOFF §4.5 step 3, with "within ±2.5 minutes" meaning |Δt| ≤ 150 s inclusive:
    /// - an `.imported` reading is skipped when any stored reading of any source (sensor, or an
    ///   import from the same or another origin) lies within ±150 s of it — this also removes the
    ///   near-duplicates Nightscout accumulates when two uploaders post the same reading, and the
    ///   overlap between a Nightscout and a Clarity import of the same period;
    /// - storing a `.sensor` reading deletes `.imported` readings within ±150 s of it.
    /// Readings inside one call are applied in ascending date order, so these rules also hold
    /// within a single batch.
    ///
    /// - Returns: only the readings that were newly stored, ascending by date. The pipeline passes
    ///   each of these through `LiveReadingGate` before handing it to Trio, uploaders or alerts, so
    ///   a re-delivered reading is never re-published and an imported one never reaches them.
    func insert(_ readings: [GlucoseReading]) async throws -> [GlucoseReading]

    /// Readings with `start <= date < end`, ascending by date.
    func readings(from start: Date, to end: Date) async throws -> [GlucoseReading]

    /// The most recent reading by `date` whose source is not `.imported` — i.e. `.sensor` (or, in a
    /// DEBUG replay database, `.replay`/`.mock`). The current value, its age, the delta, staleness
    /// (S5 missed readings) and the widget snapshot all use this, never an imported reading
    /// (S6: imported history is for charts and stats only).
    func latestLiveReading() async throws -> GlucoseReading?

    /// A new stream per call. Yields once after every committed write that changed stored rows.
    func changes() -> AsyncStream<Void>
}
