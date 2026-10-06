// Records, minute by minute, which alerts the engine has firing — the "alert fires when and only
// when" record for ReplayScenarioTests. This file imports AlertEngine but not the app module, so
// `AlertKind` here is AlertEngine's (the app declares its own `AlertKind` for the Alerts screen).

import AlertEngine
import Foundation

@MainActor
final class AlertPhaseRecorder {
    /// Every alert kind's raw value ("urgentLow", "missedReadings", …).
    static let allKinds: [String] = AlertKind.allCases.map(\.rawValue)

    /// For each kind, the start (`since`) of every firing episode seen, in order.
    private(set) var episodeStarts: [String: [Date]] = [:]
    /// For each kind, the scenario offsets (seconds) at which it was seen firing.
    private(set) var firingOffsets: [String: [TimeInterval]] = [:]
    /// For each kind, the scenario offsets at which it was seen snoozed.
    private(set) var snoozedOffsets: [String: [TimeInterval]] = [:]

    func record(_ service: AlertService, offset: TimeInterval) {
        for kind in AlertKind.allCases {
            switch service.phase(of: kind) {
            case .firing(let since):
                firingOffsets[kind.rawValue, default: []].append(offset)
                if episodeStarts[kind.rawValue]?.last != since {
                    episodeStarts[kind.rawValue, default: []].append(since)
                }
            case .snoozed:
                snoozedOffsets[kind.rawValue, default: []].append(offset)
            case .off, .armed, .pending:
                break
            }
        }
    }

    func isFiring(_ kind: String, at offset: TimeInterval) -> Bool {
        firingOffsets[kind]?.contains(offset) ?? false
    }

    /// Kinds that were ever firing.
    var kindsThatFired: Set<String> {
        Set(firingOffsets.keys)
    }

    /// Default settings plus the two rate alerts switched on, so "rise/fall fires only at ≥ 3 mg/dL/min"
    /// is exercised by every scenario.
    static var settingsWithRateAlerts: AlertSettings {
        var settings = AlertSettings.defaults
        settings.fallingFast.isEnabled = true
        settings.risingFast.isEnabled = true
        return settings
    }

    /// Acknowledges urgent low (the alarm's Stop / the notification's Acknowledge).
    static func acknowledgeUrgentLow(_ service: AlertService) async {
        await service.send(.user(.acknowledge(.urgentLow)))
    }
}
