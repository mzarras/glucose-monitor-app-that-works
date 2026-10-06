import G7Kit
import GlucoseCore
import WidgetCore
import XCTest
@testable import Sensor

/// D45 listen mode and D47 packet recording, screens and model side: the facade's mode and flags
/// reach every screen, the switches go to the facade (refusals shown, nothing changed), and the
/// rules the screens apply while listening.
@MainActor
final class ListenModeWiringTests: XCTestCase {
    private func launch(_ services: PreviewAppServices, onboardingCompleted: Bool = true) -> AppModel {
        let defaults = UserDefaults(suiteName: "ListenModeWiringTests.\(UUID().uuidString)")!
        let preferences = AppUIPreferences(defaults: defaults)
        preferences.onboardingCompleted = onboardingCompleted
        let model = AppModel.launch(services: services, arguments: [], preferences: preferences, clock: { t0 },
                                    protectedDataAvailable: { true })
        model.apply(.sensor)
        return model
    }

    // MARK: - The facade's mode on every screen

    func test_modeReachesEveryScreen() {
        let services = PreviewAppServices(sensorState: .notPaired)
        let model = launch(services)
        XCTAssertEqual(model.settings.connection, ConnectionModeState(mode: nil), "a new install's stored .pair is not shown as the choice")
        XCTAssertFalse(model.settings.isListening)
        XCTAssertEqual(model.now.connection?.mode, .pair)
        XCTAssertFalse(model.now.connectionChosen)
        XCTAssertFalse(model.calibration.listening)
        XCTAssertEqual(model.settings.packetRecording, PacketRecordingState(isOn: false), "D47: off by default")

        services.connectionMode = .listen
        services.trio = TrioBridgeSummary.off
        services.trio.isEnabled = true
        services.trio.liveOutputsAllowed = true
        services.trio.offWhileListening = true
        services.recordsRawGlucosePackets = true
        model.apply(.sensor)
        model.apply(.trio)
        XCTAssertTrue(model.settings.isListening, "listening counts as chosen")
        XCTAssertTrue(model.now.connectionChosen)
        XCTAssertEqual(model.now.connection?.mode, .listen)
        XCTAssertTrue(model.calibration.listening)
        XCTAssertEqual(CalibrationRules.availability(model.calibration, now: t0), .unavailable(reason: ConnectionModeText.calibrationWhileListening))
        XCTAssertEqual(model.settings.packetRecording, PacketRecordingState(isOn: true))
        XCTAssertEqual(model.now.health.trio, .off, "the handoff is off in the services; no Trio problem shows")
        XCTAssertEqual(ListenModeRules.outputRow(TrioStatusText.row(model.now.health.trio), listening: model.settings.isListening), "off while listening")
    }

    // MARK: - Settings › Sensor

    func test_settingsSwitchesTheModeThroughTheFacade() async {
        let services = PreviewAppServices(sensorState: .notPaired)
        let model = launch(services)
        model.setConnectionMode(.listen)
        XCTAssertEqual(model.settings.connectionSwitchingTo, .listen, "the choices wait for the switch")
        await model.settle()
        XCTAssertEqual(services.calls.last, "setConnectionMode(listen)")
        _ = await eventually { model.settings.connection?.mode == .listen }
        XCTAssertEqual(model.settings.connection?.mode, .listen)
        XCTAssertNil(model.settings.connectionSwitchingTo)
        XCTAssertNil(model.settings.feedback.connection)
        XCTAssertEqual(model.settings.sensor.state, .searching, "listening starts at once")

        // And back: the UI follows a second switch.
        model.setConnectionMode(.pair)
        await model.settle()
        _ = await eventually { model.settings.connection?.mode == .pair }
        XCTAssertEqual(model.settings.connection?.mode, .pair)
        XCTAssertFalse(model.calibration.listening)
    }

