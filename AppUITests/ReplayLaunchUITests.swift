// HANDOFF §10 gate 4 (UI half): the DEBUG app launched on every ReplayKit scenario shows the right
// Now state, keeps the DEBUG/REPLAY banner up, and doesn't crash; a launch with no sensor shows
// onboarding. The alert half (alerts fire when and only when expected) is
// SensorTests/ReplayScenarioTests.
//
// Launch hook (AppEnvironment, DEBUG): `-replayScenario <name> -replaySpeed <x> -replayStartMinute <m>`.
// Every launch also passes DEBUG `-silenceAlertAudio` (a silent alert player, notifications without
// sound), so replayed urgent lows don't ring on the machine running the tests, and DEBUG
// `-resetConnectionMode` (pairing mode, recording off), so a D45 mode switch never carries into the
// next test.
// Speed 1 keeps the replay clock equal to the phone clock (the UI classifies staleness against the
// phone clock); `-replayStartMinute m` delivers everything up to scenario minute m at once, dated in
// the past, so each test lands on the moment it checks without waiting. Offsets and values are the
// scenario tables in docs/replay.md.

import XCTest

@MainActor
final class ReplayLaunchUITests: XCTestCase {
    private let timeout: TimeInterval = 30

    /// Launches the app with `arguments` and, always, `-silenceAlertAudio` and `-resetConnectionMode`;
    /// on the Now tab unless `arguments` pick one (the app restores the last tab across launches).
    private func launchApp(_ arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-silenceAlertAudio", "-resetConnectionMode"] + (arguments.contains("-tab") ? [] : ["-tab", "now"]) + arguments
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
        waitForLabel(element(app, "now.hero.message"), "Now: no sensor set up (D45: the choice first)") { $0.contains("No sensor set up") }
        let pair = element(app, "now.hero.action")
        XCTAssertTrue(pair.waitForExistence(timeout: timeout))
        pair.tap()
        XCTAssertTrue(element(app, "settings.sensor.page").waitForExistence(timeout: timeout), "Settings › Sensor")
        XCTAssertFalse(element(app, "onboarding.step").exists, "not the full-screen onboarding")
        XCTAssertTrue(app.buttons["Trends"].exists && app.buttons["Settings"].exists, "the tab bar is there")
    }

    // MARK: - D45 listen mode (no real G7 here: the live source in the simulator, or a replay)

