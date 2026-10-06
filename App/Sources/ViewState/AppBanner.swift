// S5 banners: every "fail loud" condition becomes a visible banner at the top of the Now screen
// (and a dot on the Now tab). Pure; unit-tested in AppBannerTests (test_S5_…).

import Foundation
import GlucoseCore
import WidgetCore

struct AppBanner: Equatable, Identifiable, Sendable {
    enum Kind: Int, Equatable, Hashable, CaseIterable, Sendable {
        // Order = display order within a severity.
        case missedReadings
        /// The reading database isn't open: readings are held in memory or can't be saved (S5).
        case storageUnavailable
        case bluetoothOff
        case bluetoothUnauthorized
        case bluetoothUnavailable
        case sensorError
        /// D36: the sensor has ended — replace it.
        case sensorNeedsReplacement
        /// D36: the sensor no longer accepts this phone — pair again.
        case sensorNeedsPairing
        /// D37: a failure the source could not classify (fails loud).
        case sensorProblem
        /// D36: transient; readings may be withheld for a while.
        case sensorInterrupted
        /// D36: the sensor withholds readings until calibrated (or rejected a calibration).
        case calibrationNeeded
        case sensorExpired
        case sensorExpiring
        case trioBridgeFailing
        /// Trio's heartbeat keys couldn't be written: Trio may not loop in the background.
        case trioHeartbeatFailing
        case notificationsDisabled
        /// The notification permission prompt hasn't been answered.
        case notificationsNotSetUp
        /// Banners, sounds or Time Sensitive are off for this app.
        case notificationSettingsIncomplete
        case alarmVolumeTooLow
        case urgentLowAlarmOff
        /// iOS 26+: alarms haven't been asked for yet (D26).
        case urgentLowAlarmNotSetUp
        /// Scheduling the urgent-low system alarm failed; urgent low fell back (D26).
        case urgentLowAlarmFailed
        /// Fewer alert repeats are scheduled than planned.
        case alertRepeatsShort
        case nightscoutUploadFailing
        case shareUploadFailing
        case forceQuitGap
    }

    enum Severity: Int, Equatable, Sendable {
        case critical = 0
        case warning = 1
    }

    /// What the banner's button does. The app maps these to navigation or iOS Settings.
    enum Action: Equatable, Sendable {
        case openAppSettings
        case openSensorSettings
        case openTrioSettings
        case openSharingSettings
        case openAlertDeliverySettings
        case dismissForceQuitNotice
        /// Pair a new sensor (new-sensor flow).
        case pairSensor
        /// Pair the worn sensor again: Settings › Sensor, code entry → `pairAgain(code:)`.
        case pairAgain
        case openCalibration
        /// Ask for notification permission (`AppServices.requestNotificationAuthorization`).
        case requestNotifications
        /// Ask to allow alarms for urgent low (`AppServices.requestUrgentLowAlarmAuthorization`, D26).
        case requestUrgentLowAlarm
    }

    let kind: Kind
    let severity: Severity
    let title: String
    let detail: String
    let action: Action?
    let actionTitle: String?

    var id: Kind { kind }
}

enum AppBanners {
    /// No reading for this long raises the missed-readings banner (HANDOFF S5 "no reading for 15 min").
    static let missedReadingsAfter: TimeInterval = 15 * 60
    /// A sensor this close to expiry shows the "expiring" banner (HANDOFF §5: 24 h and 2 h alerts).
    static let expiringWithin: TimeInterval = 24 * 60 * 60

