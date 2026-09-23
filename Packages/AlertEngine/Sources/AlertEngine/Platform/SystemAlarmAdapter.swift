// iOS 26+: SystemAlarmScheduling on top of AlarmKit (PROGRESS.md D26). A field-by-field
// translation; which alarms to schedule, when, and the fallback when this throws are decided (and
// tested) elsewhere.
//
// Written from Loop's CriticalAlertAlarmScheduler (LoopKit/Loop next-dev, MIT,
// Loop/Managers/Alerts/CriticalAlertAlarmScheduler.swift) and the AlarmKit interface in the iOS 26.2
// SDK; no code copied. Differences from Loop: fixed alarm IDs per slot (SystemAlarmIDs) instead of
// a UUID map held in memory, and repeat alarms scheduled ahead, not only the immediate one.
//
// Requirements outside this package (docs/alerts.md §9): `NSAlarmKitUsageDescription` in
// App/Info.plist (present, D26); the app's `StopUrgentLowAlarmIntent` (see
// UrgentLowAlarmIntentBridge.swift), passed in as `makeStopIntent`.
//
// An alert-only alarm (no countdown) needs no widget extension or Live Activity UI (Loop
// CriticalAlertAlarmScheduler.swift:105-108).

#if os(iOS) && canImport(AlarmKit)
import AlarmKit
import AppIntents
import Foundation
import struct SwiftUI.Color

@MainActor
public final class SystemAlarmAdapter: SystemAlarmScheduling {
    private let makeStopIntent: @MainActor () -> (any LiveActivityIntent)?

    /// - Parameter makeStopIntent: returns the app's Stop intent (acknowledges urgent low through
    ///   `UrgentLowAlarmIntentBridge`). `nil` means Stop only silences the alarm; repeats continue.
    public init(makeStopIntent: @escaping @MainActor () -> (any LiveActivityIntent)?) {
        self.makeStopIntent = makeStopIntent
    }

    public var authorization: SystemAlarmAuthorization {
        guard #available(iOS 26.0, *) else { return .unavailable }
        switch AlarmManager.shared.authorizationState {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    public func requestAuthorization() async -> SystemAlarmAuthorization {
        guard #available(iOS 26.0, *) else { return .unavailable }
        if AlarmManager.shared.authorizationState == .notDetermined {
            _ = try? await AlarmManager.shared.requestAuthorization()
        }
        return authorization
    }

    public func schedule(_ request: SystemAlarmRequest) async throws {
        guard #available(iOS 26.0, *) else { throw SystemAlarmError.unavailable }
        let presentation = AlarmPresentation(alert: Self.alert(title: request.title))
        let attributes = AlarmAttributes<UrgentLowAlarmMetadata>(presentation: presentation, tintColor: .red)
        let configuration = AlarmManager.AlarmConfiguration<UrgentLowAlarmMetadata>.alarm(
            schedule: .fixed(request.fireDate),
            attributes: attributes,
            stopIntent: makeStopIntent(),
            // The bundled IMA4 .caf, by file name from the app bundle root (Loop PR #2520).
            sound: .named(request.soundFileName)
        )
        _ = try await AlarmManager.shared.schedule(id: request.id, configuration: configuration)
    }

    public func cancel(ids: [UUID]) {
        guard #available(iOS 26.0, *) else { return }
        for id in ids {
            // stop() ends a ringing alarm, cancel() removes a scheduled one; an alarm can be in
            // either state, so do both and ignore "no such alarm" (Loop :141-151).
            try? AlarmManager.shared.stop(id: id)
            try? AlarmManager.shared.cancel(id: id)
        }
    }

    public func cancelAll() {
        guard #available(iOS 26.0, *) else { return }
        // Reading the list can throw (e.g. not authorized); then there is nothing of ours to cancel.
        cancel(ids: ((try? AlarmManager.shared.alarms) ?? []).map(\.id))
    }

    @available(iOS 26.0, *)
    private static func alert(title: String) -> AlarmPresentation.Alert {
        let text = LocalizedStringResource(stringLiteral: title)
        if #available(iOS 26.1, *) {
            return AlarmPresentation.Alert(title: text)
        }
        // iOS 26.0 requires a stop button in the presentation (deprecated and ignored from 26.1).
        let stop = AlarmButton(text: LocalizedStringResource(stringLiteral: "Stop"), textColor: .white, systemImageName: "stop.circle")
        return AlarmPresentation.Alert(title: text, stopButton: stop)
    }
}

/// Urgent-low alarms carry no metadata.
@available(iOS 26.0, *)
struct UrgentLowAlarmMetadata: AlarmMetadata {}
#endif
