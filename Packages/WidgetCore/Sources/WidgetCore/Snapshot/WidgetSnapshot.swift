// What the app hands the widget (HANDOFF §7.4): latest reading, trend, delta, sensor state, the
// last 3 hours of readings, and when it was written. The app builds it from stored readings; the
// widget only displays it and never computes or guesses a value (S1).
//
// Format: JSON, dates as milliseconds since 1970 (see WidgetSnapshotStore). Documented in
// docs/widgets.md. Bump `currentSchemaVersion` on any incompatible change.

import Foundation
import GlucoseCore

public struct WidgetSnapshot: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 1

    /// How much history the widget charts (HANDOFF §7.4: "last 3 h of readings").
    public static let historyWindow: TimeInterval = 3 * 60 * 60

    public let schemaVersion: Int
    /// When the app wrote this snapshot ("last-updated time").
    public let writtenAt: Date
    /// The newest stored reading, or `nil` if there is none.
    public let latest: LatestReading?
    /// The CGM source's state when the snapshot was written.
    public let sensorState: SensorState
    /// Readings from the last 3 hours before `writtenAt`, ascending by date. Real readings only.
    public let recent: [ChartPoint]
    /// The accent the user picked, so the widget matches the app.
    public let accent: AccentChoice

    public init(
        writtenAt: Date,
        latest: LatestReading?,
        sensorState: SensorState,
        recent: [ChartPoint],
        accent: AccentChoice,
        schemaVersion: Int = WidgetSnapshot.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.writtenAt = writtenAt
        self.latest = latest
        self.sensorState = sensorState
        self.recent = recent
        self.accent = accent
    }

    /// Builds a snapshot from stored readings. Selection only: the latest reading, the one before
    /// it (for the delta), and the readings inside the 3-hour window. No value is created.
    ///
    /// - Parameter readings: stored readings, any order, covering at least the last 3 hours.
    public static func make(
        readings: [GlucoseReading],
        sensorState: SensorState,
        accent: AccentChoice,
        now: Date
    ) -> WidgetSnapshot {
        let ordered = readings.sorted { $0.date < $1.date }
        let latestReading = ordered.last
        let previousReading = ordered.count >= 2 ? ordered[ordered.count - 2] : nil
        let windowStart = now.addingTimeInterval(-historyWindow)
        let recent = ordered
            .filter { $0.date >= windowStart && $0.date <= now }
            .map(ChartPoint.init)
        return WidgetSnapshot(
            writtenAt: now,
            latest: latestReading.map { LatestReading(reading: $0, previous: previousReading) },
            sensorState: sensorState,
            recent: recent,
            accent: accent
        )
    }
}