    /// Banners for the current situation, critical first.
    static func make(
        sensorState: SensorState,
        latestLiveReadingDate: Date?,
        health: ServiceHealth,
        now: Date,
        clockMismatchLatched: Bool = false,
        sensorNeedsCalibration: Bool = false,
        context: DisplayContext = .current
    ) -> [AppBanner] {
        var banners: [AppBanner] = []

        // Review minor 4: a transient failure after "calibration needed" (e.g. the phone clock)
        // must not hide that the sensor still needs calibrating.
        if sensorNeedsCalibration, !isCalibrationState(sensorState) {
            banners.append(AppBanner(
                kind: .calibrationNeeded, severity: .critical,
                title: "Calibrate the sensor",
                detail: "The sensor still needs a fingerstick calibration before it sends readings.",
                action: .openCalibration, actionTitle: "Calibrate"))
        }

        if let banner = missedReadings(sensorState: sensorState, latest: latestLiveReadingDate, now: now, clockMismatchLatched: clockMismatchLatched, context: context) {
            banners.append(banner)
        }
        banners += sensorBanners(sensorState, now: now, context: context)

        switch health.trio {
        case .failing(let since, let message):
            banners.append(AppBanner(
                kind: .trioBridgeFailing, severity: .critical,
                title: "Trio isn't getting readings",
                detail: "Handoff failing since \(TimeText.time(since, context)): \(message)",
                action: .openTrioSettings, actionTitle: "Trio settings"))
        case .off, .ok:
            break
        }

        switch health.notifications {
        case .denied:
            banners.append(AppBanner(
                kind: .notificationsDisabled, severity: .critical,
                title: "Notifications are off",
                detail: "Alerts can't reach you. Allow notifications for this app in iOS Settings.",
                action: .openAppSettings, actionTitle: "Open Settings"))
        case .provisional:
            banners.append(AppBanner(
                kind: .notificationsDisabled, severity: .critical,
                title: "Notifications are delivered quietly",
                detail: "Alerts won't sound or show on the Lock Screen. Turn on alerts for this app in iOS Settings.",
                action: .openAppSettings, actionTitle: "Open Settings"))
        case .notDetermined, .authorized:
            break
        }

        if case .tooLow(let level) = health.alarmVolume {
            banners.append(AppBanner(
                kind: .alarmVolumeTooLow, severity: .warning,
                title: "Alarm volume is low",
                detail: "Volume is at \(Int((level * 100).rounded()))%. Alarms may be hard to hear; turn the volume up.",
                action: .openAlertDeliverySettings, actionTitle: "Alert delivery"))
        }

        if health.urgentLowAlarm == .denied {
            // Critical (review m6, D26): on iOS 26+ the system alarm is how urgent low rings while
            // the app is suspended.
            banners.append(AppBanner(
                kind: .urgentLowAlarmOff, severity: .critical,
                title: "Urgent low alarm is off",
                detail: "Alarms aren't allowed, so urgent low can't ring as a system alarm while the app is in the background. Allow alarms for this app in iOS Settings.",
                action: .openAppSettings, actionTitle: "Open Settings"))
        }

        if case .failing(let count, let error, _) = health.nightscout {
            banners.append(AppBanner(
                kind: .nightscoutUploadFailing, severity: .warning,
                title: "Nightscout upload failing",
                detail: "\(count) failed \(count == 1 ? "attempt" : "attempts"). Followers may not see new readings. \(error)",
                action: .openSharingSettings, actionTitle: "Sharing"))
        }
        if case .failing(let count, let error, _) = health.dexcomShare {
            banners.append(AppBanner(
                kind: .shareUploadFailing, severity: .warning,
                title: "Dexcom Share upload failing",
                detail: "\(count) failed \(count == 1 ? "attempt" : "attempts"). Dexcom Follow users may not see new readings. \(error)",
                action: .openSharingSettings, actionTitle: "Sharing"))
        }

        if let gap = health.forceQuitGap {
            banners.append(AppBanner(
                kind: .forceQuitGap, severity: .warning,
                title: "No readings \(TimeText.time(gap.from, context))–\(TimeText.time(gap.to, context))",
                detail: "The app was force-quit (swiped away). iOS doesn't restart it after that, so readings stopped until you opened it. Leave it running in the background.",
                action: .dismissForceQuitNotice, actionTitle: "Got it"))
        }

        banners += phase2Banners(health, context: context)

        // One banner per kind (the list is keyed by kind): the first, i.e. the more specific, wins.
        var seen = Set<AppBanner.Kind>()
        return banners
            .filter { seen.insert($0.kind).inserted }
            .sorted { ($0.severity.rawValue, $0.kind.rawValue) < ($1.severity.rawValue, $1.kind.rawValue) }
    }

