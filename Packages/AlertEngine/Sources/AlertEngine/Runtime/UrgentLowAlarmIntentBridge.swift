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
// A queued tap older than `maximumQueuedAge` (60 s) is dropped on connection: delivered late it
// could acknowledge a newer urgent-low episode the user never saw (safety review WS4 minor).
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

    /// A queued tap older than this when the service connects is dropped.
    public static let maximumQueuedAge: TimeInterval = 60

    private let clock: AlertClock
    private var handler: Handler?
    private var queued: [(action: AlertUserAction, at: Date)] = []

    /// Separate instances (with a test clock) are for tests; the app uses `shared`.
    public init(clock: AlertClock = SystemAlertClock()) {
        self.clock = clock
    }

    /// Connects the bridge to the running service, e.g.
    /// `await UrgentLowAlarmIntentBridge.shared.connect { await service.send(.user($0)) }`.
    /// Delivers the taps that arrived before, if they are recent enough.
    public func connect(_ handler: @escaping Handler) async {
        self.handler = handler
        let pending = queued
        queued = []
        for entry in pending where clock.now.timeIntervalSince(entry.at) <= Self.maximumQueuedAge {
            await handler(entry.action)
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
            queued.append((action, clock.now))
            return
        }
        await handler(action)
    }
}
