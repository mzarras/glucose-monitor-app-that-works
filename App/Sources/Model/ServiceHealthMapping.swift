// `AppServices` summaries → `ServiceHealth` (S5). Pure. Every problem a summary can report ends
// up in a `ServiceHealth` field that `AppBanners.make` turns into a banner
// (`test_S5_everyServiceHealthProblemBecomesABanner`).

import AlertEngine
import Foundation
import NightscoutKit

enum ServiceHealthMapping {
    static func make(
        trio: TrioBridgeSummary,
        nightscout: NightscoutSummary,
        dexcomShare: DexcomShareSummary,
        delivery: AlertDeliveryReport,
        forceQuitGap: ForceQuitGapReport?,
        storage: StorageStatus,
        bluetooth: BluetoothAuthorization,
        now: Date
    ) -> ServiceHealth {
        var health = ServiceHealth(
            trio: trioStatus(trio, now: now),
            nightscout: uploadStatus(nightscout.upload, notSetUp: nightscoutNotSetUp(nightscout), now: now),
            dexcomShare: uploadStatus(dexcomShare.upload, notSetUp: shareNotSetUp(dexcomShare), now: now),
            notifications: notificationPermission(delivery.permissions),
            alarmVolume: alarmVolume(delivery.outputVolume),
            urgentLowAlarm: urgentLowAlarm(delivery.urgentLowAlarm),
            forceQuitGap: forceQuitGap.map { ForceQuitGap(from: $0.from, to: $0.to) }
        )
        health.deliveryIssues = deliveryIssues(delivery.problems)
        health.trioHeartbeatError = trio.isEnabled && trio.liveOutputsAllowed && !trio.offWhileListening ? trio.heartbeatError : nil
        health.storage = storage.availability
        health.bluetoothAuthorization = bluetooth
        return health
    }

    // MARK: Trio (HANDOFF §8, S5)

    static func trioStatus(_ trio: TrioBridgeSummary, now: Date) -> TrioStatus {
        // DEBUG builds keep the bridge off unless the developer switch is on (D20): it writes nothing,
        // so it reads as off here and Settings says why.
        guard trio.isEnabled, trio.liveOutputsAllowed else { return .off }
        // D45: off in the services while listening (Integrator A; B shows "off while listening").
        guard !trio.offWhileListening else { return .off }
        // Review m4: switched on, but the bridge can't run in this build (no Trio App Group): the
        // facade says why (`unavailableReason`). The App Group check is defence in depth.
        if let reason = trio.unavailableReason {
            return .failing(since: trio.problemSince ?? now, message: reason)
        }
        guard trio.appGroupID != nil else {
            return .failing(since: trio.problemSince ?? now,
                            message: "This build has no Trio App Group (Info.plist TrioAppGroupID), so readings can't be handed to Trio.")
        }
        if trio.isFailing {
            return .failing(since: trio.problemSince ?? trio.lastErrorAt ?? now, message: trio.lastErrorDescription ?? "Writing to Trio's App Group failed.")
        }
        if trio.isStarving {
            return .failing(since: trio.problemSince ?? now, message: "New readings are arriving but none has reached Trio for 15 minutes.")
        }
        return .ok(lastHandoff: trio.lastSuccessfulWriteAt)
    }

    // MARK: Uploads (HANDOFF §8A, S5)

    static func nightscoutNotSetUp(_ nightscout: NightscoutSummary) -> String {
        nightscout.siteURL == nil ? "No Nightscout site is saved." : "No access token is saved for \(nightscout.siteURL ?? "the site")."
    }

    static func shareNotSetUp(_ share: DexcomShareSummary) -> String {
        var missing: [String] = []
        if (share.accountName ?? "").isEmpty { missing.append("account name") }
        if !share.hasPassword { missing.append("password") }
        if (share.receiverSerialNumber ?? "").isEmpty { missing.append("receiver serial number") }
        return missing.isEmpty ? "Dexcom Share credentials are incomplete." : "Missing: \(missing.joined(separator: ", "))."
    }

    static func uploadStatus(_ upload: UploaderSummary, notSetUp: String, now: Date) -> UploadStatus {
        guard upload.isEnabled, upload.liveOutputsAllowed else { return .off }
        // D45: off in the services while listening (Integrator A; B shows "off while listening").
        guard !upload.offWhileListening else { return .off }
        if upload.isFailing {
            let status = upload.status
            let failures = max(status?.consecutiveFailures ?? 0, status?.refusalsSinceLastSuccess ?? 0, 1)
            return .failing(failureCount: failures, lastError: uploadProblem(upload), since: upload.problemSince ?? status?.lastErrorAt ?? now)
        }
        if !upload.isConfigured { return .notSetUp(notSetUp) }
        return .ok(lastUpload: upload.status?.lastSuccessAt)
    }