    /// Problems the `AppServices` summaries report beyond the Phase 1 set: uploads switched on but not
    /// set up, the other alert-delivery problems, Trio's heartbeat, the database, Bluetooth permission.
    private static func phase2Banners(_ health: ServiceHealth, context: DisplayContext) -> [AppBanner] {
        var banners: [AppBanner] = []

        switch health.storage {
        case .waitingForFirstUnlock(let held):
            banners.append(AppBanner(
                kind: .storageUnavailable, severity: .critical,
                title: "Readings aren't being saved yet",
                detail: "The phone hasn't been unlocked since it restarted, so the reading database is locked. \(held == 1 ? "1 reading is" : "\(held) readings are") held until it opens.",
                action: nil, actionTitle: nil))
        case .failed(let message):
            // D42: the gate runs before the store, so live readings still reach alerts and Trio.
            banners.append(AppBanner(
                kind: .storageUnavailable, severity: .critical,
                title: "History isn't being saved",
                detail: "New readings still reach alerts and Trio, but aren't stored: charts, statistics and uploads miss them until this is fixed. \(message)",
                action: nil, actionTitle: nil))
        case .opening, .open:
            break
        }

        switch health.bluetoothAuthorization {
        case .denied, .restricted:
            banners.append(AppBanner(
                kind: .bluetoothUnauthorized, severity: .critical,
                title: "Bluetooth access not allowed",
                detail: "This app can't talk to the sensor. Allow Bluetooth for it in iOS Settings.",
                action: .openAppSettings, actionTitle: "Open Settings"))
        case .notDetermined, .allowed:
            break
        }

        if let error = health.trioHeartbeatError {
            banners.append(AppBanner(
                kind: .trioHeartbeatFailing, severity: .warning,
                title: "Trio may not loop in the background",
                detail: "The sensor couldn't be registered as Trio's heartbeat: \(error)",
                action: .openTrioSettings, actionTitle: "Trio settings"))
        }

        if case .notSetUp(let missing) = health.nightscout {
            banners.append(AppBanner(
                kind: .nightscoutUploadFailing, severity: .warning,
                title: "Nightscout upload isn't set up",
                detail: "Upload is on, but nothing is being sent. \(missing)",
                action: .openSharingSettings, actionTitle: "Sharing"))
        }
        if case .notSetUp(let missing) = health.dexcomShare {
            banners.append(AppBanner(
                kind: .shareUploadFailing, severity: .warning,
                title: "Dexcom Share upload isn't set up",
                detail: "Upload is on, but Dexcom Follow users get nothing. \(missing)",
                action: .openSharingSettings, actionTitle: "Sharing"))
        }

        var settingsOff: [String] = []
        for issue in health.deliveryIssues {
            switch issue {
            case .notificationsNotRequested:
                banners.append(AppBanner(
                    kind: .notificationsNotSetUp, severity: .warning,
                    title: "Notifications aren't set up",
                    detail: "Alerts can't reach you while the app is in the background until notifications are allowed.",
                    action: .requestNotifications, actionTitle: "Allow notifications"))
            case .notificationAlertsOff: settingsOff.append("banners")
            case .notificationSoundsOff: settingsOff.append("sounds")
            case .timeSensitiveOff: settingsOff.append("Time Sensitive")
            case .urgentLowAlarmNotRequested:
                banners.append(AppBanner(
                    kind: .urgentLowAlarmNotSetUp, severity: .warning,
                    title: "Urgent low alarm isn't set up",
                    detail: "Allow alarms so urgent low rings like a clock alarm — on silent, in Focus, and while the app is in the background.",
                    action: .requestUrgentLowAlarm, actionTitle: "Allow alarms"))
            case .urgentLowAlarmFailed(let message):
                banners.append(AppBanner(
                    kind: .urgentLowAlarmFailed, severity: .critical,
                    title: "Urgent low alarm couldn't be scheduled",
                    detail: "Urgent low uses a notification and the in-app sound instead. \(message)",
                    action: .openAlertDeliverySettings, actionTitle: "Alert delivery"))
            case .repeatsNotScheduled(let alert, let missing):
                banners.append(AppBanner(
                    kind: .alertRepeatsShort, severity: .warning,
                    title: "Some alert repeats couldn't be scheduled",
                    detail: "\(alert): \(missing) \(missing == 1 ? "repeat" : "repeats") fewer than planned while the app is in the background.",
                    action: .openAlertDeliverySettings, actionTitle: "Alert delivery"))
            }
        }
        if !settingsOff.isEmpty {
            banners.append(AppBanner(
                kind: .notificationSettingsIncomplete, severity: .warning,
                title: "Alerts may not show or sound",
                detail: "Turned off for this app in iOS Settings: \(settingsOff.joined(separator: ", ")). Turn them on so alerts reach you.",
                action: .openAppSettings, actionTitle: "Open Settings"))
        }
        return banners
    }

