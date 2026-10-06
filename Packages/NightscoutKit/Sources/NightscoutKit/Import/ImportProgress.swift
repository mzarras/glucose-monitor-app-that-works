// What the onboarding progress view shows (HANDOFF §4.5 step 3: readings imported and the date
// range covered).

import Foundation

public struct NightscoutImportProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case running
        case finished
    }

    public let phase: Phase
    /// Readings newly stored by the repository.
    public let readingsImported: Int
    /// Readings the repository did not store (already present, or within ±150 s of a stored reading).
    public let readingsSkippedByStore: Int
    /// The history range fetched so far: `[coveredFrom, coveredTo)`.
    public let coveredFrom: Date
    public let coveredTo: Date
    /// Lower bound of the plan, `nil` for "everything" (total not known in advance).
    public let planStart: Date?
    public let skipped: [NightscoutEntrySkipReason: Int]

    public init(
        phase: Phase,
        readingsImported: Int,
        readingsSkippedByStore: Int,
        coveredFrom: Date,
        coveredTo: Date,
        planStart: Date?,
        skipped: [NightscoutEntrySkipReason: Int]
    ) {
        self.phase = phase
        self.readingsImported = readingsImported
        self.readingsSkippedByStore = readingsSkippedByStore
        self.coveredFrom = coveredFrom
        self.coveredTo = coveredTo
        self.planStart = planStart
        self.skipped = skipped
    }

    init(checkpoint: NightscoutImportCheckpoint) {
        self.init(
            phase: checkpoint.isFinished ? .finished : .running,
            readingsImported: checkpoint.readingsImported,
            readingsSkippedByStore: checkpoint.readingsSkippedByStore,
            coveredFrom: checkpoint.completedDownTo,
            coveredTo: checkpoint.planEnd,
            planStart: checkpoint.planStart,
            skipped: checkpoint.skipped
        )
    }
}
