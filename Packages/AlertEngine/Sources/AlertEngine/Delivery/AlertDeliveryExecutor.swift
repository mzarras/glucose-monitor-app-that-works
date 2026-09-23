// Carries out the engine's actions with the notification center, the audio player and (iOS 26+)
// system alarms, applying DeliveryPolicy to each alert. Holds no alert logic of its own.

import Foundation
import GlucoseCore

@MainActor
public final class AlertDeliveryExecutor {
    private let center: AlertNotificationCenter
    private let audio: AlertAudioPlaying
    private let alarms: SystemAlarmScheduling?
    private let diagnostics: DiagnosticLog
    private let clock: AlertClock

    /// From the last permission check (D4). Decides Critical vs Time Sensitive for alerts with
    /// "Sound on silent" on.
    public var criticalAlertsEnabled = false
    /// The alert whose sound the in-app player is playing, if any. A less important alert never
    /// cuts off a more important one (urgent low is never interrupted).
    public private(set) var soundOwner: AlertKind?
    /// Set when scheduling an urgent-low system alarm failed in the last attempt (S5: shown on the
    /// Settings screen); cleared when a later attempt succeeds in full.
    public private(set) var urgentLowAlarmFailure: String?

    public init(
        center: AlertNotificationCenter, audio: AlertAudioPlaying, alarms: SystemAlarmScheduling? = nil,
        diagnostics: DiagnosticLog, clock: AlertClock
    ) {
        self.center = center
        self.audio = audio
        self.alarms = alarms
        self.diagnostics = diagnostics
        self.clock = clock
    }

    /// Read at execution time, so a permission change takes effect at once.
    public var systemAlarmsAvailable: Bool {
        alarms?.authorization == .authorized
    }

    public func execute(_ actions: [AlertAction]) async {
        for action in actions {
            await execute(action)
        }
    }

    private func decide(_ notice: AlertNotice, _ timing: DeliveryTiming, alarmsAvailable: Bool? = nil) -> DeliveryDecision {
        DeliveryPolicy.decide(
            for: notice, criticalAlertsEnabled: criticalAlertsEnabled,
            systemAlarmsAvailable: alarmsAvailable ?? systemAlarmsAvailable, timing: timing
        )
    }

    private func execute(_ action: AlertAction) async {
        switch action {
        case .fire(let notice):
            var decision = decide(notice, .now)
            if let alarmSound = decision.systemAlarmSoundFileName {
                let ok = await scheduleAlarm(id: SystemAlarmIDs.immediate, at: clock.now, notice: notice, soundFileName: alarmSound)
                recordAlarmOutcome(allSucceeded: ok)
                if !ok {
                    // Fall back to the D17 path now: notification sound + in-app sound.
                    decision = decide(notice, .now, alarmsAvailable: false)
                }
            }
            log("fire \(notice.kind.rawValue): \(Self.describe(decision))")
            if let sound = decision.inAppSound {
                playInApp(sound, for: notice.kind)
            }
            await add(NotificationRequestBuilder.request(for: notice, decision: decision, slot: nil))

        case .playDueAlert(let notice):
            let decision = decide(notice, .now)
            log("due \(notice.kind.rawValue): \(decision.inAppSound == nil ? "notification or alarm only" : "in-app sound")")
            if let sound = decision.inAppSound {
                playInApp(sound, for: notice.kind)
            }

        case .schedule(let kind, let notices):
            center.removePending(identifiers: AlertNotificationIDs.allScheduled(kind))
            if kind == .urgentLow {
                // Only the repeats: the immediate alarm (slot 0) may be about to ring.
                alarms?.cancel(ids: SystemAlarmIDs.allRepeats)
            }
            let first = notices.first?.fireDate.map { "\($0)" } ?? "-"
            log("schedule \(kind.rawValue): \(notices.count) pending from \(first)")
            var alarmsOK = true
            var triedAlarms = false
            for (slot, notice) in notices.enumerated() {
                let decision = decide(notice, .scheduled)
                if let alarmSound = decision.systemAlarmSoundFileName, let fireDate = notice.fireDate {
                    triedAlarms = true
                    let ok = await scheduleAlarm(id: SystemAlarmIDs.repeatSlot(slot), at: fireDate, notice: notice, soundFileName: alarmSound)
                    alarmsOK = alarmsOK && ok
                }
                // The notification is posted either way: it is the visual, and the fallback sound.
                await add(NotificationRequestBuilder.request(for: notice, decision: decision, slot: slot))
            }
            if triedAlarms { recordAlarmOutcome(allSucceeded: alarmsOK) }

        case .cancelScheduled(let kind):
            log("cancel pending \(kind.rawValue)")
            center.removePending(identifiers: AlertNotificationIDs.allScheduled(kind))
            if kind == .urgentLow { alarms?.cancelAll() }

        case .cancel(let kind):
            log("cancel \(kind.rawValue)")
            let identifiers = AlertNotificationIDs.all(kind)
            center.removePending(identifiers: identifiers)
            center.removeDelivered(identifiers: identifiers)
            if kind == .urgentLow { alarms?.cancelAll() }
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

    private func scheduleAlarm(id: UUID, at date: Date, notice: AlertNotice, soundFileName: String) async -> Bool {
        guard let alarms else { return false }
        let fireDate = max(date, clock.now.addingTimeInterval(SystemAlarmIDs.minimumLeadTime))
        do {
            try await alarms.schedule(SystemAlarmRequest(id: id, fireDate: fireDate, title: notice.title, soundFileName: soundFileName))
            return true
        } catch {
            urgentLowAlarmFailure = String(describing: error)
            log("urgent-low alarm \(id) FAILED: \(error); notification + in-app sound instead")
            return false
        }
    }

    private func recordAlarmOutcome(allSucceeded: Bool) {
        if allSucceeded { urgentLowAlarmFailure = nil }
    }

    private func playInApp(_ sound: InAppSound, for kind: AlertKind) {
        if let owner = soundOwner, audio.isPlaying, owner.priority < kind.priority {
            log("in-app sound kept for \(owner.rawValue); \(kind.rawValue) not played")
            return
        }
        if audio.play(fileName: sound.fileName, loopSeconds: sound.loopSeconds) {
            soundOwner = kind
            // Read after the session is active: before activation the value can be stale.
            let volume = audio.outputVolume.map { String(format: "%.2f", $0) } ?? "unknown"
            log("in-app sound playing for \(kind.rawValue) at media volume \(volume)")
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
        var parts = [level]
        if decision.systemAlarmSoundFileName != nil { parts.append("system alarm") }
        if decision.inAppSound != nil { parts.append("in-app sound") }
        return parts.joined(separator: " + ")
    }
}
