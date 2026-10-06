// The latest reading as the UI shows it: the sensor's value and reported trend, plus the change
// from the reading before it. Built only from real readings (S1); nothing here estimates a value.

import Foundation
import GlucoseCore

public struct LatestReading: Sendable, Equatable, Hashable, Codable {
    /// Sensor-derived time of the reading (S3).
    public let date: Date
    /// Exactly as reported, flags included (S4).
    public let value: GlucoseValue
    /// From the sensor-reported rate via `TrendArrow(rate:)` (HANDOFF §7.5); never re-derived.
    public let trend: TrendArrow
    /// Change since the previous reading, or `nil` when it cannot be stated honestly.
    public let delta: GlucoseDelta?

    public init(date: Date, value: GlucoseValue, trend: TrendArrow, delta: GlucoseDelta?) {
        self.date = date
        self.value = value
        self.trend = trend
        self.delta = delta
    }

    /// - Parameters:
    ///   - reading: the newest stored reading.
    ///   - previous: the stored reading immediately before it in time, if any.
    public init(reading: GlucoseReading, previous: GlucoseReading?) {
        self.init(
            date: reading.date,
            value: reading.value,
            trend: TrendArrow(rate: reading.trendRate),
            delta: previous.flatMap { GlucoseDelta.between(latest: reading, previous: $0) }
        )
    }
}

/// "−3 in 5 min": the difference between two real, numeric, consecutive readings.
public struct GlucoseDelta: Sendable, Equatable, Hashable, Codable {
    /// Latest minus previous, mg/dL.
    public let mgdl: Int
    /// The real interval between the two readings, rounded to whole minutes (≥ 1).
    public let minutes: Int

    public init(mgdl: Int, minutes: Int) {
        self.mgdl = mgdl
        self.minutes = minutes
    }

    /// No delta across an interval longer than this. Same limit as the chart's line break
    /// (HANDOFF §7.5: gaps > 15 min), so a delta never spans a gap the chart shows as broken.
    public static let maxInterval: TimeInterval = 15 * 60

    /// `nil` when either reading is a LOW/HIGH flag (a flag has no number to subtract, S4), when
    /// the readings are out of order or simultaneous, or when they are more than 15 min apart.
    public static func between(latest: GlucoseReading, previous: GlucoseReading) -> GlucoseDelta? {
        between(latestDate: latest.date, latestValue: latest.value, previousDate: previous.date, previousValue: previous.value)
    }

    public static func between(
        latestDate: Date, latestValue: GlucoseValue,
        previousDate: Date, previousValue: GlucoseValue
    ) -> GlucoseDelta? {
        guard let now = latestValue.numericMgdl, let before = previousValue.numericMgdl else { return nil }
        let interval = latestDate.timeIntervalSince(previousDate)
        guard interval > 0, interval <= maxInterval else { return nil }
        let minutes = max(1, Int((interval / 60).rounded()))
        return GlucoseDelta(mgdl: now - before, minutes: minutes)
    }
}