    /// A refused switch (e.g. a replay is running) shows why; nothing changed.
    func test_settingsShowsARefusedSwitch() async {
        for error in [ConnectionModeError.replayActive, .couldNotSave("disk full"), .credentialStoreFailed("locked")] {
            let services = PreviewAppServices(sensorState: .notPaired)
            services.connectionModeError = error
            let model = launch(services)
            model.setConnectionMode(.listen)
            await model.settle()
            XCTAssertEqual(model.settings.feedback.connection, ConnectionModeText.errorText(error))
            XCTAssertNil(model.settings.connection?.mode, "nothing changed (still not chosen)")
            XCTAssertEqual(services.connectionMode, .pair)
            XCTAssertNil(model.settings.connectionSwitchingTo)
        }
        XCTAssertTrue(ConnectionModeText.errorText(.replayActive).contains("Stop the replay"))
        XCTAssertTrue(ConnectionModeText.errorText(.couldNotSave("disk full")).contains("disk full"))
    }

    /// A new install: choosing "Pair this app" (the facade is already in pairing mode) records the
    /// choice without a switch; from then on Settings shows it and Now offers pairing.
    func test_choosingPairOnANewInstallRecordsTheChoice() async {
        let services = PreviewAppServices(sensorState: .notPaired)
        let model = launch(services)
        XCTAssertNil(model.settings.connection?.mode)
        model.setConnectionMode(.pair)
        await model.settle()
        XCTAssertFalse(services.calls.contains { $0.hasPrefix("setConnectionMode") }, "already pairing mode: nothing to switch")
        XCTAssertEqual(model.settings.connection?.mode, .pair)
        XCTAssertTrue(model.now.connectionChosen)
        model.apply(.sensor)
        XCTAssertEqual(model.settings.connection?.mode, .pair, "remembered")
    }

    /// An install from before D45 with a paired sensor has evidently chosen pairing.
    func test_aStoredSensorCountsAsChosen() {
        let services = PreviewAppServices(sensorState: .searching)
        services.hasStoredSensor = true
        let model = launch(services)
        XCTAssertEqual(model.settings.connection?.mode, .pair)
    }

    func test_packetRecordingSwitch() async {
        let services = PreviewAppServices(sensorState: .notPaired)
        let model = launch(services)
        model.setPacketRecording(true)
        await model.settle()
        XCTAssertEqual(services.calls.last, "setRecordsRawGlucosePackets(true)")
        _ = await eventually { model.settings.packetRecording?.isOn == true }
        XCTAssertEqual(model.settings.packetRecording?.isOn, true)
    }

    // MARK: - Onboarding

    /// The connection step: nothing preselected in pairing mode; the choice is applied on Continue;
    /// listening skips removing the Dexcom app and pairing, and offers no Share upload by default.
    func test_onboardingConnectionStep() async {
        let services = PreviewAppServices(sensorState: .notPaired)
        let model = launch(services, onboardingCompleted: false)
        guard let onboarding = model.onboarding else { return XCTFail("onboarding shows") }
        XCTAssertEqual(onboarding.connection, ConnectionModeState(mode: nil))
        XCTAssertEqual(onboarding.step(after: .welcome), .connection)
        XCTAssertTrue(onboarding.shareUploadEnabled, "D7: Share on by default when pairing")

        model.goToOnboardingStep(.connection)
        model.chooseOnboardingConnection(.listen)
        XCTAssertEqual(model.onboarding?.shareUploadEnabled, false, "listening: no Share upload by default")
        XCTAssertEqual(services.connectionMode, .pair, "nothing switched before Continue")
        model.continueFromConnectionStep()
        await model.settle()
        XCTAssertEqual(services.connectionMode, .listen)
        XCTAssertEqual(model.onboarding?.step, .importHistory)
        XCTAssertEqual(model.onboarding?.visibleSteps.contains(.removeDexcomApp), false)
        XCTAssertEqual(model.onboarding?.visibleSteps.contains(.listen), true)
        _ = await eventually { model.onboarding?.currentConnectionMode == .listen }

        // Back to pairing: Share is offered on again.
        model.goToOnboardingStep(.connection)
        model.chooseOnboardingConnection(.pair)
        XCTAssertEqual(model.onboarding?.shareUploadEnabled, true)
        model.continueFromConnectionStep()
        await model.settle()
        XCTAssertEqual(services.connectionMode, .pair)
        XCTAssertEqual(model.onboarding?.visibleSteps.contains(.removeDexcomApp), true)
    }

