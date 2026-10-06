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
    /// DEBUG (audit m9): `latest` came from a replay or mock source, so the widget labels it
    /// "REPLAY" (`WidgetEntryContent.showsReplayMarker`). Those sources are compiled only in DEBUG
    /// (S6) and `make` sets this only in DEBUG, so a Release snapshot always has false. Snapshots
    /// written before this field existed decode as false (additive; same schema version).
    public let isReplay: Bool

    public init(
        writtenAt: Date,
        latest: LatestReading?,
        sensorState: SensorState,
        recent: [ChartPoint],
        accent: AccentChoice,
        isReplay: Bool = false,
        schemaVersion: Int = WidgetSnapshot.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.writtenAt = writtenAt
        self.latest = latest
        self.sensorState = sensorState
        self.recent = recent
        self.accent = accent
        self.isReplay = isReplay
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, writtenAt, latest, sensorState, recent, accent, isReplay
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        writtenAt = try container.decode(Date.self, forKey: .writtenAt)
        latest = try container.decodeIfPresent(LatestReading.self, forKey: .latest)
        sensorState = try container.decode(SensorState.self, forKey: .sensorState)
        recent = try container.decode([ChartPoint].self, forKey: .recent)
        accent = try container.decode(AccentChoice.self, forKey: .accent)
        isReplay = try container.decodeIfPresent(Bool.self, forKey: .isReplay) ?? false
    }

    /// Builds a snapshot from stored readings. Selection only; no value is created (S1).
    ///
    /// - Parameters:
    ///   - latestLive: the repository's `latestLiveReading()` — the current value, its age, delta
    ///     and staleness come from it, however old it is (so an old reading reads "Last reading
    ///     4 h ago", not "no reading"). An imported reading here is ignored (S6).
    ///   - previousLive: the live reading immediately before `latestLive`, for the delta.
    ///   - recent: stored readings covering the last 3 hours, any source (chart only).
    public static func make(
        latestLive: GlucoseReading?,
        previousLive: GlucoseReading?,
        recent: [GlucoseReading],
        sensorState: SensorState,
        accent: AccentChoice,
        now: Date
    ) -> WidgetSnapshot {
        let latest = latestLive.flatMap { $0.source.isImportedHistory ? nil : $0 }
        let previous = previousLive.flatMap { reading -> GlucoseReading? in
            guard !reading.source.isImportedHistory, let latest, reading.date < latest.date else { return nil }
            return reading
        }
        let windowStart = now.addingTimeInterval(-historyWindow)
        let points = recent
            .filter { $0.date >= windowStart && $0.date <= now }
            .sorted { $0.date < $1.date }
            .map(ChartPoint.init)
        return WidgetSnapshot(
            writtenAt: now,
            latest: latest.map { LatestReading(reading: $0, previous: previous) },
            sensorState: sensorState,
            recent: points,
            accent: accent,
            isReplay: latest.map { isReplaySource($0.source) } ?? false
        )
    }

    /// DEBUG (audit m9): a replay or mock reading. Always false in Release, where those sources
    /// don't exist (S6).
    static func isReplaySource(_ source: ReadingSource) -> Bool {
        #if DEBUG
        switch source {
        case .replay, .mock: return true
        case .sensor, .imported: return false
        }
        #else
        return false
        #endif
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
