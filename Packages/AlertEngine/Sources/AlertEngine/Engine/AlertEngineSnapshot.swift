// Everything the engine remembers, as one Codable value the app persists after every input.
//
// Why persist: iOS relaunches the app in the background for BLE events after terminating it
// (state restoration, HANDOFF §4.6). A fresh engine would forget acknowledgements and snoozes and
// sound every active alert again. Loop persists the same thing for the same reason (LoopKit/Loop
// next-dev #2517, "Persist glucose alert episode state across launches").

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
    /// One-off announcements already made, as "<kind>@<epoch seconds of the session date>".
    var announcedEvents: [String] = []

    init(start: Date) {
        missedReadingsReference = start
    }

    /// Keep the announcement memory small; a session produces at most four.
    static let announcedEventsLimit = 32

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// `nil` if `data` is missing or unreadable; the engine then starts fresh, which can only make
    /// it louder (active alerts sound again), never quieter.
    public static func decode(_ data: Data?) -> AlertEngineSnapshot? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(AlertEngineSnapshot.self, from: data)
    }
}