    func test_onboardingShowsARefusedSwitch() async {
        let services = PreviewAppServices(sensorState: .notPaired)
        services.connectionModeError = .replayActive
        let model = launch(services, onboardingCompleted: false)
        model.goToOnboardingStep(.connection)
        model.chooseOnboardingConnection(.listen)
        model.continueFromConnectionStep()
        await model.settle()
        XCTAssertEqual(model.onboarding?.step, .connection, "stays on the step")
        XCTAssertEqual(model.onboarding?.connectionMessage, ConnectionModeText.errorText(.replayActive))
        XCTAssertEqual(model.onboarding?.connectionSwitching, false)
        XCTAssertEqual(services.connectionMode, .pair)
    }

    /// Already listening: the step still preselects nothing (the person always chooses), Share
    /// isn't on by default, and choosing listening again switches nothing.
    func test_onboardingWhileAlreadyListening() async {
        let services = PreviewAppServices(sensorState: .searching)
        services.connectionMode = .listen
        let model = launch(services, onboardingCompleted: false)
        model.presentOnboarding(at: .welcome)
        XCTAssertEqual(model.onboarding?.connection, ConnectionModeState(mode: nil))
        XCTAssertEqual(model.onboarding?.shareUploadEnabled, false)
        model.goToOnboardingStep(.connection)
        model.chooseOnboardingConnection(.listen)
        model.continueFromConnectionStep()
        await model.settle()
        XCTAssertEqual(model.onboarding?.step, .importHistory)
        XCTAssertFalse(services.calls.contains { $0.hasPrefix("setConnectionMode") }, "no switch needed")
    }

    // MARK: - Listen-mode failures (S5: visible, in clear words)

    func test_listenFailuresStayVisibleInClearWords() {
        let cases: [(SensorFailure, String, String)] = [
            (G7FailureReason.listenSessionLengthUnknown, "Waiting for session details", "waiting for session details"),
            (G7FailureReason.listenNoAuthenticatedConnection, "Connection not confirmed", "connection not confirmed"),
            (G7FailureReason.listenConnectionRejected, "Sensor rejected the connection", "connection rejected"),
        ]
        for (failure, title, row) in cases {
            let state = SensorState.failed(failure)
            let banners = AppBanners.make(sensorState: state, latestLiveReadingDate: t0, health: healthy, now: t0, listening: true)
            XCTAssertEqual(banners.first { $0.kind == .sensorInterrupted }?.title, title)
            XCTAssertFalse(banners.first { $0.kind == .sensorInterrupted }?.detail.isEmpty ?? true)
            XCTAssertEqual(SensorStatusText.connection(state, listening: true), row)
            XCTAssertTrue(SensorStatusText.row(state, now: t0, listening: true).contains(row))
            // Pairing mode keeps the source's general wording.
            XCTAssertEqual(AppBanners.make(sensorState: state, latestLiveReadingDate: t0, health: healthy, now: t0).first?.title, "Readings interrupted")
        }
        XCTAssertTrue(ListenModeRules.failure(G7FailureReason.listenSessionLengthUnknown, listening: true)?.detail.contains("Dexcom app") == true)
        XCTAssertNil(ListenModeRules.failure(G7FailureReason.sensorFailed, listening: true), "an ended sensor keeps its own words")
        XCTAssertEqual(OnboardingMapping.pairingErrorText(.notAvailableInListenMode), ConnectionModeText.pairingWhileListening)
    }

    // MARK: - Onboarding

