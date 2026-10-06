// HANDOFF §10 gate 4 (UI half): the DEBUG app launched on every ReplayKit scenario shows the right
// Now state, keeps the DEBUG/REPLAY banner up, and doesn't crash; a launch with no sensor shows
// onboarding. The alert half (alerts fire when and only when expected) is
// SensorTests/ReplayScenarioTests.
//
// Launch hook (AppEnvironment, DEBUG): `-replayScenario <name> -replaySpeed <x> -replayStartMinute <m>`.
// Every launch also passes DEBUG `-silenceAlertAudio` (a silent alert player, notifications without
// sound), so replayed urgent lows don't ring on the machine running the tests.
// Speed 1 keeps the replay clock equal to the phone clock (the UI classifies staleness against the
// phone clock); `-replayStartMinute m` delivers everything up to scenario minute m at once, dated in
// the past, so each test lands on the moment it checks without waiting. Offsets and values are the
// scenario tables in docs/replay.md.

import XCTest

@MainActor
final class ReplayLaunchUITests: XCTestCase {
    private let timeout: TimeInterval = 30

    /// Launches the app with `arguments` and, always, `-silenceAlertAudio`.
    private func launchApp(_ arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-silenceAlertAudio"] + arguments
        app.launch()
        return app
    }

    private func launch(scenario: String, minute: Int, extra: [String] = []) -> XCUIApplication {
        launchApp(["-replayScenario", scenario, "-replaySpeed", "1", "-replayStartMinute", String(minute)] + extra)
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Waits until the element exists and its accessibility label satisfies `condition`.
    @discardableResult
    private func waitForLabel(_ element: XCUIElement, _ description: String, _ condition: (String) -> Bool) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = "<missing>"
        repeat {
            if element.waitForExistence(timeout: 1) {
                last = element.label
                if condition(last) { return last }
                Thread.sleep(forTimeInterval: 0.3)
            }
        } while Date() < deadline
        XCTFail("\(description); last label: \"\(last)\"")
        return last
    }

    /// The DEBUG/REPLAY banner names the scenario (PROGRESS D19), and onboarding is not shown.
    private func assertReplayBanner(_ app: XCUIApplication, _ scenario: String) {
        waitForLabel(element(app, "build.banner"), "DEBUG/REPLAY banner") { $0.contains("DEBUG BUILD") && $0.contains("REPLAY: \(scenario.uppercased())") }
        XCTAssertFalse(element(app, "onboarding.step").exists, "a replay run never shows onboarding")
    }

    /// The hero's number, from its VoiceOver label ("112 milligrams per deciliter, steady, …").
    private func heroValue(_ label: String) -> Int? {
        Int(label.prefix { $0.isNumber })
    }

    // MARK: - Scenarios

    /// steady: after warm-up, an in-range number (112–114) with a steady trend.
    func test_steadyShowsANumber() {
        let app = launch(scenario: "steady", minute: 60)
        let label = waitForLabel(element(app, "now.hero.reading"), "a current reading") { $0.contains("milligrams per deciliter") }
        XCTAssertTrue((112...114).contains(heroValue(label) ?? 0), label)
        waitForLabel(element(app, "now.stateLine"), "state line") { $0.contains("IN RANGE") }
        assertReplayBanner(app, "steady")
    }

    /// steady during warm-up: no number, the warm-up message (S2: no readings during warm-up).
    func test_steadyWarmUpShowsNoNumber() {
        let app = launch(scenario: "steady", minute: 10)
        waitForLabel(element(app, "now.hero.message"), "warm-up message") { $0.contains("Warming up") }
        XCTAssertFalse(element(app, "now.hero.reading").exists)
        assertReplayBanner(app, "steady")
    }

    /// slowFallToUrgentLow at +111: the sensor's LOW flag is shown as LOW, never as a number (S4).
    func test_slowFallShowsTheLowFlag() {
        let app = launch(scenario: "slowFallToUrgentLow", minute: 111)
        let label = waitForLabel(element(app, "now.hero.reading"), "LOW hero") { $0.hasPrefix("LOW") }
        XCTAssertNil(heroValue(label), "no number for a LOW flag: \(label)")
        XCTAssertFalse(label.contains("40"), label)
        waitForLabel(element(app, "now.stateLine"), "state line") { $0.contains("BELOW SENSOR RANGE") }
        assertReplayBanner(app, "slowFallToUrgentLow")
    }

