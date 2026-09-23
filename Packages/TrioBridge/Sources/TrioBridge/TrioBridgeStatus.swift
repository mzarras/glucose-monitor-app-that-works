// What the bridge reports so the app can fail loud (S5): write failures, refused readings, LOW/HIGH
// readings withheld from Trio, and whether Trio is being starved of readings the app does have.
//
// Not reported: whether Trio actually reads the payload. Trio writes nothing back into the App Group
// (its only App Group access is the read in `Trio/Sources/APS/CGM/AppGroupSource.swift:34-52`;
// `lastLoopDate` is persisted in Trio's own storage, `APSManager.swift:85-86`), so "Trio not consuming"
// cannot be detected from here (PROGRESS.md D22). See docs/trio-bridge.md, "Failure reporting".

import Foundation
import GlucoseCore

/// Why a change to Trio's App Group failed.
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
    /// Reading the key back in this process did not return what was just written or removed. This only
    /// sees this process's view of the suite (a weak check); `appGroupUnavailable` from `checkAccess()` is
    /// the real guard against writes Trio cannot see.
    case readBackMismatch
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
        /// read it (`AppGroupSource.swift:61`). Benign; never masks a gate refusal (see `lastGateRefusal`).
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
    /// HANDOFF §5 "Trio bridge" alert: Trio has gone this long without a reading the app does have.
    public static let starvationThreshold: TimeInterval = 15 * 60

    /// When the App Group was last brought up to date: payload written, or key removed because no reading
    /// passes the gate (then `readingsInLastWrite` is 0).
    public var lastSuccessfulWriteAt: Date?
    /// Number of readings in that write (0 after a removal).
    public var readingsInLastWrite: Int = 0
    /// Failed attempts since the last success. Non-zero means Trio is not getting the current payload.
    public var consecutiveFailures: Int = 0
    /// The most recent failure, kept after a later success for diagnostics; compare `lastErrorAt`.
    public var lastError: TrioBridgeError?
    public var lastErrorAt: Date?
    /// The most recent refused reading, of any reason.
    public var lastRefusal: TrioBridgeRefusal?
    /// The most recent reading refused by `LiveReadingGate` (S2/S6). Kept separately so a benign
    /// `olderThanPayloadWindow` refusal in the same call cannot hide it.
    public var lastGateRefusal: TrioBridgeRefusal?
    /// When a LOW or HIGH reading was last withheld under `OutOfRangePolicy`.
    public var lastOutOfRangeWithheldAt: Date?

    /// Newest reading timestamp this bridge has successfully written since start or `clear()`: the newest
    /// reading Trio has from this app. Never decreases (a removal does not reset it).
    public var newestReadingWrittenAt: Date?
    /// Newest live (`.sensor`) reading timestamp offered to `publish`, accepted or not, capped at the
    /// bridge's clock.
    public var newestLiveReadingOfferedAt: Date?
    /// Before the first successful write: the newest live reading offered in the first call that offered
    /// one. Stands in for `newestReadingWrittenAt` so a bridge that never manages to write still starves.
    public var firstLiveReadingOfferedAt: Date?

    public init() {}

    /// True while the most recent attempt failed.
    public var isFailing: Bool { consecutiveFailures > 0 }

    /// How far the newest live reading offered is ahead of the newest reading Trio got from this bridge;
    /// nil before any live reading was offered. Grows for every reason Trio is not fed while readings keep
    /// arriving: write failures, gate refusals (including a `nil` session), and withheld LOW/HIGH. It does
    /// not grow when no readings arrive at all (a sensor gap is the missed-readings alert's job, HANDOFF §5).
    public var trioLag: TimeInterval? {
        guard let offered = newestLiveReadingOfferedAt,
              let fed = newestReadingWrittenAt ?? firstLiveReadingOfferedAt
        else { return nil }
        return max(0, offered.timeIntervalSince(fed))
    }

    /// The §5 "Trio bridge" alert condition: Trio has been starved of available readings for `threshold`.
    public func isStarving(after threshold: TimeInterval = starvationThreshold) -> Bool {
        guard let lag = trioLag else { return false }
        return lag >= threshold
    }
}

/// Outcome of one `TrioBridge.publish` call.
public struct TrioPublishResult: Sendable, Equatable {
    /// IDs of the given readings that are now in Trio's payload, newest first.
    public var addedReadingIDs: [String] = []
    /// Given readings that were not put into the payload.
    public var refusals: [TrioBridgeRefusal] = []
    /// Given readings whose ID was already in the window (S3 dedupe); the copy already written is kept.
    public var duplicateReadingIDs: [String] = []
    /// Whether `latestReadings` was written by this call.
    public var didWrite = false
    /// Whether `latestReadings` was removed by this call because no reading passes the gate any more.
    public var didRemovePayload = false
    /// Set when a change was needed and failed.
    public var error: TrioBridgeError?

    public init() {}
}