    /// No live reading for 15 min while the sensor should be delivering (S5). Not raised when no
    /// sensor is paired, during warm-up, or when the sensor has ended (those have their own banner).
    static func missedReadings(sensorState: SensorState, latest: Date?, now: Date, clockMismatchLatched: Bool = false, context: DisplayContext = .current) -> AppBanner? {
        switch sensorState {
        case .notPaired, .expired, .error, .calibrationNeeded, .calibrationError:
            return nil
        case .failed(let failure) where failure.raisesSensorAlert:
            return nil // its own critical banner
        case .failed:
            break // transient (D36): if readings stop for long, this banner covers it
        case .warmingUp(let endsAt) where now < endsAt:
            return nil
        case .warmingUp, .searching, .connecting, .authenticating, .active, .gracePeriod, .bluetoothUnavailable:
            break
        }
        guard let latest else {
            return AppBanner(
                kind: .missedReadings, severity: .critical,
                title: "No readings yet",
                detail: "The sensor hasn't delivered a reading. Keep your phone within a few metres of it.",
                action: .openSensorSettings, actionTitle: "Sensor")
        }
        // A reading dated ahead of the phone's clock (clock moved back) is not a current reading
        // (review M1), however new it looks — and stays so after the clock catches up (N1).
        if clockMismatchLatched || latest > now.addingTimeInterval(LiveReadingGate.futureTolerance) {
            return AppBanner(
                kind: .missedReadings, severity: .critical,
                title: "No current reading",
                detail: "The latest reading is dated \(TimeText.time(latest, context)), which doesn't match this phone's clock. Check Settings › General › Date & Time and turn on Set Automatically.",
                action: nil, actionTitle: nil)
        }
        let age = now.timeIntervalSince(latest)
        guard age >= missedReadingsAfter else { return nil }
        let minutes = AgeText.wholeMinutes(from: latest, to: now)
        return AppBanner(
            kind: .missedReadings, severity: .critical,
            title: "No reading for \(TimeText.minutesPhrase(minutes))",
            detail: "Last reading at \(TimeText.time(latest, context)). Trio and alerts have no current value. Keep your phone near the sensor.",
            action: .openSensorSettings, actionTitle: "Sensor")
    }

    private static func isCalibrationState(_ state: SensorState) -> Bool {
        switch state {
        case .calibrationNeeded, .calibrationError: return true
        default: return false
        }
    }