    /// slowFallToUrgentLow at +86: the urgent-low value as a number (55 at +85).
    func test_slowFallShowsTheUrgentLowValue() {
        let app = launch(scenario: "slowFallToUrgentLow", minute: 86)
        let label = waitForLabel(element(app, "now.hero.reading"), "urgent-low number") { $0.contains("milligrams per deciliter") }
        XCTAssertEqual(heroValue(label), 55, label)
        waitForLabel(element(app, "now.stateLine"), "state line") { $0.contains("LOW") }
        assertReplayBanner(app, "slowFallToUrgentLow")
    }

    /// compressionLowSpike at +46: the compression low as reported (52 at +45).
    func test_compressionLowShowsTheReportedValue() {
        let app = launch(scenario: "compressionLowSpike", minute: 46)
        let label = waitForLabel(element(app, "now.hero.reading"), "compression-low number") { $0.contains("milligrams per deciliter") }
        XCTAssertEqual(heroValue(label), 52, label)
        assertReplayBanner(app, "compressionLowSpike")
    }

    /// signalGapWithBackfill at +50: 20 minutes without a reading — no number, the missed-readings
    /// banner (S5).
    func test_signalGapShowsNoCurrentValueAndTheMissedReadingsBanner() {
        let app = launch(scenario: "signalGapWithBackfill", minute: 50)
        waitForLabel(element(app, "now.hero.message"), "no-data message") { $0.contains("No recent readings") || $0.contains("No reading for") }
        XCTAssertFalse(element(app, "now.hero.reading").exists, "the last number is not shown on its own (S5)")
        waitForLabel(element(app, "banner.missedReadings"), "missed-readings banner") { $0.contains("No reading for") }
        assertReplayBanner(app, "signalGapWithBackfill")
    }

    /// signalGapWithBackfill at +81: after the backfill the newest live reading is current (181 at
    /// +80), not a backfilled one.
    func test_signalGapAfterBackfillShowsTheLiveReading() {
        let app = launch(scenario: "signalGapWithBackfill", minute: 81)
        let label = waitForLabel(element(app, "now.hero.reading"), "live reading after backfill") { $0.contains("milligrams per deciliter") }
        XCTAssertEqual(heroValue(label), 181, label)
        XCTAssertFalse(element(app, "banner.missedReadings").exists)
        assertReplayBanner(app, "signalGapWithBackfill")
    }

    /// sensorExpiry at +161: HIGH flag shown as HIGH during the grace period, with the grace banner.
    func test_sensorExpiryShowsHighAndTheGracePeriod() {
        let app = launch(scenario: "sensorExpiry", minute: 161)
        let label = waitForLabel(element(app, "now.hero.reading"), "HIGH hero") { $0.hasPrefix("HIGH") }
        XCTAssertNil(heroValue(label), "no number for a HIGH flag: \(label)")
        waitForLabel(element(app, "banner.sensorExpiring"), "grace-period banner") { $0.contains("grace period") }
        assertReplayBanner(app, "sensorExpiry")
    }

    /// sensorExpiry at +751: the session has ended — the expiry message, no number.
    func test_sensorExpiryShowsTheExpiryMessage() {
        let app = launch(scenario: "sensorExpiry", minute: 751)
        waitForLabel(element(app, "now.hero.message"), "expiry message") { $0.contains("Sensor expired") }
        XCTAssertFalse(element(app, "now.hero.reading").exists)
        waitForLabel(element(app, "banner.sensorExpired"), "expired banner") { $0.contains("Sensor expired") }
        assertReplayBanner(app, "sensorExpiry")
    }

    // MARK: - Alerts (D43)

