import GlucoseCore
import WidgetCore
import XCTest
@testable import Sensor

/// D45 listen mode and D47 packet recording, screens side, prepared before the G7Kit API and the
/// facade exist: the rules the screens apply, and that nothing shows until the facade offers them.
@MainActor
final class ListenModeDesignTests: XCTestCase {
    // MARK: - Hidden until wired

    /// The facade has no listen mode or packet recording yet: every screen is as before D45.
    func test_nothingShowsUntilTheFacadeOffersIt() {
        let services = PreviewAppServices(sensorState: .notPaired)
        let defaults = UserDefaults(suiteName: "ListenModeDesignTests.\(UUID().uuidString)")!
        let model = AppModel.launch(services: services, arguments: [], preferences: AppUIPreferences(defaults: defaults), clock: { t0 },
                                    protectedDataAvailable: { true })
        model.apply(.sensor)
        XCTAssertNil(model.settings.connection)
        XCTAssertNil(model.settings.packetRecording)
        XCTAssertFalse(model.settings.isListening)
        XCTAssertNil(model.now.connection)
        XCTAssertFalse(model.calibration.listening)
        XCTAssertNil(model.onboarding?.connection)
        XCTAssertEqual(model.onboarding?.visibleSteps.contains(.connection), false)
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
        let pairAgain = NowHero.message(title: "Sensor not connected", detail: "The sensor no longer accepts this phone.", action: .pairAgain)
        guard case .message(_, let detail, let action) = ListenModeRules.hero(pairAgain, listening: true) else { return XCTFail() }
        XCTAssertNil(action)
        XCTAssertTrue(detail.hasSuffix(ConnectionModeText.sensorProblemWhileListening))
        guard case .message(_, let calibrateDetail, let calibrate) = ListenModeRules.hero(.message(title: "Calibrate", detail: "The sensor asks for a fingerstick.", action: .calibrate), listening: true) else { return XCTFail() }
        XCTAssertNil(calibrate)
        XCTAssertTrue(calibrateDetail.hasSuffix(ConnectionModeText.calibrationWhileListening))
        XCTAssertEqual(ListenModeRules.hero(pairAgain, listening: false), pairAgain, "paired: unchanged")
        let reading = NowHero.reading(LatestReading(date: t0, value: .mgdl(112), trend: .flat, delta: nil))
        XCTAssertEqual(ListenModeRules.hero(reading, listening: true), reading)
        let noAction = NowHero.message(title: "No data", detail: "x", action: nil)
        XCTAssertEqual(ListenModeRules.hero(noAction, listening: true), noAction)
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