    private static func sensorBanners(_ state: SensorState, now: Date, context: DisplayContext) -> [AppBanner] {
        switch state {
        case .bluetoothUnavailable(.poweredOff):
            return [AppBanner(
                kind: .bluetoothOff, severity: .critical,
                title: "Bluetooth is off",
                detail: "Readings stop until Bluetooth is on. Turn it on in Control Center or Settings.",
                action: nil, actionTitle: nil)]
        case .bluetoothUnavailable(.unauthorized):
            return [AppBanner(
                kind: .bluetoothUnauthorized, severity: .critical,
                title: "Bluetooth access not allowed",
                detail: "This app can't talk to the sensor. Allow Bluetooth for it in iOS Settings.",
                action: .openAppSettings, actionTitle: "Open Settings")]
        case .bluetoothUnavailable(.unsupported):
            return [AppBanner(
                kind: .bluetoothUnavailable, severity: .critical,
                title: "Bluetooth unavailable",
                detail: "This device doesn't support Bluetooth Low Energy.",
                action: nil, actionTitle: nil)]
        case .bluetoothUnavailable(.resetting):
            return [AppBanner(
                kind: .bluetoothUnavailable, severity: .warning,
                title: "Bluetooth is restarting",
                detail: "Readings resume when Bluetooth is back.",
                action: nil, actionTitle: nil)]
        case .error(let code, let description):
            return [AppBanner(
                kind: .sensorError, severity: .critical,
                title: "Sensor error",
                detail: "\(description) (code \(code)). Readings are paused.",
                action: .openSensorSettings, actionTitle: "Sensor")]
        case .failed(let failure):
            // Decisions from the kind, words from the source (D36).
            if failure.requiresSensorReplacement {
                return [AppBanner(
                    kind: .sensorNeedsReplacement, severity: .critical,
                    title: "Replace the sensor",
                    detail: failure.message,
                    action: .pairSensor, actionTitle: "Replace sensor")]
            }
            if failure.requiresPairing {
                return [AppBanner(
                    kind: .sensorNeedsPairing, severity: .critical,
                    title: "Pair the sensor again",
                    detail: PairingGuidance.pairAgainDetail(failure),
                    action: .pairAgain, actionTitle: "Pair again")]
            }
            if failure.raisesSensorAlert {
                // D37: unclassified — fail loud.
                return [AppBanner(
                    kind: .sensorProblem, severity: .critical,
                    title: "Sensor problem",
                    detail: failure.message,
                    action: .openSensorSettings, actionTitle: "Sensor")]
            }
            if failure.kind == .bluetoothPairingIncomplete {
                // Nothing to type: the pairing finishes when the iOS request is accepted (review M1).
                return [AppBanner(
                    kind: .sensorInterrupted, severity: .warning,
                    title: "Pairing didn't finish",
                    detail: "\(failure.message) \(PairingGuidance.acceptPrompt)",
                    action: nil, actionTitle: nil)]
            }
            return [AppBanner(
                kind: .sensorInterrupted, severity: .warning,
                title: "Readings interrupted",
                detail: failure.message,
                action: .openSensorSettings, actionTitle: "Sensor")]
        case .calibrationNeeded:
            return [AppBanner(
                kind: .calibrationNeeded, severity: .critical,
                title: "Calibrate the sensor",
                detail: "The sensor withholds readings until it gets a fingerstick calibration.",
                action: .openCalibration, actionTitle: "Calibrate")]
        case .calibrationError:
            return [AppBanner(
                kind: .calibrationNeeded, severity: .critical,
                title: "Calibration not accepted",
                detail: "The sensor couldn't use the last calibration and withholds readings. Enter a new fingerstick.",
                action: .openCalibration, actionTitle: "Calibrate")]
        case .expired:
            return [AppBanner(
                kind: .sensorExpired, severity: .critical,
                title: "Sensor expired",
                detail: "No more readings from this sensor. Start a new one.",
                action: .openSensorSettings, actionTitle: "Sensor")]
        case .gracePeriod(let endsAt):
            if now >= endsAt {
                return [AppBanner(
                    kind: .sensorExpired, severity: .critical,
                    title: "Sensor expired",
                    detail: "The grace period ended. Start a new sensor.",
                    action: .openSensorSettings, actionTitle: "Sensor")]
            }
            return [AppBanner(
                kind: .sensorExpiring, severity: .warning,
                title: "Sensor in grace period",
                detail: "Readings stop at \(TimeText.time(endsAt, context)) (\(TimeText.duration(endsAt.timeIntervalSince(now))) left). Replace the sensor soon.",
                action: .openSensorSettings, actionTitle: "Sensor")]
        case .active(_, let expiresAt) where expiresAt.timeIntervalSince(now) <= expiringWithin:
            return [AppBanner(
                kind: .sensorExpiring, severity: .warning,
                title: "Sensor expires in \(TimeText.duration(max(0, expiresAt.timeIntervalSince(now))))",
                detail: "At \(TimeText.time(expiresAt, context)). A 12-hour grace period follows; have a new sensor ready.",
                action: .openSensorSettings, actionTitle: "Sensor")]
        case .notPaired, .searching, .connecting, .authenticating, .warmingUp, .active:
            return []
        }
    }
}
