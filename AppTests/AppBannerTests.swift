import GlucoseCore
import XCTest
@testable import Sensor

/// S5: every "fail loud" condition surfaces as a visible banner on the Now screen.
final class AppBannerTests: XCTestCase {
    private func banners(_ state: SensorState = activeSensor, latestAge: Double? = 3, health: ServiceHealth = healthy, now: Date = t0) -> [AppBanner] {
        AppBanners.make(sensorState: state, latestLiveReadingDate: latestAge.map { minutes(-$0, from: now) }, health: health, now: now, context: testContext)
    }

    func test_S5_healthyStateShowsNoBanner() {
        XCTAssertEqual(banners(), [])
    }

    func test_S5_eachConditionMapsToAVisibleBanner() {
        var trio = healthy; trio.trio = .failing(since: minutes(-18), message: "App Group write failed")
        var nightscout = healthy; nightscout.nightscout = .failing(failureCount: 3, lastError: "HTTP 401", since: minutes(-20))
        var share = healthy; share.dexcomShare = .failing(failureCount: 1, lastError: "Login failed", since: minutes(-5))
        var denied = healthy; denied.notifications = .denied
        var quiet = healthy; quiet.notifications = .provisional
        var volume = healthy; volume.alarmVolume = .tooLow(level: 0.1)
        var alarm = healthy; alarm.urgentLowAlarm = .denied
        var forceQuit = healthy; forceQuit.forceQuitGap = ForceQuitGap(from: minutes(-300), to: minutes(-210))

        let cases: [(String, [AppBanner], AppBanner.Kind, AppBanner.Severity)] = [
            ("no reading for 15 min", banners(latestAge: 15), .missedReadings, .critical),
            ("no reading at all after warm-up", banners(latestAge: nil), .missedReadings, .critical),
            ("Bluetooth off", banners(.bluetoothUnavailable(.poweredOff)), .bluetoothOff, .critical),
            ("Bluetooth unauthorized", banners(.bluetoothUnavailable(.unauthorized)), .bluetoothUnauthorized, .critical),
            ("Bluetooth unsupported", banners(.bluetoothUnavailable(.unsupported)), .bluetoothUnavailable, .critical),
            ("Bluetooth resetting", banners(.bluetoothUnavailable(.resetting)), .bluetoothUnavailable, .warning),
            ("sensor error", banners(.error(code: 7, description: "Signal error")), .sensorError, .critical),
            ("sensor failed (D36)", banners(.failed(SensorFailure(kind: .sensorFailed, message: "Sensor failed"))), .sensorNeedsReplacement, .critical),
            ("pairing lost (D36)", banners(.failed(SensorFailure(kind: .bondRemoved, message: "Pair again"))), .sensorNeedsPairing, .critical),
            ("transient failure (D36)", banners(.failed(SensorFailure(kind: .otherAppRejected, message: "Another app"))), .sensorInterrupted, .warning),
            ("calibration needed (D36)", banners(.calibrationNeeded(code: 4)), .calibrationNeeded, .critical),
            ("calibration error (D36)", banners(.calibrationError(code: 8)), .calibrationNeeded, .critical),
            ("sensor expired", banners(.expired), .sensorExpired, .critical),
            ("grace period over", banners(.gracePeriod(endsAt: minutes(-1))), .sensorExpired, .critical),
            ("grace period", banners(.gracePeriod(endsAt: minutes(300))), .sensorExpiring, .warning),
            ("expiring within 24 h", banners(.active(sessionStart: minutes(-9 * 1_440), expiresAt: minutes(5 * 60))), .sensorExpiring, .warning),
            ("Trio bridge failing", banners(health: trio), .trioBridgeFailing, .critical),
            ("notifications denied", banners(health: denied), .notificationsDisabled, .critical),
            ("notifications provisional", banners(health: quiet), .notificationsDisabled, .critical),
            ("alarm volume too low", banners(health: volume), .alarmVolumeTooLow, .warning),
            ("urgent low alarm not allowed (D26, review m6)", banners(health: alarm), .urgentLowAlarmOff, .critical),
            ("Nightscout upload failing", banners(health: nightscout), .nightscoutUploadFailing, .warning),
            ("Dexcom Share upload failing", banners(health: share), .shareUploadFailing, .warning),
            ("force-quit gap", banners(health: forceQuit), .forceQuitGap, .warning),
        ]
        for (name, result, kind, severity) in cases {
            guard let banner = result.first(where: { $0.kind == kind }) else {
                XCTFail("\(name): no \(kind) banner in \(result.map(\.kind))")
                continue
            }
            XCTAssertEqual(banner.severity, severity, name)
            XCTAssertFalse(banner.title.isEmpty, name)
            XCTAssertFalse(banner.detail.isEmpty, name)
        }
    }

