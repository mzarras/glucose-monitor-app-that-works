// Original to Sensor (no ported code).

import Foundation

/// One current-glucose report from the sensor, as `G7ReadingPipeline` needs it. Two wire forms
/// produce it: the `0x4E` response (primary mode's own GetData, or the Dexcom app's GetData observed
/// in listen mode) and, in listen mode only, the observed coexistence pair `0x31` glucose + `0x25`
/// transmitter time (`G7ObservedGlucosePair`). Both are reduced to the same sensor-time quantities,
/// so every S1-S4 rule in the pipeline applies to both unchanged.
protocol G7GlucoseReport {
    /// Non-zero: a status reply that may carry an old cached value; never published or anchored.
    var responseStatus: UInt8 { get }
    /// The sensor's session clock when the report was sent: seconds since the session started.
    var sensorClock: UInt32 { get }
    /// Seconds between the reading and the report (for the log).
    var readingAge: UInt32 { get }
    /// The reading's own time in seconds since the session started, or nil when impossible.
    var readingSensorTimestamp: UInt32? { get }
    /// The 16-bit glucose field exactly as sent, classified by `G7GlucoseRange` (S4, D31).
    var glucoseField: UInt16 { get }
    var algorithmState: G7AlgorithmState { get }
    /// mg/dL per minute, or nil when the sensor reported none.
    var trendRate: Double? { get }
    /// A value shown because of a calibration: never a reading (S1).
    var isDisplayOnly: Bool { get }
}

extension G7GlucoseMessage: G7GlucoseReport {
    var readingAge: UInt32 { UInt32(age) }
}
