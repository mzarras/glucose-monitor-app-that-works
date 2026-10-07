import XCTest
@testable import AlertEngine

/// Which path(s) make each alert audible, for every combination of "Sound on silent", Critical
/// Alert authorization, system alarms (iOS 26+ AlarmKit, authorized), and app awake (`.now`) vs
/// suspended (`.scheduled`).
final class DeliveryPolicyTests: XCTestCase {
    private func notice(_ kind: AlertKind, soundsOnSilent: Bool, silenced: Bool = false, sound: AlertSoundID = .dusk,
                        playsSound: Bool = true, style: AlertStyle? = nil) -> AlertNotice {
        AlertNotice(kind: kind, title: "t", body: "b", sound: sound, soundsOnSilent: soundsOnSilent,
                    isSilenced: silenced, snoozeMinutes: 30, fireDate: nil, style: style ?? (playsSound ? .sound : .silent))
    }

    private func decide(_ n: AlertNotice, critical: Bool = false, alarms: Bool = false, _ timing: DeliveryTiming) -> DeliveryDecision {
        DeliveryPolicy.decide(for: n, criticalAlertsEnabled: critical, systemAlarmsAvailable: alarms, timing: timing)
    }

    private let dusk = "alert-dusk.wav"

    func test_soundOnSilent_awake_noCritical_playsInAppSoundAndPostsTimeSensitiveWithSound() {
        XCTAssertEqual(decide(notice(.low, soundsOnSilent: true), .now),
                       DeliveryDecision(interruption: .timeSensitive, notificationSound: .named(fileName: dusk),
                                        inAppSound: InAppSound(fileName: dusk, loopSeconds: 0)))
    }

    func test_soundOnSilent_suspended_noCritical_isTimeSensitiveOnly() {
        // The documented gap: vibrate-only on silent while the app is suspended (D17).
        XCTAssertEqual(decide(notice(.missedReadings, soundsOnSilent: true), .scheduled),
                       DeliveryDecision(interruption: .timeSensitive, notificationSound: .named(fileName: dusk), inAppSound: nil))
    }

    func test_soundOnSilent_withCriticalGranted_usesCriticalAlertAndNoInAppSound() {
        for timing in DeliveryTiming.allCases {
            for alarms in [false, true] {
                XCTAssertEqual(decide(notice(.high, soundsOnSilent: true), critical: true, alarms: alarms, timing),
                               DeliveryDecision(interruption: .critical, notificationSound: .critical(fileName: dusk, volume: 1.0), inAppSound: nil))
            }
        }
    }

    func test_soundOnSilentOff_respectsTheRingerSwitchEvenWithCriticalGranted() {
        for critical in [false, true] {
            for alarms in [false, true] {
                for timing in DeliveryTiming.allCases {
                    XCTAssertEqual(decide(notice(.risingFast, soundsOnSilent: false), critical: critical, alarms: alarms, timing),
                                   DeliveryDecision(interruption: .timeSensitive, notificationSound: .named(fileName: dusk), inAppSound: nil))
                }
            }
        }
    }

    func test_quietHoursSilenceEverythingButUrgentLow() {
        for kind in AlertKind.allCases where kind != .urgentLow {
            for critical in [false, true] {
                for alarms in [false, true] {
                    for timing in DeliveryTiming.allCases {
                        let d = decide(notice(kind, soundsOnSilent: true, silenced: true), critical: critical, alarms: alarms, timing)
                        XCTAssertEqual(d, DeliveryDecision(interruption: .passive, notificationSound: NotificationSoundChoice.none, inAppSound: nil), "\(kind)")
                        XCTAssertEqual(d.loudness, 0)
                    }
                }
            }
        }
    }

    // MARK: System alarms (D26)

    func test_urgentLowUsesASystemAlarmWhenAvailableAndCriticalIsNot() {
        for timing in DeliveryTiming.allCases {
            let d = decide(notice(.urgentLow, soundsOnSilent: true, sound: .cascade), alarms: true, timing)
            XCTAssertEqual(d, DeliveryDecision(
                interruption: .timeSensitive, notificationSound: .named(fileName: "alert-cascade.wav"),
                inAppSound: nil, systemAlarmSoundFileName: "alert-cascade.caf"),
                "\(timing): alarm rings; notification is the visual; no in-app sound to clash with it")
        }
    }

    func test_criticalAlertsTakePrecedenceOverSystemAlarms() {
        // Loop uses AlarmKit only in builds without the entitlement (AlertManager.swift:451-457).
        let d = decide(notice(.urgentLow, soundsOnSilent: true, sound: .cascade), critical: true, alarms: true, .scheduled)
        XCTAssertEqual(d.interruption, .critical)
        XCTAssertNil(d.systemAlarmSoundFileName)
    }

    func test_onlyUrgentLowEverUsesSystemAlarms() {
        for kind in AlertKind.allCases where kind != .urgentLow {
            for soundsOnSilent in [false, true] {
                for timing in DeliveryTiming.allCases {
                    XCTAssertNil(decide(notice(kind, soundsOnSilent: soundsOnSilent), alarms: true, timing).systemAlarmSoundFileName, "\(kind)")
                }
            }
        }
    }

    func test_withoutSystemAlarmsUrgentLowKeepsTheD17Path() {
        XCTAssertEqual(decide(notice(.urgentLow, soundsOnSilent: true, sound: .cascade), alarms: false, .now).inAppSound,
                       InAppSound(fileName: "alert-cascade.wav", loopSeconds: AlertLimits.urgentInAppAudioSeconds))
        XCTAssertNil(decide(notice(.urgentLow, soundsOnSilent: true), alarms: false, .scheduled).systemAlarmSoundFileName)
    }

