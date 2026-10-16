import GlucoseCore
import WidgetCore
import XCTest
@testable import Sensor

/// D61: `LiveWidgetPublisher` writes the snapshot on every publish but asks WidgetKit to reload only
/// when what the widget displays changes, and logs one line per requested reload.
@MainActor
final class WidgetReloadPolicyTests: XCTestCase {
    // XCTest makes a new instance per test, so each test has its own directory and counter.
    private let directory = PipelineFixtures.temporaryDirectory()
    private var reloads = 0
    private let log = CollectingDiagnosticLog()
    private let start = PipelineFixtures.start

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    /// Review m4: the time zone the publisher sees (the phone's, in production).
    private var timeZoneID = "America/New_York"

    private func makePublisher() -> (LiveWidgetPublisher, WidgetSnapshotStore) {
        let store = WidgetSnapshotStore(directory: directory)
        let publisher = WidgetSnapshotPublisher(store: store, reloadTimelines: { [unowned self] in self.reloads += 1 })
        let widget = LiveWidgetPublisher(publisher: publisher, accent: .forest, diagnostics: log,
                                         zoneAndLocale: { [unowned self] in (self.timeZoneID, "en_US") })
        return (widget, store)
    }

    private var active: SensorState {
        .active(sessionStart: PipelineFixtures.session.start, expiresAt: PipelineFixtures.session.expiresAt)
    }

    private var reloadLines: [String] { log.messages.filter { $0.hasPrefix("widget reload requested") } }

    func test_S5_reloadsOnlyWhenTheWidgetContentChanges() throws {
        let (widget, store) = makePublisher()
        let first = PipelineFixtures.reading(.mgdl(105), at: start)
        // One 5-minute wake: a reading, then the state events around it. The first publish of the
        // process reloads; the rest only rewrite the file.
        widget.publish(latestLive: first, previousLive: nil, recent: [first], sensorState: active, currentSensor: nil, now: start)
        XCTAssertEqual(reloads, 1)
        for (offset, state) in [SensorState.searching, .connecting, .authenticating, active, .bluetoothUnavailable(.poweredOff)].enumerated() {
            let now = start.addingTimeInterval(Double(offset + 1) * 20)
            widget.publish(latestLive: first, previousLive: nil, recent: [first], sensorState: state, currentSensor: nil, now: now)
            XCTAssertEqual(try store.read()?.writtenAt, now, "the file is still written every time")
        }
        XCTAssertEqual(reloads, 1, "state churn does not reload")

        // The next reading reloads.
        let second = PipelineFixtures.reading(.mgdl(108), at: start.addingTimeInterval(300))
        widget.publish(latestLive: second, previousLive: first, recent: [first, second], sensorState: active, currentSensor: nil, now: second.date)
        XCTAssertEqual(reloads, 2)
        // Sensor expired reloads; so does an accent change.
        widget.publish(latestLive: second, previousLive: first, recent: [first, second], sensorState: .expired, currentSensor: nil, now: second.date.addingTimeInterval(10))
        XCTAssertEqual(reloads, 3)
        widget.accent = .navy
        widget.publish(latestLive: second, previousLive: first, recent: [first, second], sensorState: .expired, currentSensor: nil, now: second.date.addingTimeInterval(20))
        XCTAssertEqual(reloads, 4)
        widget.publish(latestLive: second, previousLive: first, recent: [first, second], sensorState: .expired, currentSensor: nil, now: second.date.addingTimeInterval(30))
        XCTAssertEqual(reloads, 4)

        XCTAssertEqual(reloadLines, [
            "widget reload requested: first publish since launch or foreground",
            "widget reload requested: new reading \(second.date.ISO8601Format())",
            "widget reload requested: sensor state expired",
            "widget reload requested: accent navy",
        ], "one line per requested reload, none for the skipped ones")
    }

    func test_S5_warmUpEndReloads() {
        let (widget, _) = makePublisher()
        let warmUpEnd = start.addingTimeInterval(600)
        widget.publish(latestLive: nil, previousLive: nil, recent: [], sensorState: .warmingUp(endsAt: warmUpEnd), currentSensor: nil, now: start)
        widget.publish(latestLive: nil, previousLive: nil, recent: [], sensorState: .warmingUp(endsAt: warmUpEnd), currentSensor: nil, now: start.addingTimeInterval(60))
        XCTAssertEqual(reloads, 1)
        widget.publish(latestLive: nil, previousLive: nil, recent: [], sensorState: active, currentSensor: nil, now: warmUpEnd)
        XCTAssertEqual(reloads, 2)
    }

