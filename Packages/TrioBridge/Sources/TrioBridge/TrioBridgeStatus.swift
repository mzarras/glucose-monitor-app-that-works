// What the bridge reports so the app can fail loud (S5): write failures, refused readings, and
// LOW/HIGH readings that were withheld from Trio.
//
// Not reported: whether Trio is actually consuming the readings. Trio writes nothing back into the
// App Group (its only App Group access is the read in `Trio/Sources/APS/CGM/AppGroupSource.swift:34-48`;
// `lastLoopDate` is persisted in Trio's own container, `APSManager.swift:85-86`), so "Trio not consuming
// for 15 min" cannot be detected from here. See docs/trio-bridge.md, "Failure reporting".

import Foundation
import GlucoseCore

/// Why a write into Trio's App Group failed.
public enum TrioBridgeError: Error, Sendable, Equatable, Hashable {
    public enum AccessProblem: String, Sendable, Equatable, Hashable {
        /// The ID is not `group.org.nightscout.<10-char team>.trio.trio-app-group` (e.g. empty team ID).
        case invalidGroupID
        /// The OS gives this app no container for the group: the entitlement or provisioning is missing.
        case notEntitled
        /// `UserDefaults(suiteName:)` returned nil.
        case suiteUnavailable
    }

    /// The App Group cannot be used, so nothing reaches Trio.
    case appGroupUnavailable(groupID: String, reason: AccessProblem)
    /// The payload could not be encoded. Not expected; reported rather than crashing.
    case encodingFailed(description: String)
    /// The value read back after the write is not the value written.
    case writeNotPersisted
}

/// A reading the bridge did not put into Trio's payload, and why.
public struct TrioBridgeRefusal: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// Refused by `LiveReadingGate.validate`: S6 source check; S2 session, time, value-range and
        /// trend-rate checks.
        case gate(LiveReadingGate.Rejection)
        /// LOW or HIGH withheld by `OutOfRangePolicy` (S4). The associated value is the flag.
        case outOfRangeWithheld(GlucoseValue)
        /// Valid, but older than the newest `TrioAppGroupContract.maxReadings` readings, so Trio would not
        /// read it (`AppGroupSource.swift:61`).
        case olderThanPayloadWindow
    }

    public let readingID: String
    public let readingDate: Date
    public let reason: Reason
    /// When the bridge refused it (injected clock).
    public let refusedAt: Date

    public init(readingID: String, readingDate: Date, reason: Reason, refusedAt: Date) {
        self.readingID = readingID
        self.readingDate = readingDate
        self.reason = reason
        self.refusedAt = refusedAt
    }
}

/// The bridge's health, published after every change.
public struct TrioBridgeStatus: Sendable, Equatable {
    /// When `latestReadings` was last written and verified.
    public var lastSuccessfulWriteAt: Date?
    /// Timestamp of the newest reading in that write.
    public var newestReadingWrittenAt: Date?
    /// Number of readings in that write.
    public var readingsInLastWrite: Int = 0
    /// Failed write attempts since the last successful one. Non-zero means Trio is not getting readings.
    public var consecutiveFailures: Int = 0
    /// The most recent failure, kept after a later success for diagnostics; compare `lastErrorAt`.
    public var lastError: TrioBridgeError?
    public var lastErrorAt: Date?
    /// The most recent refused reading.
    public var lastRefusal: TrioBridgeRefusal?
    /// When a LOW or HIGH reading was last withheld from Trio under `OutOfRangePolicy`. While the sensor
    /// stays LOW/HIGH, Trio's newest reading ages and Trio stops looping after 12 minutes.
    public var lastOutOfRangeWithheldAt: Date?

    public init() {}

    /// True while the most recent write attempt failed.
    public var isFailing: Bool { consecutiveFailures > 0 }
}

/// Outcome of one `TrioBridge.publish` call.
public struct TrioPublishResult: Sendable, Equatable {
    /// IDs of the given readings that are now in Trio's payload, newest first.
    public var addedReadingIDs: [String] = []
    /// Given readings that were not put into the payload.
    public var refusals: [TrioBridgeRefusal] = []
    /// Given readings whose ID was already in the payload (S3 dedupe); the copy already written is kept.
    public var duplicateReadingIDs: [String] = []
    /// Whether `latestReadings` was written (and verified) by this call.
    public var didWrite = false
    /// Set when a write was needed and failed.
    public var error: TrioBridgeError?

    public init() {}
}
