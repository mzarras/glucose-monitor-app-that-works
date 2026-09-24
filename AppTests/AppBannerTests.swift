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
            XCTAssertEqual(result.first?.detail, failure.message, "\(kind): the source's words")
            XCTAssertTrue(banners(.failed(failure), latestAge: 16).contains { $0.kind == .missedReadings && $0.severity == .critical },
                          "\(kind): a lasting failure is covered by missed readings")
        }
        let incomplete = banners(.failed(SensorFailure(kind: .bluetoothPairingIncomplete, message: "m"))).first
        XCTAssertEqual(incomplete?.action, .pairSensor)
        XCTAssertEqual(incomplete?.actionTitle, "Pair again")
    }

    /// D36: an ended sensor or a lost pairing is critical, with the matching call to action.
    func test_S5_endedSensorOrLostPairingIsCritical() {
        for kind in SensorFailure.Kind.allCases {
            let failure = SensorFailure(kind: kind, message: "Message for \(kind)")
            guard failure.raisesSensorAlert else { continue }
            let result = banners(.failed(failure), latestAge: 16)
            guard let banner = result.first else { return XCTFail("\(kind): no banner") }
            XCTAssertEqual(banner.severity, .critical, "\(kind)")
            XCTAssertEqual(banner.detail, failure.message)
            XCTAssertEqual(banner.action, .pairSensor)
            if failure.requiresSensorReplacement {
                XCTAssertEqual(banner.kind, .sensorNeedsReplacement, "\(kind)")
                XCTAssertEqual(banner.actionTitle, "Replace sensor")
            } else {
                XCTAssertEqual(banner.kind, .sensorNeedsPairing, "\(kind)")
                XCTAssertEqual(banner.actionTitle, "Pair again")
            }
            XCTAssertFalse(result.contains { $0.kind == .missedReadings }, "\(kind): its own banner, not missed readings")
        }
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
