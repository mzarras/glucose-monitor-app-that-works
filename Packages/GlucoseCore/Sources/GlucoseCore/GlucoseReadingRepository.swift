// Contract (HANDOFF §4.4, §4.5, S3). Implemented by GlucoseStore (WS2). Owned by the orchestrator.

import Foundation

/// Persistent reading storage as seen by the rest of the app.
///
/// Two roles, never mixed (S1, S6):
/// - **production** — the app's database. Stores only `.sensor` and `.imported` readings. `insert`
///   throws `GlucoseReadingRepositoryError.sourceNotAllowed` for `.replay`/`.mock` — a batch that
///   contains any disallowed reading is rejected whole and nothing is stored — and opening a
///   production store deletes any `.replay`/`.mock` rows (defence against a DEBUG build having
///   written them to the same App Group database).
/// - **replay** (DEBUG only) — a separate in-memory store or separate file used while a ReplayKit
///   source runs. Stores only `.replay`/`.mock` readings and throws for anything else.
///
/// Both roles reject the whole batch, storing nothing, when any reading has:
/// - a numeric value outside `GlucoseValue.sensorReportableRange` (40...400) →
///   `GlucoseReadingRepositoryError.implausibleValue`;
/// - a non-finite trend rate → `.nonFiniteTrendRate` (never rewritten to nil: the returned
///   readings must be exactly what the caller passed, so `LiveReadingGate` sees the fault);
/// - a date later than the store's clock plus `LiveReadingGate.futureTolerance` → `.futureDated`.
/// Each can only come from a parse or clock fault; storing it would put it in charts, stats or the
/// current value (S1, S5). Sources and importers filter before calling `insert`, so in practice
/// these only fire on a bug.
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
    /// - Returns: only the readings that were newly stored, ascending by date, exactly as passed in
    ///   (no field rewritten). The pipeline passes
    ///   each of these through `LiveReadingGate` before handing it to Trio, uploaders or alerts, so
    ///   a re-delivered reading is never re-published and an imported one never reaches them.
    func insert(_ readings: [GlucoseReading]) async throws -> [GlucoseReading]

    /// Readings with `start <= date < end`, ascending by date.
    func readings(from start: Date, to end: Date) async throws -> [GlucoseReading]

    /// The most recent live reading by `date`: the latest `.sensor` reading in a production store,
    /// or the latest `.replay`/`.mock` reading in a DEBUG replay store — never `.imported`.
    /// The current value, its age, the delta, staleness (S5 missed readings) and the widget
    /// snapshot all use this (S6: imported history is for charts and stats only).
    func latestLiveReading() async throws -> GlucoseReading?

    /// A new stream per call. Yields once after every committed write that changed stored rows.
    func changes() -> AsyncStream<Void>
}

/// Errors every repository implementation uses for contract violations.
public enum GlucoseReadingRepositoryError: Error, Sendable, Equatable {
    /// The reading's source is not allowed in this store's role (see `GlucoseReadingRepository`).
    case sourceNotAllowed(ReadingSource)
    /// A numeric value outside `GlucoseValue.sensorReportableRange`.
    case implausibleValue(Int)
    /// A trend rate that is NaN or infinite.
    case nonFiniteTrendRate
    /// A reading dated later than the store's clock plus `LiveReadingGate.futureTolerance`.
    case futureDated(Date)
}