    func test_S5_comingToTheForegroundReloadsOnce() {
        let (widget, _) = makePublisher()
        let reading = PipelineFixtures.reading(.mgdl(105), at: start)
        widget.publish(latestLive: reading, previousLive: nil, recent: [reading], sensorState: active, currentSensor: nil, now: start)
        widget.publish(latestLive: reading, previousLive: nil, recent: [reading], sensorState: active, currentSensor: nil, now: start.addingTimeInterval(30))
        XCTAssertEqual(reloads, 1)
        widget.reloadOnNextPublish()
        widget.publish(latestLive: reading, previousLive: nil, recent: [reading], sensorState: active, currentSensor: nil, now: start.addingTimeInterval(60))
        widget.publish(latestLive: reading, previousLive: nil, recent: [reading], sensorState: active, currentSensor: nil, now: start.addingTimeInterval(90))
        XCTAssertEqual(reloads, 2, "the first publish after the foreground reloads, the next does not")
    }

    /// Review m4: a time zone change reloads at the next publish (the day labels are zone-dependent).
    func test_S5_timeZoneChangeReloads() {
        let (widget, _) = makePublisher()
        let reading = PipelineFixtures.reading(.mgdl(105), at: start)
        widget.publish(latestLive: reading, previousLive: nil, recent: [reading], sensorState: active, currentSensor: nil, now: start)
        widget.publish(latestLive: reading, previousLive: nil, recent: [reading], sensorState: active, currentSensor: nil, now: start.addingTimeInterval(30))
        XCTAssertEqual(reloads, 1)
        timeZoneID = "Europe/Paris"
        widget.publish(latestLive: reading, previousLive: nil, recent: [reading], sensorState: active, currentSensor: nil, now: start.addingTimeInterval(60))
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(reloadLines.last, "widget reload requested: time zone or locale changed")
    }

    /// D61 (review m1): a new pairing reloads, and the snapshot carries the current sensor so the
    /// widget hides the old sensor's reading.
    func test_S5_newPairingReloadsAndHidesTheOldSensorsReading() throws {
        let (widget, store) = makePublisher()
        let reading = PipelineFixtures.reading(.mgdl(105), at: start)
        let session = PipelineFixtures.session
        let paired = WidgetCurrentSensor.make(session: session, storedPairing: .read(serial: session.serial))
        widget.publish(latestLive: reading, previousLive: nil, recent: [reading], sensorState: active, currentSensor: paired, now: start)
        XCTAssertFalse(try XCTUnwrap(store.read()).latestIsFromAnEarlierSensor)
        let pairing = WidgetCurrentSensor.make(session: nil, storedPairing: .read(serial: nil))
        widget.publish(latestLive: reading, previousLive: nil, recent: [reading], sensorState: .searching, currentSensor: pairing,
                       now: start.addingTimeInterval(60))
        XCTAssertEqual(reloads, 2)
        let written = try XCTUnwrap(store.read())
        XCTAssertTrue(written.latestIsFromAnEarlierSensor)
        XCTAssertTrue(WidgetTimeline.entries(snapshot: written, now: start.addingTimeInterval(60)).allSatisfy { $0.widgetReading == nil })
    }

    /// A failed write never reloads (the widget would read the previous file) and is not remembered:
    /// the next successful write of the same content reloads.
    func test_S5_failedWriteDoesNotReloadAndIsRetried() throws {
        let (widget, _) = makePublisher()
        try FileManager.default.removeItem(at: directory)
        let reading = PipelineFixtures.reading(.mgdl(105), at: start)
        widget.publish(latestLive: reading, previousLive: nil, recent: [reading], sensorState: active, currentSensor: nil, now: start)
        XCTAssertEqual(reloads, 0)
        XCTAssertTrue(log.messages.contains { $0.hasPrefix("widget snapshot write failed") })
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        widget.publish(latestLive: reading, previousLive: nil, recent: [reading], sensorState: active, currentSensor: nil, now: start.addingTimeInterval(30))
        XCTAssertEqual(reloads, 1)
    }
}
