// How Nightscout represents glucose values, including the LOW/HIGH flags (S4).
// This is the only file that knows the numbers 39 and 401.
//
// Evidence (cgm-remote-monitor 15.0.8, 92d08342):
//   lib/client/index.js:540-549   the main display: value < 39 → Dexcom error code text,
//                                 39 ≤ value < 40 → "LOW", value > 400 → "HIGH", else the number.
//   lib/client/index.js:533       39 and > 400 get the `bg-limit` style, not the normal one.
//   lib/sandbox.js:248-256        `displayBg` (notifications, Pushover, Alexa, …): 39 → "LOW",
//                                 401 → "HIGH".
//   lib/plugins/errorcodes.js:13-22  values below 39 are Dexcom error codes (1 = ?SN, 9 = ?AD, …).
//   lib/plugins/bgnow.js:95-101   entries below 39 are errors, not glucose.
//
// So Nightscout has a faithful flag encoding: 39 means "below the sensor's range" and 401 means
// "above the sensor's range". Neither is a clamp: the G7's numeric range is 40–400, so 39 and 401
// can never be real measurements, and Nightscout renders them as the words LOW and HIGH rather
// than as numbers. Clamping (which S4 forbids) would be sending 40 or 400, which Nightscout would
// show as an ordinary reading. Follower apps: LoopFollow shows ≤ 39 as "LOW" and ≥ 400 as "HIGH"
// (LoopFollow/Helpers/Globals.swift:16-20, Controllers/Nightscout/BGData.swift:294-297).

import GlucoseCore

public enum NightscoutGlucoseEncoding {
    /// `sgv` value Nightscout renders as LOW (lib/sandbox.js:249-250, lib/client/index.js:544-545).
    public static let lowSGV = 39
    /// `sgv` value Nightscout renders as HIGH (lib/sandbox.js:251-252, lib/client/index.js:546-547).
    public static let highSGV = 401
    /// The sensor's numeric range, inclusive (GlucoseCore `GlucoseValue.sensorReportableRange`).
    public static let numericRange = GlucoseValue.sensorReportableRange

    /// What an `sgv` number from a Nightscout entry means.
    public enum Decoded: Sendable, Equatable {
        case value(GlucoseValue)
        /// Below 39: a Dexcom error code, not glucose (lib/plugins/errorcodes.js:13-22).
        case errorCode(Double)
        /// Not a finite number.
        case invalid
    }

    /// Classifies an `sgv` exactly as Nightscout's own display does (lib/client/index.js:540-549).
    /// Non-integer values inside the numeric range are rounded to the nearest mg/dL, which is also
    /// what Nightscout displays (`scaleBg`); that is a unit representation, not a new value (S1).
    public static func decode(sgv: Double) -> Decoded {
        guard sgv.isFinite else { return .invalid }
        if sgv < Double(lowSGV) { return .errorCode(sgv) }
        if sgv < Double(numericRange.lowerBound) { return .value(.belowRange) }
        if sgv > Double(numericRange.upperBound) { return .value(.aboveRange) }
        return .value(.mgdl(Int(sgv.rounded())))
    }

    /// The `sgv` to upload for a value, or `nil` if the value cannot be represented faithfully.
    ///
    /// `.mgdl` outside 40...400 violates the GlucoseCore contract; sending it would turn a number
    /// into a flag in Nightscout's display (39 → LOW), so it is refused instead (S4).
    public static func sgv(for value: GlucoseValue) -> Int? {
        switch value {
        case .belowRange: return lowSGV
        case .aboveRange: return highSGV
        case .mgdl(let mgdl): return numericRange.contains(mgdl) ? mgdl : nil
        }
    }
}
