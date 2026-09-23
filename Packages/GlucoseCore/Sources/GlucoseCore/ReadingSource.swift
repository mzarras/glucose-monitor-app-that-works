// Contract (HANDOFF §4.3). Owned by the orchestrator; change only through PROGRESS.md.

/// Where a reading came from.
///
/// Only `.sensor` readings may reach Trio, the alert engine, or any uploader (S6).
/// `.replay` and `.mock` exist only in DEBUG builds; `.imported` feeds charts and stats only.
public enum ReadingSource: Sendable, Equatable, Hashable, Codable {
    case sensor
    case imported(ImportOrigin)
    case replay
    case mock

    /// True only for readings from an authenticated live sensor session (S6).
    public var isLiveSensor: Bool { self == .sensor }
}

/// Origin of a reading imported from history (HANDOFF §4.5).
public enum ImportOrigin: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case nightscout
    case clarityCSV
}