    func test_onboardingStepsPerMode() {
        XCTAssertEqual(OnboardingStep.visibleSteps(alarmsAvailable: true, connection: nil),
                       [.welcome, .importHistory, .removeDexcomApp, .permissions, .alarms, .pairing, .warmUp], "unchanged before D45 is wired")
        XCTAssertEqual(OnboardingStep.visibleSteps(alarmsAvailable: true, connection: ConnectionModeState(mode: nil)),
                       [.welcome, .connection, .importHistory, .removeDexcomApp, .permissions, .alarms, .pairing, .warmUp], "not chosen yet")
        XCTAssertEqual(OnboardingStep.visibleSteps(alarmsAvailable: true, connection: ConnectionModeState(mode: .pair)),
                       [.welcome, .connection, .importHistory, .removeDexcomApp, .permissions, .alarms, .pairing, .warmUp])
        XCTAssertEqual(OnboardingStep.visibleSteps(alarmsAvailable: true, connection: ConnectionModeState(mode: .listen)),
                       [.welcome, .connection, .importHistory, .permissions, .alarms, .listen, .warmUp],
                       "listening keeps the Dexcom app and pairs nothing")
        XCTAssertEqual(OnboardingStep.visibleSteps(alarmsAvailable: false, connection: ConnectionModeState(mode: .listen)),
                       [.welcome, .connection, .importHistory, .permissions, .listen, .warmUp])

        var state = OnboardingState.initial
        XCTAssertEqual(state.step(after: .welcome), .importHistory)
        state.connection = ConnectionModeState(mode: .listen)
        state.urgentLowAlarm = .notDetermined
        XCTAssertEqual(state.step(after: .welcome), .connection)
        XCTAssertEqual(state.step(after: .importHistory), .permissions, "no Dexcom-removal step")
        XCTAssertEqual(state.step(after: .alarms), .listen)
        XCTAssertEqual(state.step(before: .listen), .alarms)
        XCTAssertEqual(state.step(after: .listen), .warmUp)
    }

    // MARK: - Texts

    func test_texts() {
        XCTAssertEqual(ConnectionModeText.title(.listen), "Listen alongside the Dexcom app (this sensor)")
        XCTAssertEqual(ConnectionModeText.title(.pair), "Pair this app (Dexcom app removed)")
        XCTAssertEqual(ConnectionModeText.listeningStatus, "Listening — the Dexcom app owns the connection")
        XCTAssertEqual(ConnectionModeText.outputsOffWhileListening, "Off while listening alongside the Dexcom app")
        for mode in SensorConnectionMode.allCases {
            XCTAssertFalse(ConnectionModeText.explanation(mode).isEmpty)
            XCTAssertFalse(ConnectionModeText.explanation(mode).contains("\n"), "one line")
        }
        XCTAssertTrue(ConnectionModeText.explanation(.listen).contains("sends it nothing"))
        XCTAssertTrue(ConnectionModeText.pairingWhileListening.contains(ConnectionModeText.title(.pair)))
        XCTAssertEqual(PacketRecordingText.title, "Record raw glucose packets")
        XCTAssertTrue(PacketRecordingText.explanation.contains("LOW or HIGH"))
        XCTAssertTrue(PacketRecordingText.explanation.contains("Off by default"))
    }

    // MARK: - Rules while listening

    /// Pairing and calibration write to the sensor: while listening the hero offers neither and
    /// says where to act; readings and other messages are unchanged.
    func test_heroHasNoPairingOrCalibrationButtonWhileListening() {
        let rejected = SensorFailure(kind: .pairingRejected, message: "The sensor no longer accepts this phone.")
        let failedDisplay = GlucoseDisplayState.sensorFailed(rejected, last: nil)
        let pairAgain = NowHero.message(title: "Pair the sensor again", detail: rejected.message, action: .pairAgain)
        guard case .message(_, let detail, let action) = ListenModeRules.hero(pairAgain, display: failedDisplay, listening: true) else { return XCTFail() }
        XCTAssertNil(action)
        XCTAssertEqual(detail, ListenModeRules.failure(rejected, listening: true)?.detail, "listen wording, never \"pair again\" (P3 review m3)")
        let calibrateHero = NowHero.message(title: "Calibrate", detail: "The sensor asks for a fingerstick.", action: .calibrate)
        guard case .message(_, let calibrateDetail, let calibrate) = ListenModeRules.hero(calibrateHero, display: .calibrationNeeded(last: nil), listening: true) else { return XCTFail() }
        XCTAssertNil(calibrate)
        XCTAssertTrue(calibrateDetail.hasSuffix(ConnectionModeText.calibrationWhileListening))
        XCTAssertEqual(ListenModeRules.hero(pairAgain, display: failedDisplay, listening: false), pairAgain, "paired: unchanged")
        let latest = LatestReading(date: t0, value: .mgdl(112), trend: .flat, delta: nil)
        let reading = NowHero.reading(latest)
        XCTAssertEqual(ListenModeRules.hero(reading, display: .current(latest), listening: true), reading)
        let noAction = NowHero.message(title: "No data", detail: "x", action: nil)
        XCTAssertEqual(ListenModeRules.hero(noAction, display: .noData(last: nil), listening: true), noAction)

        // An expired sensor while listening: no "Start a new sensor" button; how to follow the new one.
        let expired = NowHero.make(.sensorExpired(last: nil), now: t0)
        guard case .message(_, let expiredDetail, let expiredAction) = ListenModeRules.hero(expired, display: .sensorExpired(last: nil), listening: true) else { return XCTFail() }
        XCTAssertNil(expiredAction)
        XCTAssertTrue(expiredDetail.hasSuffix(ConnectionModeText.stopFollowingNote))
        // No followed sensor while listening.
        let notPaired = NowHero.make(.notPaired, now: t0)
        XCTAssertEqual(ListenModeRules.hero(notPaired, display: .notPaired, listening: true),
                       .message(title: ConnectionModeText.notFollowingTitle, detail: ConnectionModeText.notFollowingDetail, action: nil))
        XCTAssertEqual(ListenModeRules.stateLine(StateLine(text: "NO SENSOR PAIRED", dot: .muted), display: .notPaired, listening: true).text,
                       "NOT FOLLOWING A SENSOR")
    }

