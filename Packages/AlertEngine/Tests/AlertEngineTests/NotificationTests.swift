import XCTest
@testable import AlertEngine

final class NotificationRequestTests: XCTestCase {
    private let timeSensitive = DeliveryDecision(interruption: .timeSensitive, notificationSound: .named(fileName: "alert-dusk.wav"), inAppSound: nil)

    func test_identifiersAreFixedAndDistinctPerAlert() {
        XCTAssertEqual(AlertNotificationIDs.immediate(.urgentLow), "sensor.alert.urgentLow")
        XCTAssertEqual(AlertNotificationIDs.scheduled(.urgentLow, slot: 3), "sensor.alert.urgentLow.slot3")
        XCTAssertEqual(AlertNotificationIDs.all(.missedReadings).count, 1 + AlertLimits.maximumScheduledSlots)
        XCTAssertEqual(AlertLimits.maximumScheduledSlots, 30, "60 min at the 2-minute floor")
        let everything = AlertKind.allCases.flatMap(AlertNotificationIDs.all)
        XCTAssertEqual(Set(everything).count, everything.count)
    }

    func test_immediateRequestCarriesKindSnoozeAndCategory() {
        let notice = AlertNotice(kind: .low, title: "Low", body: "65 mg/dL at 12:00 PM.", sound: .dusk, soundsOnSilent: true,
                                 isSilenced: false, snoozeMinutes: 30, fireDate: nil)
        let spec = NotificationRequestBuilder.request(for: notice, decision: timeSensitive, slot: nil)
        XCTAssertEqual(spec, NotificationRequestSpec(
            identifier: "sensor.alert.low", title: "Low", body: "65 mg/dL at 12:00 PM.", threadIdentifier: "sensor.alert.low",
            categoryIdentifier: AlertNotificationIDs.snoozableCategory, interruption: .timeSensitive,
            sound: .named(fileName: "alert-dusk.wav"), fireDate: nil,
            userInfo: ["alertKind": "low", "snoozeMinutes": "30"]))
    }

    func test_pendingRequestUsesItsSlotAndFireDate() {
        let when = Fixtures.t0.addingTimeInterval(300)
        let notice = AlertNotice(kind: .urgentLow, title: "Urgent low", body: "b", sound: .cascade, soundsOnSilent: true,
                                 isSilenced: false, snoozeMinutes: 30, fireDate: when)
        let spec = NotificationRequestBuilder.request(for: notice, decision: timeSensitive, slot: 0)
        XCTAssertEqual(spec.identifier, "sensor.alert.urgentLow.slot0")
        XCTAssertEqual(spec.fireDate, when)
    }

    func test_announcementsHaveNoSnoozeAction() {
        let notice = AlertNotice(kind: .sensorGracePeriod, title: "t", body: "b", sound: .doorbell, soundsOnSilent: false,
                                 isSilenced: false, snoozeMinutes: nil, fireDate: nil)
        let spec = NotificationRequestBuilder.request(for: notice, decision: timeSensitive, slot: nil)
        XCTAssertEqual(spec.categoryIdentifier, AlertNotificationIDs.informationalCategory)
        XCTAssertNil(spec.userInfo["snoozeMinutes"])
    }
}

final class NotificationResponseTests: XCTestCase {
    private let info: [AnyHashable: Any] = ["alertKind": "urgentLow", "snoozeMinutes": "30"]

    func test_openingOrAcknowledgingAcknowledges() {
        XCTAssertEqual(AlertNotificationResponse.userAction(for: .opened, userInfo: info), .acknowledge(.urgentLow))
        XCTAssertEqual(AlertNotificationResponse.userAction(for: .action(AlertNotificationIDs.acknowledgeAction), userInfo: info), .acknowledge(.urgentLow))
    }