    /// Taps a confirmation dialog's button (an action sheet or a popover, depending on the OS).
    private func confirm(_ app: XCUIApplication, _ title: String) {
        let button = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "confirmation \"\(title)\"")
        button.tap()
    }

    /// Scrolls until the element is on screen.
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), element.debugDescription)
        for _ in 0..<8 where !element.isHittable { app.swipeUp(velocity: .slow) }
    }

    private func assertSharingSwitches(_ app: XCUIApplication, enabled: Bool) {
        for id in ["settings.nightscout.toggle", "settings.share.toggle"] {
            let toggle = app.switches[id].firstMatch
            reveal(app, toggle)
            XCTAssertEqual(toggle.isEnabled, enabled, "\(id) enabled: \(enabled)")
            if !enabled { XCTAssertEqual(toggle.value as? String, "0", "\(id) shows off while listening") }
        }
    }

    /// Onboarding: choose listening; the flow skips removing the Dexcom app and pairing, ends on the
    /// Listening step; afterwards Settings shows the mode and the sharing switches are off and disabled.
    func test_listenModeInOnboarding() throws {
        let app = launchApp(["-resetOnboardingFlag", "-onboarding"])
        element(app, "onboarding.welcome.start").tap()
        XCTAssertTrue(element(app, "connection.listen").waitForExistence(timeout: timeout), "the connection step")
        try saveScreenshot("listen-onboarding-connection")
        element(app, "connection.listen").tap()
        element(app, "onboarding.connection.continue").tap()
        XCTAssertTrue(element(app, "onboarding.import.skip").waitForExistence(timeout: timeout), "on to the import step")
        element(app, "onboarding.import.skip").tap()
        let permissions = element(app, "onboarding.permissions.continue")
        XCTAssertTrue(permissions.waitForExistence(timeout: timeout))
        XCTAssertFalse(element(app, "onboarding.removeDexcom.continue").exists, "listening keeps the Dexcom app")
        permissions.tap()
        let alarms = element(app, "onboarding.alarms.continue")
        if alarms.waitForExistence(timeout: 3) { alarms.tap() }
        XCTAssertTrue(element(app, "connection.listeningStatus").waitForExistence(timeout: timeout), "the Listening step")
        XCTAssertTrue(element(app, "onboarding.listen.continue").exists)
        try saveScreenshot("listen-onboarding-listening")
        element(app, "onboarding.listen.continue").tap()
        let done = element(app, "onboarding.done")
        XCTAssertTrue(done.waitForExistence(timeout: timeout))
        done.tap()

        waitForLabel(element(app, "now.trioRow"), "Now: Trio off while listening") { $0.contains("off while listening") }
        let nowLine = element(app, "connection.listeningStatus")
        reveal(app, nowLine)
        XCTAssertTrue(nowLine.isHittable, "Now: the listening line")
        try saveScreenshot("listen-now")
        app.buttons["Settings"].tap()
        waitForLabel(element(app, "settings.connection"), "Settings: listening") { $0.contains("listening alongside Dexcom") }
        waitForLabel(element(app, "settings.trio"), "Settings: Trio off while listening") { $0.contains("off while listening") }
        try saveScreenshot("listen-settings")
        element(app, "settings.nightscout").tap()
        assertSharingSwitches(app, enabled: false)
        try saveScreenshot("listen-sharing")
    }

    /// Settings › Sensor: switch to listening and back (each confirmed); the page, the sharing
    /// switches and Now follow each switch.
    func test_listenModeInSettingsAndBack() throws {
        let app = launchApp(["-tab", "settings"])
        // A fresh simulator offers onboarding first (no sensor): leave it.
        let setUpLater = element(app, "onboarding.dismiss")
        if setUpLater.waitForExistence(timeout: 5) { setUpLater.tap() }
        let sensorRow = element(app, "settings.sensor")
        XCTAssertTrue(sensorRow.waitForExistence(timeout: timeout))
        sensorRow.tap()
        let listen = element(app, "connection.listen")
        reveal(app, listen)
        listen.tap()
        confirm(app, "Listen alongside the Dexcom app")
        XCTAssertTrue(element(app, "connection.listeningStatus").waitForExistence(timeout: timeout), "the listening line")
        XCTAssertTrue(element(app, "settings.sensor.listeningNotes").exists, "calibrate and pair explained, not offered")
        XCTAssertFalse(app.buttons["Calibrate with a fingerstick…"].exists)
        XCTAssertFalse(element(app, "settings.sensor.forget").exists, "no Forget while listening…")
        let stopFollowing = element(app, "settings.sensor.stopFollowing")
        reveal(app, stopFollowing)
        XCTAssertTrue(stopFollowing.isHittable, "…but Stop following this sensor (G7Kit §14)")
        try saveScreenshot("listen-sensor-page")
        // Stop following (confirmed): the sensor is forgotten; the page no longer offers it.
        stopFollowing.tap()
        confirm(app, "Stop following this sensor")
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: stopFollowing)
        waitForExpectations(timeout: timeout)
        XCTAssertTrue(element(app, "connection.listeningStatus").exists, "still listening")
        app.navigationBars.buttons.firstMatch.tap()
        element(app, "settings.nightscout").tap()
        assertSharingSwitches(app, enabled: false)
        app.navigationBars.buttons.firstMatch.tap()

        // Back to pairing.
        sensorRow.tap()
        let pair = element(app, "connection.pair")
        reveal(app, pair)
        pair.tap()
        confirm(app, "Pair this app")
        expectation(for: gone, evaluatedWith: element(app, "connection.listeningStatus"))
        waitForExpectations(timeout: timeout)
        XCTAssertFalse(element(app, "settings.sensor.listeningNotes").exists)
        app.navigationBars.buttons.firstMatch.tap()
        element(app, "settings.nightscout").tap()
        assertSharingSwitches(app, enabled: true)
        app.navigationBars.buttons.firstMatch.tap()
        // "Now" or "Now, needs attention" (no sensor here).
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Now'")).firstMatch.tap()
        waitForLabel(element(app, "now.trioRow"), "Now: Trio row back to its usual words") { !$0.contains("listening") }
    }

    /// A replay run refuses a mode switch (`.replayActive`): the page says why; nothing changed.
    func test_replayRefusesAConnectionSwitch() throws {
        let app = launch(scenario: "steady", minute: 60, extra: ["-tab", "settings"])
        let sensorRow = element(app, "settings.sensor")
        XCTAssertTrue(sensorRow.waitForExistence(timeout: timeout))
        sensorRow.tap()
        let listen = element(app, "connection.listen")
        reveal(app, listen)
        listen.tap()
        confirm(app, "Listen alongside the Dexcom app")
        let message = element(app, "settings.connection.message")
        waitForLabel(message, "the refusal is shown") { $0.contains("replay is running") && $0.contains("Nothing changed") }
        XCTAssertFalse(element(app, "connection.listeningStatus").exists, "still pairing mode")
        reveal(app, message)
        try saveScreenshot("listen-replay-refused")
    }

    /// D45, no accidental eviction: a first run makes the person choose listen or pair, nothing
    /// preselected and no code field until "Pair" is chosen; the pairing step says, before the code
    /// field, that pairing takes over the Dexcom app's connection. Settings › Sensor is the same:
    /// no code field until "Pair this app" is chosen and confirmed.
    func test_firstRunMakesThePersonChooseBeforeAnyCodeField() throws {
        let app = launchApp(["-resetOnboardingFlag", "-onboarding"])
        element(app, "onboarding.welcome.start").tap()
        let listen = element(app, "connection.listen")
        let pair = element(app, "connection.pair")
        XCTAssertTrue(listen.waitForExistence(timeout: timeout), "the connection step comes first")
        XCTAssertFalse(listen.isSelected || pair.isSelected, "nothing preselected")
        XCTAssertFalse(element(app, "onboarding.connection.continue").exists, "no way on without a choice")
        XCTAssertFalse(element(app, "pairing.code").exists, "no code field")
        pair.tap()
        XCTAssertTrue(pair.isSelected)
        element(app, "onboarding.connection.continue").tap()
        let skip = element(app, "onboarding.import.skip")
        XCTAssertTrue(skip.waitForExistence(timeout: timeout))
        skip.tap()
        let removed = element(app, "onboarding.removeDexcom.continue")
        XCTAssertTrue(removed.waitForExistence(timeout: timeout), "pairing keeps the Remove the Dexcom app step")
        let share = app.switches.firstMatch
        if share.exists, share.value as? String == "1" { share.tap() } // no Share account here
        removed.tap()
        let permissions = element(app, "onboarding.permissions.continue")
        XCTAssertTrue(permissions.waitForExistence(timeout: timeout))
        permissions.tap()
        let alarms = element(app, "onboarding.alarms.continue")
        if alarms.waitForExistence(timeout: 3) { alarms.tap() }
        let warning = element(app, "onboarding.pairing.takeoverWarning")
        let code = element(app, "pairing.code")
        XCTAssertTrue(warning.waitForExistence(timeout: timeout), "the takeover warning on the pairing step")
        XCTAssertTrue(warning.label.contains("Pairing takes over the sensor's connection: the Dexcom app on this phone will stop receiving readings. Delete the Dexcom app first."))
        XCTAssertTrue(code.exists)
        XCTAssertLessThan(warning.frame.minY, code.frame.minY, "said before the code field")
        try saveScreenshot("first-run-pairing-warning")

        // Choosing Pair (above) was recorded: the hero now offers pairing.
        element(app, "onboarding.dismiss").tap()
        waitForLabel(element(app, "now.hero.message"), "Now after choosing Pair") { $0.contains("No sensor paired") }
        app.terminate()

        // A fresh install that leaves onboarding without choosing: Now offers the choice, and
        // Settings › Sensor shows it first, with no code field.
        let fresh = launchApp(["-resetOnboardingFlag"])
        let setUpLater = element(fresh, "onboarding.dismiss")
        XCTAssertTrue(setUpLater.waitForExistence(timeout: timeout))
        setUpLater.tap()
        try checkSettingsChoiceOnAFreshInstall(fresh)
    }

    private func checkSettingsChoiceOnAFreshInstall(_ app: XCUIApplication) throws {
        waitForLabel(element(app, "now.hero.message"), "Now: no sensor set up") { $0.contains("No sensor set up") }
        element(app, "now.hero.action").tap()
        XCTAssertTrue(element(app, "settings.sensor.page").waitForExistence(timeout: timeout))
        let settingsPair = element(app, "connection.pair")
        XCTAssertTrue(settingsPair.waitForExistence(timeout: timeout))
        XCTAssertFalse(settingsPair.isSelected || element(app, "connection.listen").isSelected, "nothing preselected in Settings either")
        XCTAssertFalse(element(app, "pairing.code").exists, "no code field before the choice")
        try saveScreenshot("first-run-settings-choice")
        settingsPair.tap()
        let message = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Pairing takes over the sensor's connection")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: timeout), "the confirmation says it plainly")
        confirm(app, "Pair this app")
        let settingsWarning = element(app, "settings.sensor.takeoverWarning")
        XCTAssertTrue(settingsWarning.waitForExistence(timeout: timeout))
        XCTAssertTrue(element(app, "pairing.code").exists, "the code field once Pair is chosen")
        XCTAssertLessThan(settingsWarning.frame.minY, element(app, "pairing.code").frame.minY, "said before the code field")
    }
}
