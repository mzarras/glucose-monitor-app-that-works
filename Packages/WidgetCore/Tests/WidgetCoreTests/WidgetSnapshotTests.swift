import GlucoseCore
import XCTest
@testable import WidgetCore

final class WidgetSnapshotTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetSnapshotTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sampleSnapshot(state: SensorState = Fixture.activeSensor) -> WidgetSnapshot {
        WidgetSnapshot(
            writtenAt: Fixture.now,
            latest: Fixture.latest(.mgdl(105), minutesAgo: 3, trend: .flat, delta: GlucoseDelta(mgdl: -3, minutes: 5)),
            sensorState: state,
            recent: [
                Fixture.point(.mgdl(108), minutesAgo: 8),
                Fixture.point(.belowRange, minutesAgo: 60),
                Fixture.point(.aboveRange, minutesAgo: 90),
                Fixture.point(.mgdl(105), minutesAgo: 3),
            ],
            accent: .navy
        )
    }

    // MARK: Encoding

    func test_snapshotRoundTripsThroughJSONExactly() throws {
        let states: [SensorState] = [
            Fixture.activeSensor, .notPaired, .searching, .warmingUp(endsAt: Fixture.now), .expired,
            .gracePeriod(endsAt: Fixture.now), .failed(reason: "x"), .error(code: 3, description: "y"),
            .bluetoothUnavailable(.unauthorized),
        ]
        for state in states {
            let snapshot = sampleSnapshot(state: state)
            let data = try WidgetSnapshotStore.encoder().encode(snapshot)
            XCTAssertEqual(try WidgetSnapshotStore.decode(data), snapshot, "\(state)")
        }
    }

    func test_S4_flagsSurviveEncoding() throws {
        let data = try WidgetSnapshotStore.encoder().encode(sampleSnapshot())
        let decoded = try WidgetSnapshotStore.decode(data)
        XCTAssertEqual(decoded.recent.map(\.value), [.mgdl(108), .belowRange, .aboveRange, .mgdl(105)])
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("belowRange"))
        XCTAssertTrue(json.contains("aboveRange"))
    }

    func test_datesAreEncodedAsEpochMilliseconds() throws {
        let data = try WidgetSnapshotStore.encoder().encode(sampleSnapshot())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["writtenAt"] as? NSNumber)?.int64Value, 1_790_166_900_000)
        XCTAssertEqual(object["schemaVersion"] as? Int, WidgetSnapshot.currentSchemaVersion)
    }

    func test_nonWholeMillisecondDatesSurviveToTheMillisecond() throws {
        let odd = Fixture.now.addingTimeInterval(0.123_456)
        let snapshot = WidgetSnapshot(writtenAt: odd, latest: nil, sensorState: .searching, recent: [], accent: .forest)
        let decoded = try WidgetSnapshotStore.decode(WidgetSnapshotStore.encoder().encode(snapshot))
        XCTAssertEqual(decoded.writtenAt.timeIntervalSince1970, odd.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_unsupportedSchemaVersionIsRejected() throws {
        let future = WidgetSnapshot(writtenAt: Fixture.now, latest: nil, sensorState: .searching, recent: [], accent: .forest, schemaVersion: 99)
        let data = try WidgetSnapshotStore.encoder().encode(future)
        XCTAssertThrowsError(try WidgetSnapshotStore.decode(data)) { error in
            XCTAssertEqual(error as? WidgetSnapshotStore.StoreError, .unsupportedSchemaVersion(99))
        }
    }

    // MARK: Store

    func test_storeWritesAndReadsTheSnapshot() throws {
        let store = WidgetSnapshotStore(directory: directory)
        XCTAssertNil(try store.read(), "no file yet")
        let snapshot = sampleSnapshot()
        try store.write(snapshot)
        XCTAssertEqual(try store.read(), snapshot)
        XCTAssertEqual(store.fileURL.lastPathComponent, "widget-snapshot.json")
        // Overwrite (atomic replace) keeps the file readable.
        let second = sampleSnapshot(state: .expired)
        try store.write(second)
        XCTAssertEqual(try store.read(), second)
    }

    func test_writesAreAtomicAndReadableWhileLocked() {
        let options = WidgetSnapshotStore.writingOptions
        XCTAssertTrue(options.contains(.atomic))
        #if os(iOS)
        // HANDOFF §4.5: readable after first unlock, so background writes and Lock Screen reads work.
        XCTAssertTrue(options.contains(.completeFileProtectionUntilFirstUserAuthentication))
        XCTAssertFalse(options.contains(.completeFileProtection))
        #endif
    }

    func test_appGroupIDComesFromInfoPlist() {
        // The test bundle has no AppGroupID key.
        XCTAssertNil(WidgetSnapshotStore.appGroupID(in: Bundle(for: WidgetSnapshotTests.self)))
    }

    // MARK: Builder

    func test_S1_makeSelectsRealReadingsOnly() {
        let readings = [
            Fixture.reading(.mgdl(100), minutesAgo: 200), // outside the 3 h window
            Fixture.reading(.mgdl(110), minutesAgo: 10),
            Fixture.reading(.mgdl(108), minutesAgo: 5, rate: -0.4),
            Fixture.reading(.mgdl(105), minutesAgo: 0, rate: -0.6),
        ]
        let snapshot = WidgetSnapshot.make(readings: readings.shuffled(), sensorState: Fixture.activeSensor, accent: .rust, now: Fixture.now)
        XCTAssertEqual(snapshot.latest, LatestReading(date: Fixture.now, value: .mgdl(105), trend: .flat, delta: GlucoseDelta(mgdl: -3, minutes: 5)))
        XCTAssertEqual(snapshot.recent.map(\.value), [.mgdl(110), .mgdl(108), .mgdl(105)])
        let input = Set(readings.map(ChartPoint.init))
        XCTAssertTrue(Set(snapshot.recent).isSubset(of: input), "every point is a stored reading")
        XCTAssertEqual(snapshot.writtenAt, Fixture.now)
        XCTAssertEqual(snapshot.accent, .rust)
    }

    func test_S6_makeNeverUsesImportedHistoryAsTheCurrentValue() {
        let readings = [
            Fixture.reading(.mgdl(120), minutesAgo: 30),
            Fixture.reading(.mgdl(118), minutesAgo: 25),
            Fixture.reading(.mgdl(250), minutesAgo: 0, source: .imported(.nightscout)),
            Fixture.reading(.mgdl(251), minutesAgo: 1, source: .imported(.clarityCSV)),
        ]
        let snapshot = WidgetSnapshot.make(readings: readings, sensorState: Fixture.activeSensor, accent: .forest, now: Fixture.now)
        XCTAssertEqual(snapshot.latest?.value, .mgdl(118), "latest live reading, not the newer imported one")
        XCTAssertEqual(snapshot.latest?.delta, GlucoseDelta(mgdl: -2, minutes: 5), "delta between live readings only")
        XCTAssertEqual(snapshot.recent.count, 4, "imported history may still be charted")

        let onlyImported = WidgetSnapshot.make(readings: [readings[2]], sensorState: Fixture.activeSensor, accent: .forest, now: Fixture.now)
        XCTAssertNil(onlyImported.latest)
    }
}