    /// The most specific reason uploads aren't getting through.
    static func uploadProblem(_ upload: UploaderSummary) -> String {
        if let setupError = upload.setupError { return setupError }
        guard let status = upload.status else { return "Uploads are not getting through." }
        if let problem = status.queueLoadProblem { return "The upload queue couldn't be read: \(problem)" }
        if let problem = status.queueSaveProblem { return "The upload queue couldn't be saved: \(problem)" }
        if status.consecutiveFailures > 0, let error = status.lastError { return error.message }
        if status.refusalsSinceLastSuccess > 0, let refusal = status.lastRefusal { return refusalText(refusal) }
        // NightscoutKit review m3: readings held or dropped for their dates (S5: each says which).
        if status.heldInFuture > 0 { return heldInFutureText(status.heldInFuture) }
        if status.discardedSinceLastSuccess > 0 { return discardedText(status.discardedSinceLastSuccess, lastReason: status.lastDiscardReason) }
        return status.lastError?.message ?? "Uploads are not getting through."
    }

    /// Readings waiting in the queue because they are dated ahead of the phone's clock (the clock
    /// was set back after they were queued); they go out once the clock passes their dates.
    static func heldInFutureText(_ count: Int) -> String {
        "\(count) \(count == 1 ? "reading is" : "readings are") waiting because \(count == 1 ? "it's" : "they're") dated ahead of the phone's clock; \(count == 1 ? "it" : "they")'ll upload when the clock catches up."
    }

    /// Readings dropped from the queue since the last successful upload; they will never reach
    /// followers. `lastReason` is NightscoutKit's "N readings <why>" for the latest drop (its
    /// safety-rule tags removed).
    static func discardedText(_ count: Int, lastReason: String?) -> String {
        let base = "\(count) \(count == 1 ? "reading wasn't" : "readings weren't") uploaded and won't be"
        guard let reason = lastReason?.replacingOccurrences(of: #"\s*\(S\d\)"#, with: "", options: .regularExpression),
              !reason.isEmpty else { return base + "." }
        return "\(base) (latest: \(reason))."
    }

    static func refusalText(_ refusal: UploadRefusal) -> String {
        switch refusal {
        case .gate(let rejection): return "Readings were refused as not valid for upload (\(rejection))."
        case .notRepresentable: return "A reading could not be represented for this service."
        }
    }

    // MARK: Alert delivery (HANDOFF §4.7, D4, D17, D26)

    static func notificationPermission(_ permissions: NotificationPermissionState) -> NotificationPermission {
        switch permissions.authorization {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .ephemeral: return .authorized
        case .provisional: return .provisional
        }
    }

    static func criticalAlerts(_ permissions: NotificationPermissionState) -> CriticalAlertsStatus {
        switch permissions.criticalAlerts {
        case .enabled: return permissions.isAuthorized ? .active : .disabledByUser
        case .disabled: return .disabledByUser
        case .notSupported: return .entitlementNotGranted
        }
    }

    static func alarmVolume(_ volume: Float?) -> AlarmVolumeStatus {
        guard let volume else { return .unknown }
        let level = Double(volume)
        return volume < AlertLimits.lowAlarmVolume ? .tooLow(level: level) : .ok(level: level)
    }

    static func urgentLowAlarm(_ authorization: SystemAlarmAuthorization) -> UrgentLowAlarmStatus {
        switch authorization {
        case .unavailable: return .unavailable
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        }
    }

    /// The problems not already carried by `notifications`, `alarmVolume` and `urgentLowAlarm`.
    /// Exhaustive on purpose: a new `DeliveryProblem` must be placed here.
    static func deliveryIssues(_ problems: [DeliveryProblem]) -> [DeliveryIssue] {
        var issues: [DeliveryIssue] = []
        for problem in problems {
            let issue: DeliveryIssue?
            switch problem {
            case .notificationsDenied, .alarmVolumeMuted, .alarmVolumeLow, .urgentLowAlarmDenied:
                issue = nil // `notifications`, `alarmVolume`, `urgentLowAlarm`
            case .notificationsNotRequested: issue = .notificationsNotRequested
            case .notificationAlertsOff: issue = .notificationAlertsOff
            case .notificationSoundsOff: issue = .notificationSoundsOff
            case .timeSensitiveOff: issue = .timeSensitiveOff
            case .urgentLowAlarmNotRequested: issue = .urgentLowAlarmNotRequested
            case .urgentLowAlarmFailed(let message): issue = .urgentLowAlarmFailed(message)
            case .repeatsNotAllScheduled(let kind, let missing): issue = .repeatsNotScheduled(alert: kind.title, missing: missing)
            }
            if let issue, !issues.contains(issue) { issues.append(issue) }
        }
        return issues
    }
}