    /// Before the person has chosen listen or pair, "no sensor" offers the choice, never pairing.
    func test_heroOffersTheChoiceBeforeAnyPairing() {
        let notPaired = NowHero.make(.notPaired, now: t0)
        XCTAssertEqual(ListenModeRules.hero(notPaired, display: .notPaired, listening: false, chosen: false),
                       .message(title: ConnectionModeText.notSetUpTitle, detail: ConnectionModeText.notSetUpDetail, action: .setUpSensor))
        XCTAssertEqual(ListenModeRules.hero(notPaired, display: .notPaired, listening: false, chosen: true), notPaired)
        XCTAssertEqual(NowHero.HeroAction.setUpSensor.title, "Set up the sensor")
    }

    func test_outputsReadOffWhileListening() {
        XCTAssertEqual(ListenModeRules.outputRow("handed over 3 min ago", listening: true), "off while listening")
        XCTAssertEqual(ListenModeRules.outputRow("handed over 3 min ago", listening: false), "handed over 3 min ago")
        var settings = Fixtures.settings()
        XCTAssertFalse(settings.isListening)
        settings.connection = ConnectionModeState(mode: .listen)
        XCTAssertTrue(settings.isListening)
        settings.connection = ConnectionModeState(mode: .pair)
        XCTAssertFalse(settings.isListening)
    }

    func test_calibrationIsExplainedWhileListening() {
        var state = Fixtures.calibration(.available)
        XCTAssertEqual(CalibrationRules.availability(state, now: Fixtures.referenceNow), .available)
        state.listening = true
        XCTAssertEqual(CalibrationRules.availability(state, now: Fixtures.referenceNow), .unavailable(reason: ConnectionModeText.calibrationWhileListening))
    }

    // MARK: - Phase 3 review follow-ups (p3b)

    /// m1: onboarding always confirms a switch away from listening (the facade's mode), whether or
    /// not a sensor is stored; a switch from pairing to listening asks only when a sensor is stored.
    func test_onboardingConfirmsLeavingListening() {
        var state = OnboardingState.initial
        state.currentConnectionMode = .listen
        state.connectionSwitchNeedsConfirmation = false // hasStoredSensor is always false while listening
        XCTAssertTrue(state.continueNeedsConfirmation(for: .pair))
        XCTAssertFalse(state.continueNeedsConfirmation(for: .listen), "no switch")
        state.currentConnectionMode = .pair
        XCTAssertFalse(state.continueNeedsConfirmation(for: .listen))
        XCTAssertFalse(state.continueNeedsConfirmation(for: .pair))
        state.connectionSwitchNeedsConfirmation = true
        XCTAssertTrue(state.continueNeedsConfirmation(for: .listen), "a stored pairing would be replaced")
        XCTAssertTrue(ConnectionModeText.switchMessage(to: .pair).hasPrefix(ConnectionModeText.pairingTakeoverWarning))
    }

