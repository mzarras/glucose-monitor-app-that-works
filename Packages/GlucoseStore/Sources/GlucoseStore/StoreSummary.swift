// What Settings shows about storage (HANDOFF §4.5 "Backup"): count, date range, size on disk.

import Foundation

public struct StoreSummary: Sendable, Equatable {
    /// Rows stored, from every source.
    public let readingCount: Int
    /// Date of the oldest stored reading; nil when empty.
    public let earliest: Date?
    /// Date of the newest stored reading; nil when empty.
    public let latest: Date?
    /// Bytes used by the database file plus its -wal and -shm files. nil for an in-memory store.
    public let fileSizeBytes: Int64?

    public init(readingCount: Int, earliest: Date?, latest: Date?, fileSizeBytes: Int64?) {
        self.readingCount = readingCount
        self.earliest = earliest
        self.latest = latest
        self.fileSizeBytes = fileSizeBytes
    }
}
