// Carries out the engine's actions with the notification center and the audio player, applying
// DeliveryPolicy to each alert. Holds no alert logic of its own.

import Foundation
import GlucoseCore

@MainActor
public final class AlertDeliveryExecutor {
    private let center: AlertNotificationCenter
    private let audio: AlertAudioPlaying
    private let diagnostics: DiagnosticLog
    private let clock: AlertClock

    /// From the last permission check (D4). Decides Critical vs Time Sensitive for alerts with
    /// "Sound on silent" on.
    public var criticalAlertsEnabled = false
    /// The alert whose sound the in-app player is playing, if any. A less important alert never
    /// cuts off a more important one (urgent low is never interrupted).
    public private(set) var soundOwner: AlertKind?

    public init(center: AlertNotificationCenter, audio: AlertAudioPlaying, diagnostics: DiagnosticLog, clock: AlertClock) {
        self.center = center
        self.audio = audio
        self.diagnostics = diagnostics
        self.clock = clock
    }

    public func execute(_ actions: [AlertAction]) async {
        for action in actions {
            await execute(action)
        }
    }

    private func execute(_ action: AlertAction) async {
        switch action {
        case .fire(let notice):
            let decision = DeliveryPolicy.decide(for: notice, criticalAlertsEnabled: criticalAlertsEnabled, timing: .now)
            log("fire \(notice.kind.rawValue): \(Self.describe(decision))")
            if let sound = decision.inAppSound {
                playInApp(sound, for: notice.kind)
            }
            await add(NotificationRequestBuilder.request(for: notice, decision: decision, slot: nil))

        case .playDueAlert(let notice):
            let decision = DeliveryPolicy.decide(for: notice, criticalAlertsEnabled: criticalAlertsEnabled, timing: .now)
            log("due \(notice.kind.rawValue): \(decision.inAppSound == nil ? "notification only" : "in-app sound")")
            if let sound = decision.inAppSound {
                playInApp(sound, for: notice.kind)
            }

        case .schedule(let kind, let notices):
            center.removePending(identifiers: AlertNotificationIDs.allScheduled(kind))
            let first = notices.first?.fireDate.map { "\($0)" } ?? "-"
            log("schedule \(kind.rawValue): \(notices.count) pending from \(first)")
            for (slot, notice) in notices.enumerated() {
                let decision = DeliveryPolicy.decide(for: notice, criticalAlertsEnabled: criticalAlertsEnabled, timing: .scheduled)
                await add(NotificationRequestBuilder.request(for: notice, decision: decision, slot: slot))
            }

        case .cancelScheduled(let kind):
            log("cancel pending \(kind.rawValue)")
            center.removePending(identifiers: AlertNotificationIDs.allScheduled(kind))

        case .cancel(let kind):
            log("cancel \(kind.rawValue)")
            let identifiers = AlertNotificationIDs.all(kind)
            center.removePending(identifiers: identifiers)
            center.removeDelivered(identifiers: identifiers)
            stopInApp(for: kind)

        case .stopSound(let kind):
            log("stop sound \(kind.rawValue)")
            stopInApp(for: kind)

        case .readingRejected(let id, let reason):
            log("reading \(id) refused: \(reason)")

        case .userActionIgnored(let userAction):
            log("ignored \(userAction): alert not active")
        }
    }

    /// Plays a sound for the Alerts screen's preview button. Never interrupts an alert's sound.
    public func preview(_ sound: AlertSoundID) -> Bool {
        if soundOwner != nil, audio.isPlaying { return false }
        soundOwner = nil
        return audio.play(fileName: AlertSoundCatalog.fileName(sound), loopSeconds: 0)
    }

    public func stopPreview() {
        guard soundOwner == nil || !audio.isPlaying else { return }
        audio.stop()
    }

    private func playInApp(_ sound: InAppSound, for kind: AlertKind) {
        if let owner = soundOwner, audio.isPlaying, owner.priority < kind.priority {
            log("in-app sound kept for \(owner.rawValue); \(kind.rawValue) not played")
            return
        }
        if audio.play(fileName: sound.fileName, loopSeconds: sound.loopSeconds) {
            soundOwner = kind
        } else {
            soundOwner = nil
            log("in-app sound FAILED to start for \(kind.rawValue) (\(sound.fileName))")
        }
    }

    private func stopInApp(for kind: AlertKind) {
        guard soundOwner == kind else { return }
        audio.stop()
        soundOwner = nil
    }

    private func add(_ request: NotificationRequestSpec) async {
        do {
            try await center.add(request)
        } catch {
            log("notification \(request.identifier) FAILED: \(error)")
        }
    }

    private func log(_ message: String) {
        diagnostics.record(DiagnosticEvent(date: clock.now, category: .alert, message: message))
    }

    static func describe(_ decision: DeliveryDecision) -> String {
        let level: String
        switch decision.interruption {
        case .passive: level = "passive (quiet hours)"
        case .timeSensitive: level = "time-sensitive"
        case .critical: level = "critical"
        }
        return decision.inAppSound == nil ? level : level + " + in-app sound"
    }
}