    /// m1: once a mode is chosen, nothing paired or followed raises a calm banner, so it never looks
    /// like monitoring is running; nothing before a choice, and nothing while a sensor is followed.
    func test_notConnectedBanner() async {
        let services = PreviewAppServices(sensorState: .notPaired)
        let model = launch(services)
        XCTAssertFalse(model.now.notConnected, "not chosen yet: the hero offers the choice")
        model.setConnectionMode(.pair) // records the choice (already pairing mode)
        await model.settle()
        XCTAssertTrue(model.now.notConnected)
        let banner = model.now.banners(now: t0).first { $0.kind == .notConnected }
        XCTAssertEqual(banner?.title, "Not connected to a sensor")
        XCTAssertEqual(banner?.severity, .warning, "calm")
        XCTAssertTrue(banner?.detail.contains("No sensor is paired") == true)

        // Listening, nothing followed yet (no followed serial, no session).
        model.setConnectionMode(.listen)
        await model.settle()
        _ = await eventually { model.now.connection?.mode == .listen }
        XCTAssertEqual(services.sensorState, .searching)
        XCTAssertTrue(model.now.notConnected)
        XCTAssertTrue(model.now.banners(now: t0).first { $0.kind == .notConnected }?.detail.contains("Not following a sensor yet") == true)
        // A followed sensor clears it.
        services.storedSensorSerial = "DXCM01-1A2B3C4D"
        services.sensorState = activeSensor
        model.apply(.sensor)
        XCTAssertFalse(model.now.notConnected)
        XCTAssertNil(model.now.banners(now: t0).first { $0.kind == .notConnected })
    }

