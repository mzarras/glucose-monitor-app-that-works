import XCTest
import GlucoseCore
@testable import AlertEngine

/// D53 (Michael): every alert except urgent low has a style — sound, vibrate only, or (one-off
/// announcements only) silent. Urgent low always sounds on the loudest path (S7).
@MainActor
final class AlertStyleTests: XCTestCase {
    private let vibrate = AlertSoundCatalog.vibrateFileName
    private let conditionKinds = AlertKind.allCases.filter { $0 != .urgentLow && !$0.isEventAlert }
    private let eventKinds = AlertKind.allCases.filter(\.isEventAlert)

    private func decode(_ json: String) throws -> AlertSettings {
        try JSONDecoder().decode(AlertSettings.self, from: Data(json.utf8))
    }

    // MARK: Settings

    func test_defaultsAreUnchanged() {
        let s = AlertSettings.defaults
        XCTAssertEqual(AlertKind.allCases.filter { s.style($0) != .sound }, [.sensorExpiringIn24Hours])
        XCTAssertEqual(s.style(.sensorExpiringIn24Hours), .silent, "the 24-hour reminder stays silent by default (D43)")
    }

    func test_uniformAccessorsOfferAndRefuseByKind() {
        var s = AlertSettings.defaults
        for kind in AlertKind.allCases {
            let allowed = s.allowedStyles(for: kind)
            switch kind {
            case .urgentLow: XCTAssertEqual(allowed, [.sound])
            case _ where kind.isEventAlert: XCTAssertEqual(allowed, [.sound, .vibrateOnly, .silent], "\(kind)")
            default: XCTAssertEqual(allowed, [.sound, .vibrateOnly], "\(kind)")
            }
            XCTAssertEqual(AlertSettings.allowedStyles(for: kind), allowed)
            for style in AlertStyle.allCases {
                let before = s.style(kind)
                let applied = s.setStyle(style, for: kind)
                XCTAssertEqual(applied, allowed.contains(style), "\(kind) \(style)")
                XCTAssertEqual(s.style(kind), applied ? style : before, "\(kind) \(style): a refused style changes nothing")
            }
        }
        var low = LowAlertSettings()
        low.style = .vibrateOnly
        low.style = .silent
        XCTAssertEqual(low.style, .vibrateOnly, "a condition alert keeps its style when assigned .silent directly")
        XCTAssertEqual(StatusAlertSettings(isEnabled: true, sound: .warble, soundsOnSilent: true, style: .silent, snoozeMinutes: 30).style, .sound)
    }

    func test_theD43SoundSwitchMapsOntoTheStyle() {
        var s = AlertSettings.defaults
        XCTAssertTrue(s.setStyle(.vibrateOnly, for: .sensorExpiringIn12Hours))
        XCTAssertTrue(s.playsSound(.sensorExpiringIn12Hours), "vibrate only is not 'silent'")
        XCTAssertTrue(s.setPlaysSound(true, for: .sensorExpiringIn12Hours))
        XCTAssertEqual(s.style(.sensorExpiringIn12Hours), .vibrateOnly, "turning the switch on keeps vibrate only")
        s.setPlaysSound(false, for: .sensorExpiringIn12Hours)
        XCTAssertEqual(s.style(.sensorExpiringIn12Hours), .silent)
        s.setPlaysSound(true, for: .sensorExpiringIn12Hours)
        XCTAssertEqual(s.style(.sensorExpiringIn12Hours), .sound)
        XCTAssertFalse(s.setPlaysSound(false, for: .low), "condition alerts cannot be silent")
        XCTAssertEqual(s.style(.low), .sound)
    }

    // MARK: Migration