    // MARK: S7

    func test_S7_urgentLowAlwaysGetsTheLoudestAvailablePath() {
        // Whatever the notice claims (even a malformed one that says silenced / not sound-on-silent),
        // urgent low gets the loudest path the situation allows.
        for critical in [false, true] {
            for alarms in [false, true] {
                for timing in DeliveryTiming.allCases {
                    let loudestPossible = (critical || alarms) ? 3 : (timing == .now ? 2 : 1)
                    for soundsOnSilent in [false, true] {
                        for (silenced, playsSound) in [(false, true), (true, true), (false, false), (true, false)] {
                            let n = notice(.urgentLow, soundsOnSilent: soundsOnSilent, silenced: silenced, sound: .cascade, playsSound: playsSound)
                            let d = decide(n, critical: critical, alarms: alarms, timing)
                            let label = "critical \(critical) alarms \(alarms) \(timing) silenced \(silenced) playsSound \(playsSound)"
                            XCTAssertEqual(d.loudness, loudestPossible, label)
                            XCTAssertNotEqual(d.interruption, .passive, label)
                            XCTAssertNotEqual(d.notificationSound, NotificationSoundChoice.none, label)
                            if !critical && !alarms && timing == .now {
                                XCTAssertEqual(d.inAppSound, InAppSound(fileName: "alert-cascade.wav", loopSeconds: AlertLimits.urgentInAppAudioSeconds),
                                               "loops for 30 s")
                            }
                        }
                    }
                }
            }
        }
    }

    /// D43: an announcement with its sound off (the 24-hour expiry reminder by default) is a visible
    /// notification with no sound, whatever else is set; quiet hours still make it passive.
    func test_anAnnouncementWithItsSoundOffIsAVisibleNotificationWithNoSound() {
        for critical in [false, true] {
            for alarms in [false, true] {
                for timing in DeliveryTiming.allCases {
                    for soundsOnSilent in [false, true] {
                        let n = notice(.sensorExpiringIn24Hours, soundsOnSilent: soundsOnSilent, sound: .doorbell, playsSound: false)
                        XCTAssertEqual(decide(n, critical: critical, alarms: alarms, timing),
                                       DeliveryDecision(interruption: .active, notificationSound: .none, inAppSound: nil))
                        let quiet = notice(.sensorExpiringIn24Hours, soundsOnSilent: soundsOnSilent, silenced: true, sound: .doorbell, playsSound: false)
                        XCTAssertEqual(decide(quiet, critical: critical, alarms: alarms, timing).interruption, .passive)
                    }
                }
            }
        }
        XCTAssertEqual(DeliveryDecision(interruption: .active, notificationSound: .none, inAppSound: nil).loudness, 0)
        let audible = notice(.sensorExpiringIn24Hours, soundsOnSilent: false, sound: .doorbell, playsSound: true)
        XCTAssertEqual(decide(audible, .scheduled),
                       DeliveryDecision(interruption: .timeSensitive, notificationSound: .named(fileName: "alert-doorbell.wav"), inAppSound: nil),
                       "with its sound turned on")
    }

    func test_loudnessOrdering() {
        XCTAssertEqual(DeliveryDecision(interruption: .timeSensitive, notificationSound: .none, inAppSound: nil).loudness, 0)
        XCTAssertEqual(DeliveryDecision(interruption: .timeSensitive, notificationSound: .named(fileName: "x"), inAppSound: nil).loudness, 1)
        XCTAssertEqual(DeliveryDecision(interruption: .passive, notificationSound: .none, inAppSound: InAppSound(fileName: "x", loopSeconds: 0)).loudness, 2)
        XCTAssertEqual(DeliveryDecision(interruption: .timeSensitive, notificationSound: .none, inAppSound: nil, systemAlarmSoundFileName: "x").loudness, 3)
        XCTAssertEqual(DeliveryDecision(interruption: .critical, notificationSound: .critical(fileName: "x", volume: 1), inAppSound: nil).loudness, 3)
        XCTAssertEqual(DeliveryDecision(interruption: .critical, notificationSound: .critical(fileName: AlertSoundCatalog.vibrateFileName, volume: 1),
                                        inAppSound: nil).loudness, 0, "D53: vibrate only is never audible")
        XCTAssertEqual(DeliveryDecision(interruption: .timeSensitive, notificationSound: .named(fileName: AlertSoundCatalog.vibrateFileName),
                                        inAppSound: nil, inAppHaptic: true).loudness, 0)
    }

    func test_alarmIDsAreFixedDistinctAndValid() {
        XCTAssertEqual(SystemAlarmIDs.immediate.uuidString, "5E7A1A7D-0000-4000-8000-000000000000")
        XCTAssertEqual(SystemAlarmIDs.repeatSlot(0).uuidString, "5E7A1A7D-0000-4000-8000-000000000001")
        XCTAssertEqual(SystemAlarmIDs.repeatSlot(29).uuidString, "5E7A1A7D-0000-4000-8000-00000000001E")
        let all = [SystemAlarmIDs.immediate] + SystemAlarmIDs.allRepeats
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertEqual(SystemAlarmIDs.allRepeats.count, AlertLimits.scheduleIDCycle)
        XCTAssertEqual(SystemAlarmIDs.all.count, 1 + AlertLimits.scheduleIDCycle)
    }
}
