// TrioBridge's status → the facade's `TrioBridgeSummary`. This file imports TrioBridge but not
// AlertEngine: both modules declare a `TrioBridgeStatus`, and neither can be qualified by module
// name in Swift (each module also exports a type with its own name). The summary → alert input
// mapping is in TrioAlertInput.swift.

import Foundation
import TrioBridge

extension TrioBridgeSummary {
    /// Copies the bridge's health into the summary. The user's switch, `liveOutputsAllowed`, the
    /// App Group ID and the heartbeat fields are kept.
    mutating func update(from status: TrioBridgeStatus, now: Date) {
        lastSuccessfulWriteAt = status.lastSuccessfulWriteAt
        readingsInLastWrite = status.readingsInLastWrite
        newestReadingWrittenAt = status.newestReadingWrittenAt
        consecutiveFailures = status.consecutiveFailures
        lastErrorDescription = status.lastError.map(Self.describe)
        lastErrorAt = status.lastErrorAt
        bridgeIsStarving = status.isStarving()
        trioLag = status.trioLag
        refreshStarvation(now: now)
        lastGateRefusalDescription = status.lastGateRefusal.map { "\($0.reason) — reading at \($0.readingDate.ISO8601Format())" }
        if status.isFailing || isStarving || unavailableReason != nil {
            problemSince = problemSince ?? (status.isFailing ? status.lastErrorAt : nil) ?? now
        } else {
            problemSince = nil
        }
    }

    /// Trio is starving when the bridge says so, or when readings have been held back from it for
    /// the starvation threshold (review m5: a hold must count as readings Trio does not have).
    mutating func refreshStarvation(now: Date) {
        let heldTooLong = heldBackSince.map { now.timeIntervalSince($0) >= TrioBridgeStatus.starvationThreshold } ?? false
        // D45: while listening the handoff is off on purpose; Trio has its own CGM path.
        isStarving = !offWhileListening && (bridgeIsStarving || heldTooLong)
    }

    /// Words for Settings and the S5 banner.
    static func describe(_ error: TrioBridgeError) -> String {
        switch error {
        case .appGroupUnavailable(let groupID, let reason):
            switch reason {
            case .invalidGroupID:
                return "Trio's App Group ID \"\(groupID)\" is not valid; the build's team ID is missing or wrong"
            case .notEntitled:
                return "This build is not entitled to Trio's App Group \(groupID); sign both apps with the same team (docs/trio-bridge.md, Setup)"
            case .suiteUnavailable:
                return "Trio's App Group \(groupID) could not be opened"
            }
        case .encodingFailed(let description):
            return "Readings could not be encoded for Trio: \(description)"
        case .readBackMismatch:
            return "Trio's App Group did not keep what was written"
        }
    }
}
