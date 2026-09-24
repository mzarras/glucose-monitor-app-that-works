// HANDOFF §4.6: iOS does not relaunch an app the user force-quit, so readings stop silently until
// it is opened again. The app persists a heartbeat (the last pipeline activity and whether the
// sensor was delivering then); at launch a long silence is reported as a force-quit gap.
//
// Heuristic, deliberately conservative:
// - only when the sensor was active (active or grace period) at the last activity — readings were
//   due every 5 minutes, and each wakes the app;
// - only within the same boot (a restart also silences the app; that is not a force-quit);
// - only when this launch is not a Bluetooth state-restoration relaunch (iOS relaunches only apps
//   that were not force-quit, so such a launch proves the opposite);
// - only when the silence lasted at least 15 minutes (three missed readings; a suspended app is
//   woken every ~5 min, and an app iOS terminated is relaunched at the next sensor event).
// Pure logic; `LiveAppServices` persists the heartbeat.

import Foundation
import GlucoseCore

struct PipelineHeartbeat: Sendable, Equatable, Codable {
    /// Last time the pipeline processed an event or the app was running in the foreground.
    var at: Date
    /// The sensor was delivering readings then (active or grace period).
    var sensorWasActive: Bool
    /// `kern.bootsessionuuid` then, nil if unknown.
    var boot: String?
}

enum ForceQuitGapDetector {
    static let minimumGap: TimeInterval = 15 * 60

    /// Whether `state` means readings are due every ~5 minutes.
    static func sensorIsActive(_ state: SensorState?) -> Bool {
        switch state {
        case .active, .gracePeriod: return true
        default: return false
        }
    }

    /// The gap to report at this launch, or nil.
    static func gap(lastHeartbeat: PipelineHeartbeat?, launchedByBluetoothRestoration: Bool, now: Date, boot: String?) -> ForceQuitGapReport? {
        guard !launchedByBluetoothRestoration,
              let heartbeat = lastHeartbeat, heartbeat.sensorWasActive,
              let boot, heartbeat.boot == boot,
              now.timeIntervalSince(heartbeat.at) >= minimumGap
        else { return nil }
        return ForceQuitGapReport(from: heartbeat.at, to: now)
    }
}
