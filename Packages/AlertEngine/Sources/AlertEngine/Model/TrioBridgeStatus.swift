// The plain status input for the Trio bridge alert (HANDOFF §5 "Trio bridge", S5). TrioBridge is
// built in parallel (WS6); the app maps whatever it reports into this type, so AlertEngine does not
// depend on it.

import Foundation

public enum TrioBridgeStatus: Sendable, Equatable, Hashable, Codable {
    /// The user has not turned the bridge on, or nothing has been reported yet. Never alerts.
    case off
    /// The last write succeeded and (if detectable) Trio is consuming readings.
    case healthy
    /// Writing to Trio's App Group failed. Alerts immediately.
    case writeFailing(since: Date, reason: String)
    /// Writes succeed but Trio has not consumed a reading since `since`. Alerts once that has
    /// lasted `AlertLimits.trioNotConsumingMinutes` (15). Report this only if it is detectable.
    case notConsumedSince(Date)
}
