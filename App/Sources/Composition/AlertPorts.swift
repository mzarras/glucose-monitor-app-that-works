// The alert engine's delivery ports and how the app builds an `AlertService` on them
// (docs/alerts.md §9). The app has exactly one AlertService at a time: the production one, or —
// during a DEBUG replay run — a replay one that accepts replay readings (PROGRESS D11) and persists
// nothing. Both use these same ports (one notification center adapter, one audio player, one
// AlarmKit adapter per process).

import AlertEngine
import Foundation
import GlucoseCore

@MainActor
struct AlertPorts {
    let notificationCenter: any AlertNotificationCenter
    let audio: any AlertAudioPlaying
    /// AlarmKit (iOS 26+) for urgent low (D26); nil uses the D17 path only.
    let alarms: (any SystemAlarmScheduling)?
    /// Calendar and locale for quiet hours and notification text (the phone's by default).
    let configuration: AlertEngineConfiguration
    let diagnostics: any DiagnosticLog

    /// The production service: restores the persisted engine snapshot and persists every new one
    /// (acknowledgements and snoozes survive a relaunch). Call `start()` on it.
    func makeProductionService(settings: AlertSettings, snapshot: AlertEngineSnapshot?, clock: any AlertClock,
                               onSnapshot: @escaping @MainActor (AlertEngineSnapshot) -> Void) -> AlertService {
        AlertService(
            settings: settings, restoring: snapshot, configuration: configuration, clock: clock,
            notificationCenter: notificationCenter, audio: audio, systemAlarms: alarms, diagnostics: diagnostics,
            onSnapshot: onSnapshot
        )
    }

    #if DEBUG
    /// DEBUG replay run (D11): accepts `.replay` readings; starts from a fresh engine and persists
    /// nothing, so a replay never changes the production alert state.
    func makeReplayService(settings: AlertSettings, clock: any AlertClock) -> AlertService {
        var replayConfiguration = configuration
        replayConfiguration.acceptsReplayReadings = true
        return AlertService(
            settings: settings, restoring: nil, configuration: replayConfiguration, clock: clock,
            notificationCenter: notificationCenter, audio: audio, systemAlarms: alarms, diagnostics: diagnostics
        )
    }
    #endif
}