    func test_D43PlaysSoundMigratesToTheStyle() throws {
        let older = try decode("""
        {"sensorExpiringIn12Hours": {"playsSound": false}, "sensorExpiringIn24Hours": {"playsSound": true},
         "sensorExpiringIn2Hours": {"isEnabled": false}, "low": {"isEnabled": true}}
        """)
        XCTAssertEqual(older.style(.sensorExpiringIn12Hours), .silent, "playsSound false → silent")
        XCTAssertEqual(older.style(.sensorExpiringIn24Hours), .sound, "playsSound true → sound")
        XCTAssertEqual(older.style(.sensorExpiringIn2Hours), .sound, "missing → the default")
        XCTAssertEqual(older.style(.low), .sound)
        XCTAssertEqual(try decode("{}").style(.sensorExpiringIn24Hours), .silent, "missing → the default (silent for 24 h)")
        let both = try decode(#"{"sensorGracePeriod": {"playsSound": false, "style": "vibrateOnly"}}"#)
        XCTAssertEqual(both.style(.sensorGracePeriod), .vibrateOnly, "a stored style wins")
    }

    func test_storedStylesDecodeWithinWhatEachAlertAllows() throws {
        let s = try decode("""
        {"low": {"style": "vibrateOnly"}, "missedReadings": {"style": "silent"}, "high": {"style": "loud"},
         "sensorWarmUpComplete": {"style": "silent"}, "sensorGracePeriod": {"style": 7}}
        """)
        XCTAssertEqual(s.style(.low), .vibrateOnly)
        XCTAssertEqual(s.style(.missedReadings), .sound, "not allowed for a condition alert: the default")
        XCTAssertEqual(s.style(.high), .sound, "unknown (a newer build): the default")
        XCTAssertEqual(s.style(.sensorWarmUpComplete), .silent)
        XCTAssertEqual(s.style(.sensorGracePeriod), .sound, "unreadable: the default")

        var all = AlertSettings.defaults
        for kind in AlertKind.allCases where kind != .urgentLow { all.setStyle(.vibrateOnly, for: kind) }
        all.setStyle(.silent, for: .sensorWarmUpComplete)
        let data = try JSONEncoder().encode(all)
        XCTAssertEqual(try JSONDecoder().decode(AlertSettings.self, from: data), all, "round trip")
    }

    // MARK: S7

    func test_S7_urgentLowAlwaysSoundsWhateverTheStyleAPIStoredSettingsOrNoticeSay() async throws {
        var s = AlertSettings.defaults
        XCTAssertFalse(s.setStyle(.vibrateOnly, for: .urgentLow), "the API refuses")
        XCTAssertFalse(s.setStyle(.silent, for: .urgentLow))
        XCTAssertEqual(s.style(.urgentLow), .sound)
        XCTAssertEqual(s, AlertSettings.defaults, "nothing changed")
        XCTAssertEqual(try decode(#"{"urgentLow": {"style": "vibrateOnly"}}"#).style(.urgentLow), .sound, "nowhere to decode it into")

        // Every other alert vibrate only: urgent low still plays its sound, in-app while awake.
        for kind in AlertKind.allCases where kind != .urgentLow { s.setStyle(.vibrateOnly, for: kind) }
        let h = ServiceHarness(settings: s)
        await h.service.start()
        await h.reading(.mgdl(50))
        XCTAssertEqual(h.center.posted.last?.sound, .named(fileName: "alert-cascade.wav"))
        XCTAssertEqual(h.audio.plays.map(\.fileName), ["alert-cascade.wav"])
        XCTAssertEqual(h.haptics.vibrations, 0)

        // A tampered notice cannot make it vibrate only either (defence in depth).
        for style in [AlertStyle.vibrateOnly, .silent] {
            let notice = AlertNotice(kind: .urgentLow, title: "Urgent low", body: "b", sound: .cascade, soundsOnSilent: true,
                                     isSilenced: false, snoozeMinutes: 30, fireDate: nil, style: style)
            let decision = DeliveryPolicy.decide(for: notice, criticalAlertsEnabled: false, systemAlarmsAvailable: false, timing: .now)
            XCTAssertEqual(decision.notificationSound, .named(fileName: "alert-cascade.wav"), "\(style)")
            XCTAssertNotNil(decision.inAppSound)
            XCTAssertFalse(decision.inAppHaptic)
        }
    }

    // MARK: Delivery policy

    private func notice(_ kind: AlertKind = .low, style: AlertStyle, soundsOnSilent: Bool = true, silenced: Bool = false) -> AlertNotice {
        AlertNotice(kind: kind, title: "t", body: "b", sound: .dusk, soundsOnSilent: soundsOnSilent, isSilenced: silenced,
                    snoozeMinutes: 30, fireDate: nil, style: style)
    }

    private func decide(_ n: AlertNotice, critical: Bool = false, _ timing: DeliveryTiming) -> DeliveryDecision {
        DeliveryPolicy.decide(for: n, criticalAlertsEnabled: critical, systemAlarmsAvailable: false, timing: timing)
    }

    func test_vibrateOnlyIsTimeSensitiveAndVibratesWheneverAwakeWhateverSoundOnSilentSays() {
        // D54: "Sound on silent" (hidden for vibrate only) plays no part.
        for soundsOnSilent in [true, false] {
            for critical in [false, true] {
                XCTAssertEqual(decide(notice(style: .vibrateOnly, soundsOnSilent: soundsOnSilent), critical: critical, .now),
                               DeliveryDecision(interruption: .timeSensitive, notificationSound: .named(fileName: vibrate), inAppSound: nil, inAppHaptic: true),
                               "sound on silent \(soundsOnSilent), critical \(critical): Time Sensitive, never Critical; awake: one vibration, no audio")
                XCTAssertEqual(decide(notice(style: .vibrateOnly, soundsOnSilent: soundsOnSilent), critical: critical, .scheduled),
                               DeliveryDecision(interruption: .timeSensitive, notificationSound: .named(fileName: vibrate), inAppSound: nil),
                               "pending: the silent sound, so iOS vibrates")
                XCTAssertEqual(decide(notice(style: .vibrateOnly, soundsOnSilent: soundsOnSilent, silenced: true), critical: critical, .now),
                               DeliveryDecision(interruption: .passive, notificationSound: .none, inAppSound: nil), "quiet hours: passive, no vibration")
            }
        }
        XCTAssertEqual(decide(notice(.sensorGracePeriod, style: .silent), .now),
                       DeliveryDecision(interruption: .active, notificationSound: .none, inAppSound: nil), "silent: the banner only")
        XCTAssertEqual(decide(notice(style: .sound), .now),
                       DeliveryDecision(interruption: .timeSensitive, notificationSound: .named(fileName: "alert-dusk.wav"),
                                        inAppSound: InAppSound(fileName: "alert-dusk.wav", loopSeconds: 0)), "sound: as before")
        XCTAssertEqual(decide(notice(style: .sound), critical: true, .now).interruption, .critical, "sound with Critical granted: as before")
    }

    func test_aVibrateOnlyAlertWithSoundOnSilentOffStillVibratesInTheApp() async {
        var settings = AlertSettings.defaults
        settings.fallingFast.isEnabled = true      // Sound on silent is off by default for the rate alerts
        settings.setStyle(.vibrateOnly, for: .fallingFast)
        XCTAssertFalse(settings.soundsOnSilent(.fallingFast))
        let h = ServiceHarness(settings: settings)
        h.center.permissions.criticalAlerts = .enabled   // and Critical granted: still Time Sensitive
        await h.service.start()
        await h.service.send(.reading(Fixtures.reading(.mgdl(150), at: h.clock.now, rate: -4), session: Fixtures.session))
        let posted = h.center.posted.last { $0.userInfo[AlertNotificationIDs.userInfoKind] == "fallingFast" }
        XCTAssertEqual(posted?.interruption, .timeSensitive, "never Critical")
        XCTAssertEqual(posted?.sound, .named(fileName: vibrate))
        XCTAssertEqual(h.haptics.vibrations, 1)
        XCTAssertTrue(h.audio.plays.isEmpty)
    }

    // MARK: The service, per style

    func test_eachStylesNotificationAndInAppAction() async {
        for style in [AlertStyle.sound, .vibrateOnly] {
            var settings = AlertSettings.defaults
            settings.setStyle(style, for: .low)
            let h = ServiceHarness(settings: settings)
            await h.service.start()
            await h.reading(.mgdl(65))
            let posted = h.center.posted.last { $0.userInfo[AlertNotificationIDs.userInfoKind] == "low" }
            XCTAssertEqual(posted?.interruption, .timeSensitive, "\(style)")
            switch style {
            case .sound:
                XCTAssertEqual(posted?.sound, .named(fileName: "alert-dusk.wav"))
                XCTAssertEqual(h.audio.plays.map(\.fileName), ["alert-dusk.wav"])
                XCTAssertEqual(h.haptics.vibrations, 0)
            default:
                XCTAssertEqual(posted?.sound, .named(fileName: vibrate))
                XCTAssertEqual(h.audio.plays.count, 0, "the audio session is never activated")
                XCTAssertEqual(h.haptics.vibrations, 1, "awake: one vibration from the app")
                XCTAssertTrue(h.log.messages.contains { $0.contains("vibrate only") && $0.contains("in-app vibration") })
            }
        }

        var silentEvent = AlertSettings.defaults
        silentEvent.setStyle(.silent, for: .sensorWarmUpComplete)
        let h = ServiceHarness(settings: silentEvent)
        await h.service.start()
        await h.service.send(.sensorState(.warmingUp(endsAt: h.clock.now.addingTimeInterval(60))))
        h.clock.advance(minutes: 1)
        await h.service.send(.sensorState(.active(sessionStart: Fixtures.session.start, expiresAt: Fixtures.session.expiresAt)))
        let announced = h.center.posted.last { $0.userInfo[AlertNotificationIDs.userInfoKind] == "sensorWarmUpComplete" }
        XCTAssertEqual(announced?.interruption, .active)
        XCTAssertEqual(announced?.sound, NotificationSoundChoice.none)
        XCTAssertEqual(h.audio.plays.count + h.haptics.vibrations, 0, "silent: nothing at all")
    }

    func test_aVibrateOnlyAlertsRepeatsVibrateToo() async {
        var settings = AlertSettings.defaults
        settings.setStyle(.vibrateOnly, for: .missedReadings)
        let h = ServiceHarness(settings: settings)
        await h.service.start()
        await h.reading(.mgdl(120))
        let pending = h.center.pending(for: .missedReadings)
        XCTAssertEqual(pending.count, 12)
        XCTAssertTrue(pending.allSatisfy { $0.sound == .named(fileName: vibrate) && $0.interruption == .timeSensitive },
                      "every pending repeat carries the silent sound")
        await h.advance(minutes: 15)
        await h.advance(minutes: 15)
        XCTAssertEqual(h.haptics.vibrations, 2, "each repeat while awake vibrates")
        XCTAssertTrue(h.audio.plays.isEmpty)
    }

    func test_quietHoursSilenceAVibrateOnlyAlertAsBefore() async {
        var settings = AlertSettings.defaults
        settings.setStyle(.vibrateOnly, for: .low)
        settings.quietHours = QuietHours(isEnabled: true, startMinuteOfDay: 11 * 60, endMinuteOfDay: 13 * 60)   // t0 is 12:00 UTC
        let h = ServiceHarness(settings: settings)
        await h.service.start()
        await h.reading(.mgdl(65))
        let posted = h.center.posted.last { $0.userInfo[AlertNotificationIDs.userInfoKind] == "low" }
        XCTAssertEqual(posted?.interruption, .passive)
        XCTAssertEqual(posted?.sound, NotificationSoundChoice.none)
        XCTAssertEqual(h.haptics.vibrations, 0)
    }

    func test_thePendingBudgetIsUnchanged() {
        XCTAssertEqual(AlertLimits.worstCasePendingNotifications, 49, "a style changes a notification's sound, not how many are pending")
    }
}
