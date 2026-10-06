// Original to Sensor (no ported code).
// Resume state for the Nightscout history import (HANDOFF §4.5 step 3: resumable and idempotent).

import Foundation

/// How much history to import (HANDOFF §4.5 step 1: 90 days by default, option for everything).
public enum NightscoutImportScope: Sendable, Equatable, Hashable, Codable {
    /// The last `days` × 24 h before the import started.
    case lastDays(Int)
    /// All sgv entries on the site.
    case everything

    public static let `default` = NightscoutImportScope.lastDays(90)
}

/// Progress of one import plan, saved after every completed 7-day window.
///
/// The importer walks backwards from `planEnd`. Everything in `[completedDownTo, planEnd)` has
/// been fetched and handed to the repository. Resuming continues below `completedDownTo`; a crash
/// between the repository insert and the checkpoint save only means that window is fetched again,
/// which the repository's insert-or-ignore makes harmless (S3).
public struct NightscoutImportCheckpoint: Sendable, Equatable, Codable {
    /// Site the plan belongs to (no credentials; `NightscoutSite` never contains any). A checkpoint
    /// for a different site or scope is discarded and the plan starts over.
    public let site: NightscoutSite
    public let scope: NightscoutImportScope
    /// Fixed upper bound of the plan, set when the plan started (the clock at that moment).
    public let planEnd: Date
    /// Lower bound for `.lastDays`; `nil` for `.everything`.
    public let planStart: Date?
    /// Lower edge of the completed range.
    public var completedDownTo: Date
    /// Readings the repository reported as newly stored, summed over completed windows.
    public var readingsImported: Int
    /// Readings handed to the repository that it did not store: already present, or within ±150 s
    /// of a stored reading (a sensor reading, or a near-duplicate from a second uploader or an
    /// overlapping import — GlucoseReadingRepository.insert).
    public var readingsSkippedByStore: Int
    /// Entries fetched that were not stored as readings, by reason (non-sgv, error codes, …).
    public var skipped: [NightscoutEntrySkipReason: Int]
    public var isFinished: Bool

    public init(
        site: NightscoutSite,
        scope: NightscoutImportScope,
        planEnd: Date,
        planStart: Date?,
        completedDownTo: Date,
        readingsImported: Int,
        readingsSkippedByStore: Int,
        skipped: [NightscoutEntrySkipReason: Int],
        isFinished: Bool
    ) {
        self.site = site
        self.scope = scope
        self.planEnd = planEnd
        self.planStart = planStart
        self.completedDownTo = completedDownTo
        self.readingsImported = readingsImported
        self.readingsSkippedByStore = readingsSkippedByStore
        self.skipped = skipped
        self.isFinished = isFinished
    }
}

/// Where the checkpoint lives. The app backs it with UserDefaults
/// (`UserDefaultsNightscoutImportCheckpointStore`).
public protocol NightscoutImportCheckpointStore: Sendable {
    func loadCheckpoint() async throws -> NightscoutImportCheckpoint?
    func saveCheckpoint(_ checkpoint: NightscoutImportCheckpoint) async throws
    func clearCheckpoint() async throws
}

/// In-memory checkpoint store for tests and previews.
public actor InMemoryNightscoutImportCheckpointStore: NightscoutImportCheckpointStore {
    public private(set) var checkpoint: NightscoutImportCheckpoint?

    public init(_ checkpoint: NightscoutImportCheckpoint? = nil) {
        self.checkpoint = checkpoint
    }

    public func loadCheckpoint() -> NightscoutImportCheckpoint? { checkpoint }
    public func saveCheckpoint(_ checkpoint: NightscoutImportCheckpoint) { self.checkpoint = checkpoint }
    public func clearCheckpoint() { checkpoint = nil }
}

/// Checkpoint as JSON under one UserDefaults key.
///
/// Holds the suite name rather than a `UserDefaults` instance (which is not `Sendable`) and opens
/// the suite per call; `nil` means `UserDefaults.standard`.
public struct UserDefaultsNightscoutImportCheckpointStore: NightscoutImportCheckpointStore {
    public static let defaultKey = "nightscoutImport.checkpoint.v1"

    private let suiteName: String?
    private let key: String

    public init(suiteName: String? = nil, key: String = UserDefaultsNightscoutImportCheckpointStore.defaultKey) {
        self.suiteName = suiteName
        self.key = key
    }

    public func loadCheckpoint() throws -> NightscoutImportCheckpoint? {
        guard let data = try defaults().data(forKey: key) else { return nil }
        return try JSONDecoder().decode(NightscoutImportCheckpoint.self, from: data)
    }

    public func saveCheckpoint(_ checkpoint: NightscoutImportCheckpoint) throws {
        try defaults().set(try JSONEncoder().encode(checkpoint), forKey: key)
    }

    public func clearCheckpoint() throws {
        try defaults().removeObject(forKey: key)
    }

    private func defaults() throws -> UserDefaults {
        guard let suiteName else { return .standard }
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "No UserDefaults suite \(suiteName)"])
        }
        return defaults
    }
}
