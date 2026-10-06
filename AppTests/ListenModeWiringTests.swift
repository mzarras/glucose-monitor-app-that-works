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
        XCTAssertTrue(detail.hasSuffix(ConnectionModeText.sensorProblemWhileListening))
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
}
