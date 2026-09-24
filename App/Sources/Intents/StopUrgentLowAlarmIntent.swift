// The urgent-low system alarm's Stop button (PROGRESS D26, D34; docs/alerts.md §4.4, §9).
//
// AlarmKit runs this intent in the app process when the user taps Stop. It must live in the app
// target: App Intents metadata is extracted from the app's own sources. The system rebuilds the
// intent from its type, so it cannot hold the running AlertService; it reaches it through
// `UrgentLowAlarmIntentBridge.shared`, which `LiveAppServices` connects at bootstrap (taps before
// that are queued, and dropped if older than 60 s). Stop = acknowledge urgent low: snoozed for the
// urgent-low snooze time, which is ≤ 30 minutes by construction (S7).
// Code as given in AlertEngine/Runtime/UrgentLowAlarmIntentBridge.swift.

import AlertEngine
import AppIntents

@available(iOS 26.0, *)
struct StopUrgentLowAlarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop urgent low alarm"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await UrgentLowAlarmIntentBridge.shared.stopTapped()
        return .result()
    }
}
