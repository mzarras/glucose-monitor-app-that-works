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
            .gracePeriod(endsAt: Fixture.now), .failed(SensorFailure(kind: .sensorFailed, message: "x")),
            .failed(SensorFailure(kind: .otherAppRejected, message: "Another app")), .error(code: 3, description: "y"),
            .calibrationNeeded(code: 4), .calibrationError(code: 8), .bluetoothUnavailable(.unauthorized),
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
        let snapshot = WidgetSnapshot.make(latestLive: readings[3], previousLive: readings[2], recent: readings.shuffled(),
                                           sensorState: Fixture.activeSensor, accent: .rust, now: Fixture.now)
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
        let snapshot = WidgetSnapshot.make(latestLive: readings[1], previousLive: readings[0], recent: readings,
                                           sensorState: Fixture.activeSensor, accent: .forest, now: Fixture.now)
        XCTAssertEqual(snapshot.latest?.value, .mgdl(118), "the live reading passed in, not the newer imported one")
        XCTAssertEqual(snapshot.latest?.delta, GlucoseDelta(mgdl: -2, minutes: 5), "delta between live readings only")
        XCTAssertEqual(snapshot.recent.count, 4, "imported history may still be charted")

        // A caller bug passing imported readings as "live" is ignored.
        let wrong = WidgetSnapshot.make(latestLive: readings[2], previousLive: readings[3], recent: readings,
                                        sensorState: Fixture.activeSensor, accent: .forest, now: Fixture.now)
        XCTAssertNil(wrong.latest)
        let wrongPrevious = WidgetSnapshot.make(latestLive: readings[1], previousLive: readings[3], recent: readings,
                                                sensorState: Fixture.activeSensor, accent: .forest, now: Fixture.now)
        XCTAssertNil(wrongPrevious.latest?.delta, "no delta against an imported reading")
    }

    /// Review m2: a latest reading older than the 3-hour chart window is still the latest reading
    /// ("Last reading 4 h ago"), not "no reading".
    func test_S5_oldLatestReadingIsKeptOutsideTheChartWindow() {
        let old = Fixture.reading(.mgdl(140), minutesAgo: 240)
        let snapshot = WidgetSnapshot.make(latestLive: old, previousLive: nil, recent: [], sensorState: Fixture.activeSensor, accent: .forest, now: Fixture.now)
        XCTAssertEqual(snapshot.latest?.date, old.date)
        XCTAssertEqual(snapshot.recent, [])
        let entry = WidgetTimeline.entries(snapshot: snapshot, now: Fixture.now)[0]
        XCTAssertEqual(entry.display, .noData(last: snapshot.latest))
        // D61: shown as the last reading (muted, with its time), not as current.
        XCTAssertEqual(entry.widgetReading?.age, .last)
    }

    /// D61: for an old latest reading the snapshot carries the 3 hours up to that reading (the
    /// widget charts them), not only the 3 hours before `now`.
    func test_oldLatestReadingKeepsItsLastThreeHoursForTheChart() {
        let latest = Fixture.reading(.mgdl(140), minutesAgo: 60)
        let recent = [
            Fixture.reading(.mgdl(150), minutesAgo: 241), // before latest − 3 h: dropped
            Fixture.reading(.mgdl(120), minutesAgo: 240), // exactly latest − 3 h: kept
            Fixture.reading(.mgdl(130), minutesAgo: 200),
            latest,
        ]
        let snapshot = WidgetSnapshot.make(latestLive: latest, previousLive: nil, recent: recent, sensorState: Fixture.activeSensor, accent: .forest, now: Fixture.now)
        XCTAssertEqual(snapshot.recent.map(\.date), [Fixture.minutesAgo(240), Fixture.minutesAgo(200), Fixture.minutesAgo(60)])
        XCTAssertEqual(WidgetSnapshot.chartWindows(latestLive: latest.date, now: Fixture.now), [Fixture.minutesAgo(240)...Fixture.now])
        // A current reading, a future-dated one, or none: the 3 hours before the earlier of the two.
        XCTAssertEqual(WidgetSnapshot.chartWindows(latestLive: Fixture.minutesAgo(2), now: Fixture.now), [Fixture.minutesAgo(182)...Fixture.now])
        XCTAssertEqual(WidgetSnapshot.chartWindows(latestLive: Fixture.minutesAgo(-30), now: Fixture.now), [Fixture.minutesAgo(180)...Fixture.now])
        XCTAssertEqual(WidgetSnapshot.chartWindows(latestLive: nil, now: Fixture.now), [Fixture.minutesAgo(180)...Fixture.now])
    }

    /// Review m6: a month-old latest reading adds its own 3 hours, not the month in between, so the
    /// file stays small on every drain.
    func test_monthOldLatestReadingKeepsOnlyItsOwnThreeHoursAndTheLastThree() {
        let month: Double = 30 * 1_440
        let latest = Fixture.reading(.mgdl(140), minutesAgo: month)
        // One imported reading every 5 minutes for the whole month, plus the latest itself.
        let imported = stride(from: month + 240, through: 0, by: -5).map { Fixture.reading(.mgdl(100), minutesAgo: $0, source: .imported(.nightscout)) }
        let snapshot = WidgetSnapshot.make(latestLive: latest, previousLive: nil, recent: imported + [latest], sensorState: .searching,
                                           accent: .forest, now: Fixture.now)
        XCTAssertEqual(WidgetSnapshot.chartWindows(latestLive: latest.date, now: Fixture.now),
                       [Fixture.minutesAgo(month + 180)...Fixture.minutesAgo(month), Fixture.minutesAgo(180)...Fixture.now])
        // 37 imported points (every 5 min, both ends included) + the latest in its window; 37 in the last 3 hours.
        XCTAssertEqual(snapshot.recent.count, 38 + 37)
        XCTAssertTrue(snapshot.recent.allSatisfy { $0.date >= Fixture.minutesAgo(180) || ($0.date >= Fixture.minutesAgo(month + 180) && $0.date <= latest.date) })
        XCTAssertEqual(snapshot.recent.map(\.date), snapshot.recent.map(\.date).sorted())
    }

    /// Review m3: whatever is in the file, the widget either gets a valid snapshot or nil ("No data").
    func test_S5_corruptTruncatedOrEmptyFileReadsAsNoData() throws {
        let store = WidgetSnapshotStore(directory: directory)
        let valid = try WidgetSnapshotStore.encoder().encode(sampleSnapshot())
        let bad: [(String, Data)] = [
            ("empty", Data()),
            ("truncated", valid.prefix(valid.count / 2)),
            ("not JSON", Data("garbage \u{0}\u{1}".utf8)),
            ("wrong shape", Data(#"{"schemaVersion":1,"latest":42}"#.utf8)),
            ("other schema", try WidgetSnapshotStore.encoder().encode(WidgetSnapshot(writtenAt: Fixture.now, latest: nil, sensorState: .searching, recent: [], accent: .forest, schemaVersion: 2))),
            ("random bytes", Data((0..<256).map { UInt8($0) })),
        ]
        for (name, data) in bad {
            try data.write(to: store.fileURL)
            XCTAssertNil(store.readOrNil(), name)
            XCTAssertEqual(WidgetTimeline.entries(snapshot: store.readOrNil(), now: Fixture.now).map(\.display), [.noData(last: nil)], name)
        }
        try valid.write(to: store.fileURL)
        XCTAssertEqual(store.readOrNil(), sampleSnapshot())
        XCTAssertNil(WidgetSnapshotStore.snapshotForWidget(bundle: Bundle(for: WidgetSnapshotTests.self)), "no App Group → nil")
    }

    // MARK: DEBUG replay marker (audit m9)

    /// A replayed (or mock) latest reading marks the snapshot and every timeline entry showing it;
    /// a live sensor reading never does. These tests run in DEBUG, where the marker exists.
    func test_m9_replayedLatestReadingIsMarked() {
        for (source, marked) in [(ReadingSource.replay, true), (.mock, true), (.sensor, false)] {
            let latest = Fixture.reading(.mgdl(48), minutesAgo: 1, source: source)
            let snapshot = WidgetSnapshot.make(latestLive: latest, previousLive: nil, recent: [latest],
                                               sensorState: Fixture.activeSensor, accent: .navy, now: Fixture.now)
            XCTAssertEqual(snapshot.isReplay, marked, "\(source)")
            let entries = WidgetTimeline.entries(snapshot: snapshot, now: Fixture.now)
            XCTAssertEqual(entries.first?.showsReplayMarker, marked, "\(source)")
            XCTAssertTrue(entries.allSatisfy { $0.isReplay == marked })
        }
        let none = WidgetSnapshot.make(latestLive: nil, previousLive: nil, recent: [], sensorState: .notPaired, accent: .navy, now: Fixture.now)
        XCTAssertFalse(none.isReplay)
    }

    /// The marker labels a displayed reading only — current, stale or (D61) a last reading; a
    /// message state ("No data" without a reading, expired, …) has no number to mark.
    func test_m9_replayMarkerOnlyWithAReading() {
        let reading = Fixture.latest(.mgdl(48), minutesAgo: 1)
        func content(_ display: GlucoseDisplayState) -> WidgetEntryContent {
            WidgetEntryContent(date: Fixture.now, display: display, recent: [], accent: .navy, snapshotWrittenAt: Fixture.now, isReplay: true)
        }
        XCTAssertTrue(content(.current(reading)).showsReplayMarker)
        XCTAssertTrue(content(.stale(reading)).showsReplayMarker)
        XCTAssertTrue(content(.noData(last: reading)).showsReplayMarker, "D61 (changed): a last reading is a number, so it is marked")
        XCTAssertFalse(content(.noData(last: nil)).showsReplayMarker)
        XCTAssertFalse(content(.sensorExpired(last: reading)).showsReplayMarker)
        XCTAssertFalse(content(.clockMismatch(latest: reading)).showsReplayMarker)
        XCTAssertEqual(WidgetStyle.replayLabel, "REPLAY")
    }

    /// The field is additive: a snapshot written before it existed decodes (as not replay), and a
    /// marked one round-trips.
    func test_m9_replayFieldIsBackwardCompatible() throws {
        let marked = WidgetSnapshot(writtenAt: Fixture.now, latest: Fixture.latest(.mgdl(48), minutesAgo: 1), sensorState: Fixture.activeSensor,
                                    recent: [], accent: .navy, isReplay: true)
        let data = try WidgetSnapshotStore.encoder().encode(marked)
        XCTAssertEqual(try WidgetSnapshotStore.decode(data), marked)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "isReplay")
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try WidgetSnapshotStore.decode(old)
        XCTAssertFalse(decoded.isReplay)
        XCTAssertEqual(decoded.latest, marked.latest)
    }
}
