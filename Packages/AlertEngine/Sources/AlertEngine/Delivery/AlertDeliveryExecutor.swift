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
    /// Alerts whose last plan could not schedule every repeat, with how many are missing (S5).
    /// Cleared by the next `.schedule` or cancel for that alert.
    public private(set) var repeatShortfalls: [AlertKind: Int] = [:]

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
            await add(NotificationRequestBuilder.request(for: notice, decision: decision))

        case .playDueAlert(let notice):
            var decision = decide(notice, .now)
            if decision.systemAlarmSoundFileName != nil, !dueAlarmIsPresent(notice) {
                // Belt and braces (safety review WS4 B2): the alarm for this repeat is not there to
                // ring (removed, never scheduled, or the system cannot say), so play the sound here.
                decision = decide(notice, .now, alarmsAvailable: false)
                log("due \(notice.kind.rawValue): its alarm is missing; in-app sound instead")
            }
            log("due \(notice.kind.rawValue): \(decision.inAppSound == nil ? "notification or alarm only" : "in-app sound")")
            if let sound = decision.inAppSound {
                playInApp(sound, for: notice.kind)
            }

        case .schedule(let kind, let notices):
            // Adds (or replaces) exactly these slots. Nothing else is removed: the engine never
            // names a slot that is due within a minute, so no due or ringing repeat is touched.
            let first = notices.first?.fireDate.map { "\($0)" } ?? "-"
            log("schedule \(kind.rawValue): \(notices.count) pending from \(first)")
            repeatShortfalls[kind] = nil
            var alarmsOK = true
            var triedAlarms = false
            for notice in notices {
                let decision = decide(notice, .scheduled)
                if let alarmSound = decision.systemAlarmSoundFileName, let fireDate = notice.fireDate, let slot = notice.slot {
                    triedAlarms = true
                    let ok = await scheduleAlarm(id: SystemAlarmIDs.repeatSlot(slot), at: fireDate, notice: notice, soundFileName: alarmSound)
                    alarmsOK = alarmsOK && ok
                }
                // The notification is posted either way: it is the visual, and the fallback sound.
                await add(NotificationRequestBuilder.request(for: notice, decision: decision))
            }
            if triedAlarms { recordAlarmOutcome(allSucceeded: alarmsOK) }

        case .cancelSlots(let kind, let slots):
            log("cancel \(slots.count) pending \(kind.rawValue)")
            center.removePending(identifiers: slots.map { AlertNotificationIDs.scheduled(kind, slot: $0) })
            if kind == .urgentLow { alarms?.cancel(ids: slots.map(SystemAlarmIDs.repeatSlot)) }

        case .cancelScheduled(let kind):
            log("cancel all pending \(kind.rawValue)")
            repeatShortfalls[kind] = nil
            center.removePending(identifiers: AlertNotificationIDs.allScheduled(kind))
            if kind == .urgentLow { cancelAllAlarms() }

        case .cancel(let kind):
            log("cancel \(kind.rawValue)")
            repeatShortfalls[kind] = nil
            let identifiers = AlertNotificationIDs.all(kind)
            center.removePending(identifiers: identifiers)
            center.removeDelivered(identifiers: identifiers)
            if kind == .urgentLow { cancelAllAlarms() }
            stopInApp(for: kind)

        case .stopSound(let kind):
            log("stop sound \(kind.rawValue)")
            stopInApp(for: kind)

        case .repeatsNotAllScheduled(let kind, let missing):
            repeatShortfalls[kind] = missing
            log("\(kind.rawValue): \(missing) repeat(s) NOT scheduled: every free slot is held by a repeat that must not be disturbed")

        case .readingRejected(let id, let reason):
            log("reading \(id) refused: \(reason)")

        case .userActionIgnored(let userAction):
            log("ignored \(userAction): alert not active")
        }
    }

    /// Whether the alarm for a due repeat is still scheduled or ringing.
    private func dueAlarmIsPresent(_ notice: AlertNotice) -> Bool {
        guard let slot = notice.slot, let active = alarms?.activeAlarmIDs() else { return false }
        return active.contains(SystemAlarmIDs.repeatSlot(slot))
    }

    private func cancelAllAlarms() {
        do {
            try alarms?.cancelAll()
        } catch {
            // Every fixed alarm ID was cancelled; only the system's own list could not be read.
            urgentLowAlarmFailure = "could not list alarms to cancel them: \(error)"
            log("urgent-low alarms: \(urgentLowAlarmFailure ?? "")")
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
        // Replace, never duplicate: whatever still holds this ID is an old alarm (the engine never
        // reuses the ID of a pending repeat that is due or ringing).
        alarms.cancel(ids: [id])
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
        case .active: level = "active, no sound"
        case .timeSensitive: level = "time-sensitive"
        case .critical: level = "critical"
        }
        var parts = [level]
        if decision.systemAlarmSoundFileName != nil { parts.append("system alarm") }
        if decision.inAppSound != nil { parts.append("in-app sound") }
        return parts.joined(separator: " + ")
    }
}
