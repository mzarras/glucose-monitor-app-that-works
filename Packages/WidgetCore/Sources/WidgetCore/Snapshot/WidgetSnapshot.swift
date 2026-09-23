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

    /// Builds a snapshot from stored readings. Selection only: the latest live reading, the live
    /// reading before it (for the delta), and the readings inside the 3-hour window. No value is
    /// created (S1).
    ///
    /// The current value, its age, delta and staleness come from live readings only; imported
    /// history may appear in the chart but is never the current value (S6, repository contract
    /// `latestLiveReading()`).
    ///
    /// - Parameter readings: stored readings, any order, covering at least the last 3 hours.
    public static func make(
        readings: [GlucoseReading],
        sensorState: SensorState,
        accent: AccentChoice,
        now: Date
    ) -> WidgetSnapshot {
        let ordered = readings.sorted { $0.date < $1.date }
        let live = ordered.filter { !$0.source.isImportedHistory }
        let latestLive = live.last
        let previousLive = live.count >= 2 ? live[live.count - 2] : nil
        let windowStart = now.addingTimeInterval(-historyWindow)
        let recent = ordered
            .filter { $0.date >= windowStart && $0.date <= now }
            .map(ChartPoint.init)
        return WidgetSnapshot(
            writtenAt: now,
            latest: latestLive.map { LatestReading(reading: $0, previous: previousLive) },
            sensorState: sensorState,
            recent: recent,
            accent: accent
        )
    }
}

extension ReadingSource {
    /// True for history imported from Nightscout or a Clarity export (HANDOFF §4.5). Such readings
    /// feed charts and statistics only; they are never the current value (S6).
    public var isImportedHistory: Bool {
        if case .imported = self { return true }
        return false
    }
}