    func test_snoozeUsesTheDurationCarriedByTheNotification() {
        XCTAssertEqual(AlertNotificationResponse.userAction(for: .action(AlertNotificationIDs.snoozeAction), userInfo: info), .snooze(.urgentLow, minutes: 30))
        let noDuration: [AnyHashable: Any] = ["alertKind": "high"]
        XCTAssertEqual(AlertNotificationResponse.userAction(for: .action(AlertNotificationIDs.snoozeAction), userInfo: noDuration), .acknowledge(.high))
    }

    func test_swipingAwayOnlySilences() {
        XCTAssertEqual(AlertNotificationResponse.userAction(for: .dismissed, userInfo: info), .silence(.urgentLow))
    }

    func test_foreignNotificationsAndUnknownActionsAreIgnored() {
        XCTAssertNil(AlertNotificationResponse.userAction(for: .opened, userInfo: [:]))
        XCTAssertNil(AlertNotificationResponse.userAction(for: .opened, userInfo: ["alertKind": "somethingElse"]))
        XCTAssertNil(AlertNotificationResponse.userAction(for: .action("other.action"), userInfo: info))
    }
}

final class DeliveryStatusTests: XCTestCase {
    private func permissions(
        _ authorization: NotificationPermissionState.Authorization = .authorized,
        alerts: NotificationPermissionState.Setting = .enabled, sounds: NotificationPermissionState.Setting = .enabled,
        critical: NotificationPermissionState.Setting = .notSupported, timeSensitive: NotificationPermissionState.Setting = .enabled
    ) -> NotificationPermissionState {
        NotificationPermissionState(authorization: authorization, alerts: alerts, sounds: sounds, criticalAlerts: critical, timeSensitive: timeSensitive)
    }

    func test_allGoodHasNoProblems() {
        XCTAssertEqual(AlertDeliveryStatus(permissions: permissions(), outputVolume: 0.8).problems, [])
    }

    func test_S5_notificationsDeniedIsSurfaced() {
        XCTAssertEqual(AlertDeliveryStatus(permissions: permissions(.denied), outputVolume: 0.8).problems, [.notificationsDenied])
        XCTAssertEqual(AlertDeliveryStatus(permissions: permissions(.notDetermined), outputVolume: nil).problems, [.notificationsNotRequested])
        XCTAssertEqual(AlertDeliveryStatus(permissions: .unknown, outputVolume: nil).problems, [.notificationsNotRequested])
    }

    func test_S5_partialPermissionsAreSurfaced() {
        let status = AlertDeliveryStatus(permissions: permissions(alerts: .disabled, sounds: .disabled, timeSensitive: .disabled), outputVolume: 1)
        XCTAssertEqual(status.problems, [.notificationAlertsOff, .notificationSoundsOff, .timeSensitiveOff])
    }

    func test_S5_mutedOrLowAlarmVolumeIsSurfaced() {
        XCTAssertEqual(AlertDeliveryStatus(permissions: permissions(), outputVolume: 0).problems, [.alarmVolumeMuted])
        XCTAssertEqual(AlertDeliveryStatus(permissions: permissions(), outputVolume: 0.1).problems, [.alarmVolumeLow(0.1)])
        XCTAssertEqual(AlertDeliveryStatus(permissions: permissions(), outputVolume: 0.25).problems, [])
    }

    func test_criticalDeliveryRequiresTheGrantAndAuthorization() {
        XCTAssertTrue(permissions(critical: .enabled).criticalAlertsEnabled)
        XCTAssertTrue(permissions(.provisional, critical: .enabled).criticalAlertsEnabled)
        XCTAssertTrue(permissions(.ephemeral, critical: .enabled).criticalAlertsEnabled)
        XCTAssertFalse(permissions(critical: .disabled).criticalAlertsEnabled)
        XCTAssertFalse(permissions(critical: .notSupported).criticalAlertsEnabled)
        XCTAssertFalse(permissions(.denied, critical: .enabled).criticalAlertsEnabled)
    }
}