    /// m3: no failure reachable in listen mode tells a listening person to pair; credentials
    /// unavailable is "waiting for the phone to unlock".
    func test_noListenFailureSaysToPair() {
        let reasons: [SensorFailure] = [
            G7FailureReason.credentialsUnavailable, G7FailureReason.listenSessionLengthUnknown, G7FailureReason.listenNoAuthenticatedConnection,
            G7FailureReason.listenConnectionRejected, G7FailureReason.sensorClockMismatch, G7FailureReason.noGlucoseValue,
            G7FailureReason.unsupportedSensor, G7FailureReason.sensorFailed, G7FailureReason.sessionStopped,
            // Primary-only today; covered anyway.
            G7FailureReason.savedKeyRejected, G7FailureReason.pairingCodeNeeded, G7FailureReason.bondRemovedBySensor,
            G7FailureReason.bluetoothPairingNotCompleted, G7FailureReason.otherAppRejected, G7FailureReason.authenticationFailed,
        ]
        let session = SensorSession(serial: "DXCM01", start: t0.addingTimeInterval(-86_400), warmUpEndsAt: t0.addingTimeInterval(-84_600),
                                    expiresAt: t0.addingTimeInterval(9 * 86_400), gracePeriodEndsAt: t0.addingTimeInterval(9.5 * 86_400))
        for failure in reasons {
            let state = SensorState.failed(failure)
            var texts = AppBanners.make(sensorState: state, latestLiveReadingDate: t0, health: healthy, now: t0, listening: true)
                .flatMap { [$0.title, $0.detail, $0.actionTitle ?? ""] }
            texts.append(ListenModeRules.listeningDetail(failure))
            texts.append(SensorStatusText.row(state, session: session, now: t0, listening: true))
            let display = GlucoseDisplayState.classify(latest: nil, sensorState: state, now: t0)
            texts.append(ListenModeRules.stateLine(StateLine.make(display, sensorState: state, now: t0), display: display, listening: true).text)
            if case .message(let title, let detail, let action) = ListenModeRules.hero(NowHero.make(display, now: t0), display: display, listening: true) {
                texts += [title, detail]
                XCTAssertNil(action, "\(failure.kind): no pairing or replacing button while listening")
            }
            for text in texts {
                XCTAssertFalse(text.range(of: #"\bpair"#, options: [.regularExpression, .caseInsensitive]) != nil && !text.contains("nothing needs pairing"),
                               "\(failure.kind): \"\(text)\" tells a listening person to pair")
            }
            let banners = AppBanners.make(sensorState: state, latestLiveReadingDate: t0, health: healthy, now: t0, listening: true)
            XCTAssertFalse(banners.contains { $0.action == .pairSensor || $0.action == .pairAgain }, "\(failure.kind)")
        }
        XCTAssertEqual(ListenModeRules.failure(G7FailureReason.credentialsUnavailable, listening: true)?.detail,
                       "Waiting for the phone to unlock — readings resume after you unlock it.")
        XCTAssertTrue(AppBanners.make(sensorState: .failed(G7FailureReason.savedKeyRejected), latestLiveReadingDate: t0, health: healthy, now: t0,
                                      listening: true).contains { $0.severity == .critical }, "a lost connection still fails loud (S5)")
    }

    /// m4: while listening, calibration banners point to the Dexcom app with no button, and an ended
    /// sensor says to start the new one in the Dexcom app (no "Replace sensor" button).
    func test_listeningBannersPointToTheDexcomApp() {
        for state in [SensorState.calibrationNeeded(code: 1), .calibrationError(code: 2)] {
            let banner = AppBanners.make(sensorState: state, latestLiveReadingDate: t0, health: healthy, now: t0, listening: true)
                .first { $0.kind == .calibrationNeeded }
            XCTAssertNil(banner?.action, "\(state)")
            XCTAssertTrue(banner?.detail.hasSuffix("Calibrate in the Dexcom app.") == true, "\(state)")
            XCTAssertEqual(AppBanners.make(sensorState: state, latestLiveReadingDate: t0, health: healthy, now: t0).first { $0.kind == .calibrationNeeded }?.action,
                           .openCalibration, "pairing mode keeps the button")
        }
        let remembered = AppBanners.make(sensorState: activeSensor, latestLiveReadingDate: t0, health: healthy, now: t0, sensorNeedsCalibration: true, listening: true)
        XCTAssertNil(remembered.first { $0.kind == .calibrationNeeded }?.action)

        let ended = AppBanners.make(sensorState: .failed(G7FailureReason.sensorFailed), latestLiveReadingDate: t0, health: healthy, now: t0, listening: true)
            .first { $0.kind == .sensorNeedsReplacement }
        XCTAssertNotEqual(ended?.actionTitle, "Replace sensor")
        XCTAssertTrue(ended?.detail.contains("Start the new sensor in the Dexcom app") == true)
        let expired = AppBanners.make(sensorState: .expired, latestLiveReadingDate: t0, health: healthy, now: t0, listening: true).first { $0.kind == .sensorExpired }
        XCTAssertTrue(expired?.detail.contains("Start the new sensor in the Dexcom app") == true)
    }

    /// m2: the listen copy says exactly what may be sent.
    func test_listenCopySaysWhatMayBeSent() {
        XCTAssertTrue(ConnectionModeText.explanation(.listen).contains("one read-only question for the session length (the same one Trio asks)"))
        XCTAssertFalse(ConnectionModeText.calibrationWhileListening.contains("sends nothing"))
    }

    /// n5, n4: the state line matches the hero before a choice; the last onboarding step says
    /// "Warming up" only while the sensor is.
    func test_stateLineAndLastStepWords() {
        let line = StateLine(text: "NO SENSOR PAIRED", dot: .muted)
        XCTAssertEqual(ListenModeRules.stateLine(line, display: .notPaired, listening: false, chosen: false).text, "NO SENSOR SET UP")
        XCTAssertEqual(ListenModeRules.stateLine(line, display: .notPaired, listening: false, chosen: true).text, "NO SENSOR PAIRED")
        XCTAssertEqual(OnboardingText.lastStep(sensorState: .warmingUp(endsAt: t0.addingTimeInterval(600)), listening: true, now: t0).title, "Warming up")
        let midSession = OnboardingText.lastStep(sensorState: activeSensor, listening: true, now: t0)
        XCTAssertEqual(midSession.title, "All set")
        XCTAssertNil(midSession.waiting)
        XCTAssertTrue(midSession.lead.contains("keeps listening"))
        XCTAssertEqual(OnboardingText.lastStep(sensorState: .searching, listening: false, now: t0).waiting, "Waiting for the first reading.")
    }

    // MARK: - P3b review: unresolved connection setting

    private static let unreadable = "SensorConnection.json could not be read: dataCorrupted"
    private static let refused = "The saved connection setting does not match the stored sensor connection (delete refused)"
    private static let failedSave = "The connection mode could not be changed and the previous setting could not be saved back (disk full)"

    /// p1: while the setting is unresolved, the source's "credentials unavailable" banner is not
    /// shown (it would say "pair again" or "waiting for the phone to unlock"); the setting banner
    /// explains it, in either mode.
    func test_settingProblemSuppressesTheCredentialsBanner() {
        var health = healthy
        health.connectionSettingProblem = Self.unreadable
        let state = SensorState.failed(G7FailureReason.credentialsUnavailable)
        for listening in [false, true] {
            let banners = AppBanners.make(sensorState: state, latestLiveReadingDate: t0, health: health, now: t0, listening: listening)
            XCTAssertEqual(banners.map(\.kind), [.connectionSettingUnreadable], "listening: \(listening)")
            XCTAssertFalse(banners.contains { $0.detail.contains("pair the sensor again") || $0.title.contains("unlock") })
            let unresolvedFree = AppBanners.make(sensorState: state, latestLiveReadingDate: t0, health: healthy, now: t0, listening: listening)
            XCTAssertTrue(unresolvedFree.contains { $0.kind == .sensorInterrupted }, "without the problem the credentials banner shows (S5)")
        }
        // Other sensor problems still show.
        let other = AppBanners.make(sensorState: .bluetoothUnavailable(.poweredOff), latestLiveReadingDate: t0, health: health, now: t0)
        XCTAssertTrue(other.contains { $0.kind == .bluetoothOff })
    }

    /// Nit: the setting banner names the cause.
    func test_settingProblemBannerNamesTheCause() {
        let cases: [(String, String)] = [
            (Self.unreadable, "Connection setting couldn't be read"),
            (Self.refused, "Connection setting doesn't match the sensor"),
            (Self.failedSave, "Connection setting couldn't be saved"),
            ("something new", "Connection setting can't be used"),
        ]
        for (problem, title) in cases {
            var health = healthy
            health.connectionSettingProblem = problem
            let banner = AppBanners.make(sensorState: .notPaired, latestLiveReadingDate: nil, health: health, now: t0).first { $0.kind == .connectionSettingUnreadable }
            XCTAssertEqual(banner?.title, title)
            XCTAssertTrue(banner?.detail.hasPrefix(ConnectionSettingProblem(problem).explanation) == true)
            XCTAssertTrue(banner?.detail.contains(problem) == true, "the services' words, for a bug report")
        }
    }

    /// p2: onboarding's Continue goes to the services even for the mode shown, and always asks
    /// first, while the setting is unresolved; Settings asks again and says why; packet recording
    /// says a change lasts only until a restart.
    func test_unresolvedSettingInOnboardingAndSettings() async {
        let services = PreviewAppServices(sensorState: .failed(G7FailureReason.credentialsUnavailable))
        services.connectionSettingProblem = Self.unreadable
        let model = launch(services, onboardingCompleted: false)
        model.presentOnboarding(at: .connection)
        XCTAssertEqual(model.onboarding?.connectionSettingUnresolved, true)
        XCTAssertEqual(model.onboarding?.continueNeedsConfirmation(for: .pair), true, "always confirmed, even for the mode shown")
        XCTAssertEqual(model.settings.connection, ConnectionModeState(mode: nil), "Settings asks again")
        XCTAssertEqual(model.settings.connectionSettingProblem, Self.unreadable)
        XCTAssertEqual(model.settings.packetRecording?.unresolved, true)

        model.chooseOnboardingConnection(.pair) // the mode the facade reports
        model.continueFromConnectionStep()
        await model.settle()
        XCTAssertTrue(services.calls.contains("setConnectionMode(pair)"), "the services rewrite the setting and start the connection")
        XCTAssertNil(services.connectionSettingProblem)
        _ = await eventually { model.settings.connectionSettingProblem == nil }
        XCTAssertEqual(model.settings.connection?.mode, .pair)
        XCTAssertEqual(model.settings.packetRecording?.unresolved, false)
        XCTAssertEqual(model.onboarding?.step, .importHistory)
    }
}
