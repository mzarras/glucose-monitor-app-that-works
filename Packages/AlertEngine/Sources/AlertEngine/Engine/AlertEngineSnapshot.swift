// Everything the engine remembers, as one Codable value the app persists after every input.
//
// Why persist: iOS relaunches the app in the background for BLE events after terminating it
// (state restoration, HANDOFF §4.6). A fresh engine would forget acknowledgements and snoozes and
// sound every active alert again. Loop persists the same thing for the same reason (LoopKit/Loop
// next-dev #2517, "Persist glucose alert episode state across launches").
//
// Decoding is lossy, field by field: a missing, unknown or unreadable field takes its default and
// an episode that cannot be read is dropped, so adding a field in a later build never throws the
// whole state away. Whatever is restored then goes through `AlertEngine.sanitized` (S7 clamp,
// clock-fault repair).

import Foundation
import GlucoseCore

public struct AlertEngineSnapshot: Sendable, Equatable, Codable {
    /// Keyed by `AlertKind.rawValue`; unknown keys are dropped when restoring.
    var episodes: [String: AlertEpisode] = [:]
    /// The newest live, non-backfilled reading. Glucose alerts evaluate only this, and only while
    /// it is current (S1).
    var latestLiveReading: LiveReadingSummary?
    /// The newest valid reading of any kind, backfill included. For notification text only.
    var lastValidReadingDate: Date?
    /// Missed readings fire at `missedReadingsReference + window`: the newest valid reading, or
    /// the moment the engine started or the sensor left warm-up, whichever is latest.
    var missedReadingsReference: Date
    /// First fire time of the missed-readings notifications currently pending, if any.
    var missedReadingsScheduledFrom: Date?
    /// The last sensor state that describes the session (not searching/connecting/Bluetooth).
    var settledSensorState: SensorState?
    /// The last state the CGM source reported, whatever it was.
    var lastReportedSensorState: SensorState?
    var bridgeStatus: TrioBridgeStatus = .off
    /// One-off announcements already made: `AlertKind.rawValue` → the session date announced
    /// (expiry, grace end or warm-up end). At most one entry per announcement kind.
    var announcedSessionDates: [String: Date] = [:]

    init(start: Date) {
        missedReadingsReference = start
    }

    /// Marks a snapshot decoded without a missed-readings reference; `AlertEngine.sanitized`
    /// replaces it with the restore time (the window starts again, as after a launch).
    static let missingReference = Date.distantPast

    private enum CodingKeys: String, CodingKey {
        case episodes, latestLiveReading, lastValidReadingDate, missedReadingsReference
        case missedReadingsScheduledFrom, settledSensorState, lastReportedSensorState, bridgeStatus
        case announcedSessionDates
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var episodes: [String: AlertEpisode] = [:]
        if let stored = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .episodes) {
            for key in stored.allKeys {
                if let episode = try? stored.decode(AlertEpisode.self, forKey: key) {
                    episodes[key.stringValue] = episode
                }
            }
        }
        self.episodes = episodes
        latestLiveReading = (try? c.decodeIfPresent(LiveReadingSummary.self, forKey: .latestLiveReading)) ?? nil
        lastValidReadingDate = (try? c.decodeIfPresent(Date.self, forKey: .lastValidReadingDate)) ?? nil
        missedReadingsReference = (try? c.decodeIfPresent(Date.self, forKey: .missedReadingsReference)) ?? Self.missingReference
        missedReadingsScheduledFrom = (try? c.decodeIfPresent(Date.self, forKey: .missedReadingsScheduledFrom)) ?? nil
        settledSensorState = (try? c.decodeIfPresent(SensorState.self, forKey: .settledSensorState)) ?? nil
        lastReportedSensorState = (try? c.decodeIfPresent(SensorState.self, forKey: .lastReportedSensorState)) ?? nil
        bridgeStatus = (try? c.decodeIfPresent(TrioBridgeStatus.self, forKey: .bridgeStatus)) ?? .off
        announcedSessionDates = (try? c.decodeIfPresent([String: Date].self, forKey: .announcedSessionDates)) ?? [:]
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// `nil` if `data` is missing or not a JSON object; the engine then starts fresh, which can only
    /// make it louder (active alerts sound again), never quieter.
    public static func decode(_ data: Data?) -> AlertEngineSnapshot? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(AlertEngineSnapshot.self, from: data)
    }
}