    /// The Alerts tab groups the sensor expiry reminders (24 h, 12 h, 2 h, grace start, expired). Each
    /// row has one switch (on/off; review m8: no Sound switch in the list); an announcement's page has
    /// the Sound switch (24 h off by default); urgent low's page has none (S7).
    /// With SENSOR_WRITE_SCREENSHOTS=1 (TEST_RUNNER_ prefix through xcodebuild) it also saves the
    /// list and the 24 h reminder's page to docs/screenshots, named with SENSOR_SCREENSHOT_SCHEME.
    func test_alertsShowTheSensorExpiryReminders() throws {
        let app = launch(scenario: "steady", minute: 60, extra: ["-tab", "alerts"])
        let urgentLow = element(app, "alerts.row.urgentLow")
        XCTAssertTrue(urgentLow.waitForExistence(timeout: timeout))
        urgentLow.tap()
        XCTAssertTrue(app.staticTexts["Urgent low"].waitForExistence(timeout: timeout))
        XCTAssertFalse(element(app, "alerts.detail.sound").exists, "S7: no Sound switch for urgent low")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(urgentLow.waitForExistence(timeout: timeout))
        let first = element(app, "alerts.row.sensorExpiringIn24Hours")
        let last = element(app, "alerts.row.sensorExpired")
        // Scroll until the whole group is on screen (the last row of it visible).
        for _ in 0..<12 where !(last.exists && last.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(first.isHittable && last.isHittable, "the expiry reminders are on the Alerts tab")
        for kind in ["sensorExpiringIn24Hours", "sensorExpiringIn12Hours", "sensorExpiringIn2Hours", "sensorGracePeriod", "sensorExpired"] {
            XCTAssertTrue(element(app, "alerts.row.\(kind)").exists, kind)
            XCTAssertTrue(element(app, "alerts.toggle.\(kind)").exists, "\(kind): its on/off switch")
        }
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'alerts.sound.'")).count, 0,
                       "review m8: no Sound switch in the list")
        try saveScreenshot("alerts-expiry-reminders")
        first.tap()
        XCTAssertTrue(app.staticTexts["Sensor expires in 24 h"].waitForExistence(timeout: timeout))
        let sound = app.switches.matching(identifier: "alerts.detail.sound").firstMatch
        XCTAssertTrue(sound.waitForExistence(timeout: timeout), "the Sound switch is on the reminder's page")
        XCTAssertEqual(sound.value as? String, "0", "24 h: no sound by default")
        try saveScreenshot("alerts-expiry-24h")
    }

    /// Writes the screen to docs/screenshots when asked (see above).
    private func saveScreenshot(_ name: String) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SENSOR_WRITE_SCREENSHOTS"] == "1" else { return }
        let scheme = environment["SENSOR_SCREENSHOT_SCHEME"] ?? "light"
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/screenshots", isDirectory: true)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("\(name)-\(scheme).png"))
    }

    // MARK: - No sensor

    /// A fresh install with no sensor opens onboarding, under the DEBUG banner.
    func test_launchWithNoSensorShowsOnboarding() {
        let app = launchApp(["-resetOnboardingFlag"])
        XCTAssertTrue(element(app, "onboarding.welcome.start").waitForExistence(timeout: timeout), "onboarding's first step")
        waitForLabel(element(app, "build.banner"), "DEBUG banner over onboarding") { $0.contains("DEBUG BUILD") }
    }

    /// Review M1: onboarding can be left, and pairing from inside the app is Settings › Sensor (with
    /// the tab bar), never a full-screen flow without a way out.
    func test_onboardingCanBeLeftAndInAppPairingOpensSettings() {
        let app = launchApp(["-resetOnboardingFlag"])
        XCTAssertTrue(element(app, "onboarding.welcome.start").waitForExistence(timeout: timeout), "onboarding's first step")
        let setUpLater = element(app, "onboarding.dismiss")
        XCTAssertTrue(setUpLater.waitForExistence(timeout: timeout), "every onboarding step offers Set up later")
        setUpLater.tap()
        waitForLabel(element(app, "now.hero.message"), "Now: no sensor paired") { $0.contains("No sensor paired") }
        let pair = element(app, "now.hero.action")
        XCTAssertTrue(pair.waitForExistence(timeout: timeout))
        pair.tap()
        XCTAssertTrue(element(app, "settings.sensor.page").waitForExistence(timeout: timeout), "Settings › Sensor")
        XCTAssertFalse(element(app, "onboarding.step").exists, "not the full-screen onboarding")
        XCTAssertTrue(app.buttons["Trends"].exists && app.buttons["Settings"].exists, "the tab bar is there")
    }
}
