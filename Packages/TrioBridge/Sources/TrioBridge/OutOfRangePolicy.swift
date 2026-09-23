// What the bridge does with the sensor's LOW and HIGH flags (S4). One explicit policy, one place.
//
// A safety trade-off (docs/trio-bridge.md, "LOW and HIGH"):
//   - not writing a LOW/HIGH reading means Trio's newest reading ages; after 12 minutes Trio stops
//     looping (Trio `APSManager.swift:464-470`), the running temp basal finishes, and the pump returns
//     to the scheduled basal while the sensor may still read LOW;
//   - writing a number puts a value the sensor did not report into Trio (S1), which Trio shows as an
//     ordinary number.
// Decision (PROGRESS.md D21, Michael): LOW → 39, HIGH → 401, i.e. `.writeSentinel` for both, set explicitly
// in the app's wiring with a comment citing D21. The package default stays `.doNotWrite` so the sentinels
// cannot be enabled by accident. 40/400 are never written for a flag under any policy (S4).

/// How LOW (`GlucoseValue.belowRange`) and HIGH (`GlucoseValue.aboveRange`) readings reach Trio.
public struct OutOfRangePolicy: Sendable, Equatable, Hashable {
    public enum Action: Sendable, Equatable, Hashable {
        /// The reading is not written to Trio. The refusal is recorded in `TrioBridgeStatus` and
        /// the diagnostic log so the app can say "LOW not sent to Trio" (S5).
        case doNotWrite
        /// The reading is written with the ecosystem's LOW/HIGH code:
        /// `TrioAppGroupContract.lowSentinelMgdl` (39) or `.highSentinelMgdl` (401).
        /// Never 40 or 400 (S4). Chosen for both flags by Michael (PROGRESS.md D21).
        case writeSentinel
    }

    /// Action for the sensor's LOW flag.
    public var low: Action
    /// Action for the sensor's HIGH flag.
    public var high: Action

    public init(low: Action, high: Action) {
        self.low = low
        self.high = high
    }

    /// The package default: neither LOW nor HIGH is written to Trio. The app overrides it per D21.
    public static let doNotWrite = OutOfRangePolicy(low: .doNotWrite, high: .doNotWrite)
}
