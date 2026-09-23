// Routes the urgent-low system alarm's Stop (and optional Snooze) button to the alert engine.
//
// AlarmKit runs the alarm's `stopIntent` (a `LiveActivityIntent`) in the app process when the user
// taps Stop. The system rebuilds the intent from its type, so the intent cannot hold a reference to
// the running AlertService; it reaches it through this shared bridge instead. Taps that arrive
// before the service is connected (the system launched the app to run the intent) are queued and
// delivered on connection. Same design as Loop's CriticalAlertAcknowledgementBridge
// (Loop/Managers/Alerts/CriticalAlertAlarmScheduler.swift:155-185).
//
// Stop = acknowledge urgent low: the engine snoozes it for the configured urgent-low snooze,
// which is ≤ 30 minutes by construction (S7). Snooze(minutes) is clamped by the engine to ≤ 30.
//
// The intent type itself lives in the APP target (docs/alerts.md §9), because App Intents
// metadata is extracted from the app's own sources:
//
//     @available(iOS 26.0, *)
//     struct StopUrgentLowAlarmIntent: LiveActivityIntent {
//         static let title: LocalizedStringResource = "Stop urgent low alarm"
//         static let isDiscoverable = false
//         func perform() async throws -> some IntentResult {
//             await UrgentLowAlarmIntentBridge.shared.stopTapped()
//             return .result()
//         }
//     }

import Foundation

@MainActor
public final class UrgentLowAlarmIntentBridge {
    /// The instance the app's intent calls.
    public static let shared = UrgentLowAlarmIntentBridge()

    public typealias Handler = @MainActor (AlertUserAction) async -> Void

    private var handler: Handler?
    private var queued: [AlertUserAction] = []

    /// Separate instances are for tests; the app uses `shared`.
    public init() {}

    /// Connects the bridge to the running service, e.g.
    /// `await UrgentLowAlarmIntentBridge.shared.connect { await service.send(.user($0)) }`.
    /// Delivers any taps that arrived before.
    public func connect(_ handler: @escaping Handler) async {
        self.handler = handler
        let pending = queued
        queued = []
        for action in pending {
            await handler(action)
        }
    }

    /// The alarm's Stop button: acknowledge urgent low (snooze ≤ 30 minutes, S7).
    public func stopTapped() async {
        await deliver(.acknowledge(.urgentLow))
    }

    /// A Snooze button, if the app adds one to the alarm: the engine clamps to ≤ 30 minutes (S7).
    public func snoozeTapped(minutes: Int) async {
        await deliver(.snooze(.urgentLow, minutes: minutes))
    }

    private func deliver(_ action: AlertUserAction) async {
        guard let handler else {
            queued.append(action)
            return
        }
        await handler(action)
    }
}
