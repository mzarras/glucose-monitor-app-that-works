// The facade's `TrioBridgeSummary` → AlertEngine's input for the HANDOFF §5 "Trio bridge" alert
// (S5). Imports AlertEngine but not TrioBridge (see TrioStatusMapping.swift for why).
//
// docs/trio-bridge.md "Failure reporting": the alert fires on write failures and on starvation
// (live readings keep arriving but Trio has had none of them for 15 min, whatever the cause). The
// 15-minute threshold is already applied by `isStarving`, so both map to `.writeFailing`, which
// alerts at once. "Trio not consuming" is not detectable (D22) and is never reported.

import AlertEngine
import Foundation

extension TrioBridgeSummary {
    var alertInput: TrioBridgeStatus {
        guard isEnabled, liveOutputsAllowed else { return .off }
        let since = problemSince ?? lastErrorAt ?? newestReadingWrittenAt ?? .distantPast
        if let unavailableReason {
            return .writeFailing(since: since, reason: unavailableReason)
        }
        if isFailing {
            return .writeFailing(since: since, reason: lastErrorDescription ?? "Writing to Trio's App Group failed")
        }
        if isStarving {
            let minutes = Int((trioLag ?? 0) / 60)
            return .writeFailing(since: since, reason: "Trio has had no new reading for \(minutes) min although readings are arriving"
                + (lastGateRefusalDescription.map { " (last refusal: \($0))" } ?? ""))
        }
        return .healthy
    }
}