    func test_S5_missedReadingsBannerAt15Minutes() {
        XCTAssertNil(banners(latestAge: 14.99).first { $0.kind == .missedReadings })
        let banner = banners(latestAge: 15).first { $0.kind == .missedReadings }
        XCTAssertEqual(banner?.title, "No reading for 15 min")
        XCTAssertEqual(banners(latestAge: 75).first { $0.kind == .missedReadings }?.title, "No reading for 1 h 15 min")
        // Also while Bluetooth is off (two banners: the cause and the consequence).
        XCTAssertEqual(Set(banners(.bluetoothUnavailable(.poweredOff), latestAge: 20).map(\.kind)), [.missedReadings, .bluetoothOff])
    }

    func test_missedReadingsBannerNotRaisedWhenNoSensorIsExpectedToSend() {
        XCTAssertEqual(banners(.notPaired, latestAge: nil), [])
        XCTAssertEqual(banners(.warmingUp(endsAt: minutes(30)), latestAge: nil), [])
        // Once warm-up should be over, silence is a problem again.
        XCTAssertEqual(banners(.warmingUp(endsAt: minutes(-1)), latestAge: nil).map(\.kind), [.missedReadings])
    }

    /// Review M1: a reading dated ahead of the phone's clock raises the missed-readings banner.
    func test_S5_futureDatedReadingIsNeverShownAsCurrent() {
        for ahead in [5.0, 60, 600] {
            let result = banners(latestAge: -ahead)
            let banner = result.first { $0.kind == .missedReadings }
            XCTAssertEqual(banner?.severity, .critical, "\(ahead) min ahead")
            XCTAssertEqual(banner?.title, "No current reading", "\(ahead) min ahead")
            XCTAssertTrue(banner?.detail.contains("doesn't match this phone's clock") ?? false)
        }
        XCTAssertNil(banners(latestAge: -0.5).first { $0.kind == .missedReadings }, "within the 60 s tolerance")
    }

    /// D36: transient failures are a warning banner with the source's message — never the critical
    /// "replace/pair" banner — and the missed-readings banner still appears if they last 15 min.
    func test_S5_transientFailureIsAWarningNotCritical() {
        for kind in SensorFailure.Kind.allCases where !SensorFailure(kind: kind, message: "").raisesSensorAlert {
            let failure = SensorFailure(kind: kind, message: "Message for \(kind)")
            let result = banners(.failed(failure), latestAge: 3)
            XCTAssertEqual(result.map(\.kind), [.sensorInterrupted], "\(kind)")
            XCTAssertEqual(result.first?.severity, .warning, "\(kind)")
            XCTAssertTrue(result.first?.detail.hasPrefix(failure.message) ?? false, "\(kind): the source's words first")
            XCTAssertTrue(banners(.failed(failure), latestAge: 16).contains { $0.kind == .missedReadings && $0.severity == .critical },
                          "\(kind): a lasting failure is covered by missed readings")
        }
        // Review M1: nothing to type — accept the iOS request at the next connection.
        let incomplete = banners(.failed(SensorFailure(kind: .bluetoothPairingIncomplete, message: "m"))).first
        XCTAssertNil(incomplete?.action)
        XCTAssertTrue(incomplete?.detail.contains(PairingGuidance.acceptPrompt) ?? false)
    }

    /// D36: an ended sensor or a lost pairing is critical, with the matching call to action.
    func test_S5_endedSensorOrLostPairingIsCritical() {
        for kind in SensorFailure.Kind.allCases {
            let failure = SensorFailure(kind: kind, message: "Message for \(kind)")
            guard failure.raisesSensorAlert else { continue }
            let result = banners(.failed(failure), latestAge: 16)
            guard let banner = result.first else { return XCTFail("\(kind): no banner") }
            XCTAssertEqual(banner.severity, .critical, "\(kind)")
            if failure.requiresSensorReplacement {
                XCTAssertEqual(banner.kind, .sensorNeedsReplacement, "\(kind)")
                XCTAssertEqual(banner.detail, failure.message)
                XCTAssertEqual(banner.action, .pairSensor, "new-sensor flow")
                XCTAssertEqual(banner.actionTitle, "Replace sensor")
            } else if failure.requiresPairing {
                // Review M1: pair the worn sensor again (Settings › Sensor → pairAgain(code:)).
                XCTAssertEqual(banner.kind, .sensorNeedsPairing, "\(kind)")
                XCTAssertEqual(banner.action, .pairAgain)
                XCTAssertEqual(banner.actionTitle, "Pair again")
                XCTAssertEqual(banner.detail, PairingGuidance.pairAgainDetail(failure))
            } else {
                // D37: unclassified.
                XCTAssertEqual(banner.kind, .sensorProblem, "\(kind)")
                XCTAssertEqual(banner.title, "Sensor problem")
                XCTAssertEqual(banner.detail, failure.message)
            }
            XCTAssertFalse(result.contains { $0.kind == .missedReadings }, "\(kind): its own banner, not missed readings")
        }
    }

