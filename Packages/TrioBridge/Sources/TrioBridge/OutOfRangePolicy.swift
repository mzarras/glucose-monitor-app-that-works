// What the bridge does with the sensor's LOW and HIGH flags (S4). One explicit policy, one place.
//
// This is a safety trade-off that Michael decides (docs/trio-bridge.md, "LOW and HIGH"):
//   - not writing a LOW/HIGH reading means Trio's newest reading ages; after 12 minutes Trio stops
//     looping (Trio `APSManager.swift:464-470`), the running temp basal finishes, and the pump returns
//     to the scheduled basal while the sensor may still read LOW;
//   - writing a number presents a value the sensor did not report (S1) and that Trio shows as an
//     ordinary number.
// Until Michael decides, the default writes nothing for either flag.

/// How LOW (`GlucoseValue.belowRange`) and HIGH (`GlucoseValue.aboveRange`) readings reach Trio.
public struct OutOfRangePolicy: Sendable, Equatable, Hashable {
    public enum Action: Sendable, Equatable, Hashable {
        /// The reading is not written to Trio. The refusal is recorded in `TrioBridgeStatus` and
        /// the diagnostic log so the app can say "LOW not sent to Trio" (S5).
        case doNotWrite
        /// The reading is written with the ecosystem's LOW/HIGH code:
        /// `TrioAppGroupContract.lowSentinelMgdl` (39) or `.highSentinelMgdl` (401).
        /// Never 40 or 400 (S4). Requires Michael's explicit decision.
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

    /// The default until Michael decides: neither LOW nor HIGH is written to Trio.
    public static let doNotWrite = OutOfRangePolicy(low: .doNotWrite, high: .doNotWrite)
}
