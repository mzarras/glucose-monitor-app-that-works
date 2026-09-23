// S5 banners: every "fail loud" condition becomes a visible banner at the top of the Now screen
// (and a dot on the Now tab). Pure; unit-tested in AppBannerTests (test_S5_…).

import Foundation
import GlucoseCore
import WidgetCore

struct AppBanner: Equatable, Identifiable, Sendable {
    enum Kind: Int, Equatable, Hashable, CaseIterable, Sendable {
        // Order = display order within a severity.
        case missedReadings
        case bluetoothOff
        case bluetoothUnauthorized
        case bluetoothUnavailable
        case sensorError
        case sensorExpired
        case sensorExpiring
        case trioBridgeFailing
        case notificationsDisabled
        case alarmVolumeTooLow
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
        context: DisplayContext = .current
    ) -> [AppBanner] {
        var banners: [AppBanner] = []

        if let banner = missedReadings(sensorState: sensorState, latest: latestLiveReadingDate, now: now, context: context) {
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

        return banners.sorted { ($0.severity.rawValue, $0.kind.rawValue) < ($1.severity.rawValue, $1.kind.rawValue) }
    }

    /// No live reading for 15 min while the sensor should be delivering (S5). Not raised when no
    /// sensor is paired, during warm-up, or when the sensor has ended (those have their own banner).
    static func missedReadings(sensorState: SensorState, latest: Date?, now: Date, context: DisplayContext = .current) -> AppBanner? {
        switch sensorState {
        case .notPaired, .expired, .failed, .error:
            return nil
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
        let age = now.timeIntervalSince(latest)
        guard age >= missedReadingsAfter else { return nil }
        let minutes = AgeText.wholeMinutes(from: latest, to: now)
        return AppBanner(
            kind: .missedReadings, severity: .critical,
            title: "No reading for \(TimeText.minutesPhrase(minutes))",
            detail: "Last reading at \(TimeText.time(latest, context)). Trio and alerts have no current value. Keep your phone near the sensor.",
            action: .openSensorSettings, actionTitle: "Sensor")
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
        case .failed(let reason):
            return [AppBanner(
                kind: .sensorError, severity: .critical,
                title: "Sensor failed",
                detail: "\(reason). Replace the sensor.",
                action: .openSensorSettings, actionTitle: "Sensor")]
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