    /// D37: a failure the source could not classify is critical, never a quiet warning.
    func test_S5_unclassifiedFailureIsCritical() {
        let unknown = SensorFailure(kind: .other, message: "Unrecognised sensor status.")
        let result = banners(.failed(unknown), latestAge: 3)
        XCTAssertEqual(result.map(\.kind), [.sensorProblem])
        XCTAssertEqual(result.first?.severity, .critical)
        XCTAssertEqual(result.first?.detail, unknown.message)
    }

    /// Review minor 4: after "calibration needed", a transient clock mismatch keeps the calibration
    /// banner (the sensor still needs calibrating) next to the clock warning.
    func test_S5_calibrationNeedSurvivesATransientFailure() {
        var need = CalibrationNeed.update(previous: false, sensorState: .calibrationNeeded(code: 4))
        XCTAssertTrue(need)
        let clock = SensorState.failed(SensorFailure(kind: .clockMismatch, message: "Check the phone's clock."))
        need = CalibrationNeed.update(previous: need, sensorState: clock)
        XCTAssertTrue(need, "a transient failure keeps the need")
        let result = AppBanners.make(sensorState: clock, latestLiveReadingDate: minutes(-3), health: healthy, now: t0,
                                     sensorNeedsCalibration: need, context: testContext)
        XCTAssertEqual(result.map(\.kind), [.calibrationNeeded, .sensorInterrupted])
        XCTAssertEqual(result.first?.action, .openCalibration)
        // Calibration itself is refused with the clock reason (G7Kit would answer invalidTime).
        let calibration = CalibrationViewState(sensorState: clock, latestLiveReading: nil, acceptedRange: 40...400, lastSubmission: nil)
        XCTAssertEqual(CalibrationRules.availability(calibration, now: t0), .unavailable(reason: CalibrationRules.clockMismatchReason))
        XCTAssertEqual(CalibrationRules.clockMismatchReason, "Phone clock doesn't match — fix Date & Time first.")
        // Readings resuming, or the sensor/pairing ending, clears it.
        XCTAssertFalse(CalibrationNeed.update(previous: true, sensorState: activeSensor))
        XCTAssertFalse(CalibrationNeed.update(previous: true, sensorState: .failed(SensorFailure(kind: .sensorFailed, message: "m"))))
        XCTAssertTrue(CalibrationNeed.update(previous: true, sensorState: .searching))
        XCTAssertTrue(CalibrationNeed.update(previous: true, sensorState: .error(code: 1, description: "temporary")))
        XCTAssertFalse(CalibrationNeed.update(previous: false, sensorState: clock))
    }

    func test_calibrationBannerOpensCalibration() {
        for state in [SensorState.calibrationNeeded(code: 4), .calibrationError(code: 8)] {
            let banner = banners(state, latestAge: 30).first
            XCTAssertEqual(banner?.kind, .calibrationNeeded)
            XCTAssertEqual(banner?.action, .openCalibration)
            XCTAssertEqual(banners(state, latestAge: 30).count, 1, "no missed-readings banner on top")
        }
    }

    func test_urgentLowAlarmNotAvailableIsNotAProblem() {
        var health = healthy
        health.urgentLowAlarm = .unavailable
        XCTAssertEqual(banners(health: health), [], "older iOS falls back to D17; nothing to fix")
        health.urgentLowAlarm = .notDetermined
        XCTAssertEqual(banners(health: health), [])
    }

    func test_criticalBannersComeFirst() {
        var health = healthy
        health.nightscout = .failing(failureCount: 2, lastError: "timeout", since: minutes(-10))
        health.notifications = .denied
        let result = banners(.bluetoothUnavailable(.poweredOff), latestAge: 20, health: health)
        XCTAssertEqual(result.map(\.kind), [.missedReadings, .bluetoothOff, .notificationsDisabled, .nightscoutUploadFailing])
    }

    func test_nowStateBannersUseTheLatestLiveReading() {
        var state = NowViewState.empty
        state.sensorState = activeSensor
        state.latestLiveReading = latest(.mgdl(105), ageMinutes: 16)
        XCTAssertEqual(state.banners(now: t0, context: testContext).map(\.kind), [.missedReadings])
        state.latestLiveReading = latest(.mgdl(105), ageMinutes: 1)
        XCTAssertEqual(state.banners(now: t0, context: testContext), [])
    }
}
