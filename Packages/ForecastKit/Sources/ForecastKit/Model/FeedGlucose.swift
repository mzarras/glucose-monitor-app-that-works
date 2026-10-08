// Original to Sensor (no ported code).
// The feed's own newest CGM value (`bg` in latest.json). Informational only (D57): the app's live
// reading is the current value; this tells the user which reading the feed had seen.
//
// Source of the number: publish.py `_current_bg` publishes `int(newest["sgv"])` from Nightscout.
// Nightscout's `sgv` encodes the sensor's flags as numbers (cgm-remote-monitor 15.0.8 lib/sandbox.js
// 248-256, lib/client/index.js:540-549, lib/plugins/errorcodes.js:13-22): 39 means LOW, above 400
// means HIGH, below 39 is a Dexcom error code. This app uploads LOW as 39 and HIGH as 401
// (NightscoutKit NightscoutGlucoseEncoding.swift, PROGRESS D29). S4: those numbers must stay flags,
// so they are classified here and never exposed as a plain mg/dL value.

import Foundation

/// What the feed's `bg.mg_dl` number means.
public enum FeedGlucoseValue: Sendable, Equatable {
    /// A numeric value inside the sensor's range, 40…400 mg/dL.
    case mgdl(Int)
    /// 39 (or anything from 39 up to 40): below the sensor's range, LOW. Not the number 39.
    case belowRange
    /// Above 400: above the sensor's range, HIGH. Not a number.
    case aboveRange
    /// 0…38: a Dexcom error code stored as an entry, not glucose.
    case notGlucose(code: Int)

    /// Nightscout's LOW `sgv` (lib/sandbox.js:249-250).
    static let lowSGV: Double = 39
    /// The sensor's numeric range (G7: 40–400 mg/dL; GlucoseCore `GlucoseValue.sensorReportableRange`).
    static let numericRange: ClosedRange<Double> = 40...400

    /// Classifies a published `mg_dl` the way Nightscout's display does (lib/client/index.js:540-549).
    /// The caller has already checked `ForecastLimits.plausibleFeedGlucose`.
    static func classify(_ sgv: Double) -> FeedGlucoseValue {
        if sgv < lowSGV { return .notGlucose(code: Int(sgv)) }
        if sgv < numericRange.lowerBound { return .belowRange }
        if sgv > numericRange.upperBound { return .aboveRange }
        return .mgdl(Int(sgv.rounded()))
    }
}

/// The newest CGM reading the feed had when it was published.
public struct FeedGlucose: Sendable, Equatable {
    /// The reading's timestamp (`bg.ts`).
    public let date: Date
    public let value: FeedGlucoseValue
    /// Nightscout's direction string as published ("Flat", "SingleDown", …), or nil.
    public let trend: String?

    init(date: Date, value: FeedGlucoseValue, trend: String?) {
        self.date = date
        self.value = value
        self.trend = trend
    }
}
