import XCTest
@testable import AlertEngine

/// Which path(s) make each alert audible, for every combination of "Sound on silent", Critical
/// Alert authorization, and app awake (`.now`) vs suspended (`.scheduled`).
final class DeliveryPolicyTests: XCTestCase {
    private func notice(_ kind: AlertKind, soundsOnSilent: Bool, silenced: Bool = false, sound: AlertSoundID = .dusk) -> AlertNotice {
        AlertNotice(kind: kind, title: "t", body: "b", sound: sound, soundsOnSilent: soundsOnSilent,
                    isSilenced: silenced, snoozeMinutes: 30, fireDate: nil)
    }

    private let dusk = "alert-dusk.wav"

    func test_soundOnSilent_awake_noCritical_playsInAppSoundAndPostsTimeSensitiveWithSound() {
        let d = DeliveryPolicy.decide(for: notice(.low, soundsOnSilent: true), criticalAlertsEnabled: false, timing: .now)
        XCTAssertEqual(d, DeliveryDecision(interruption: .timeSensitive, notificationSound: .named(fileName: dusk),
                                           inAppSound: InAppSound(fileName: dusk, loopSeconds: 0)))
    }

    func test_soundOnSilent_suspended_noCritical_isTimeSensitiveOnly() {
        // The documented gap: vibrate-only on silent while the app is suspended (D17).
        let d = DeliveryPolicy.decide(for: notice(.missedReadings, soundsOnSilent: true), criticalAlertsEnabled: false, timing: .scheduled)
        XCTAssertEqual(d, DeliveryDecision(interruption: .timeSensitive, notificationSound: .named(fileName: dusk), inAppSound: nil))
    }

    func test_soundOnSilent_withCriticalGranted_usesCriticalAlertAndNoInAppSound() {
        for timing in DeliveryTiming.allCases {
            let d = DeliveryPolicy.decide(for: notice(.high, soundsOnSilent: true), criticalAlertsEnabled: true, timing: timing)
            XCTAssertEqual(d, DeliveryDecision(interruption: .critical, notificationSound: .critical(fileName: dusk, volume: 1.0), inAppSound: nil))
        }
    }

    func test_soundOnSilentOff_respectsTheRingerSwitchEvenWithCriticalGranted() {
        for critical in [false, true] {
            for timing in DeliveryTiming.allCases {
                let d = DeliveryPolicy.decide(for: notice(.risingFast, soundsOnSilent: false), criticalAlertsEnabled: critical, timing: timing)
                XCTAssertEqual(d, DeliveryDecision(interruption: .timeSensitive, notificationSound: .named(fileName: dusk), inAppSound: nil))
            }
        }
    }

    func test_quietHoursSilenceEverythingButUrgentLow() {
        for kind in AlertKind.allCases where kind != .urgentLow {
            for critical in [false, true] {
                for timing in DeliveryTiming.allCases {
                    let d = DeliveryPolicy.decide(for: notice(kind, soundsOnSilent: true, silenced: true), criticalAlertsEnabled: critical, timing: timing)
                    XCTAssertEqual(d, DeliveryDecision(interruption: .passive, notificationSound: .none, inAppSound: nil), "\(kind)")
                    XCTAssertEqual(d.loudness, 0)
                }
            }
        }
    }

    func test_S7_urgentLowAlwaysGetsTheLoudestAvailablePath() {
        // Whatever the notice claims (even a malformed one that says silenced / not sound-on-silent),
        // urgent low gets the loudest path the situation allows.
        for critical in [false, true] {
            for timing in DeliveryTiming.allCases {
                let loudestPossible = (critical ? 3 : (timing == .now ? 2 : 1))
                for soundsOnSilent in [false, true] {
                    for silenced in [false, true] {
                        let n = notice(.urgentLow, soundsOnSilent: soundsOnSilent, silenced: silenced, sound: .cascade)
                        let d = DeliveryPolicy.decide(for: n, criticalAlertsEnabled: critical, timing: timing)
                        XCTAssertEqual(d.loudness, loudestPossible, "critical \(critical) \(timing) silenced \(silenced)")
                        XCTAssertNotEqual(d.interruption, .passive)
                        XCTAssertNotEqual(d.notificationSound, .none)
                        if !critical && timing == .now {
                            XCTAssertEqual(d.inAppSound, InAppSound(fileName: "alert-cascade.wav", loopSeconds: AlertLimits.urgentInAppAudioSeconds),
                                           "loops for 30 s")
                        }
                    }
                }
            }
        }
    }

    func test_loudnessOrdering() {
        XCTAssertEqual(DeliveryDecision(interruption: .timeSensitive, notificationSound: .none, inAppSound: nil).loudness, 0)
        XCTAssertEqual(DeliveryDecision(interruption: .passive, notificationSound: .none, inAppSound: InAppSound(fileName: "x", loopSeconds: 0)).loudness, 2)
    }
}
