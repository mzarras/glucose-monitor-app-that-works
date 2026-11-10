import GlucoseCore
import XCTest
@testable import Sensor

/// D65: the app tells G7Kit where each stored gap of the last day starts, so backfill requests ask
/// the sensor for them.
@MainActor
final class BackfillGapTests: XCTestCase {
    private let t0 = PipelineFixtures.start

    private func reading(_ offset: TimeInterval, serial: String = PipelineFixtures.serial) -> GlucoseReading {
        PipelineFixtures.reading(.mgdl(120), at: t0.addingTimeInterval(offset), serial: serial)
    }

    /// The reading before each step longer than 450 s, oldest first, among this sensor's live
    /// readings only; empty without a gap.
    func test_storedGapStartsAreTheReadingsBeforeEachGap() {
        let r0 = reading(0), r1 = reading(300), r2 = reading(1_500), r3 = reading(1_800), r4 = reading(3_000)
        let otherSensor = reading(900, serial: "TESTG7-99999999")
        let imported = GlucoseReading(id: "ns:1", date: t0.addingTimeInterval(600), value: .mgdl(130), trendRate: nil,
                                      isBackfill: false, source: .imported(.nightscout), sensorSerial: "")
        let stored = [r0, r1, imported, otherSensor, r2, r3, r4]
        XCTAssertEqual(LiveAppServices.storedGapStarts(in: stored, serial: PipelineFixtures.serial).map(\.id), [r1.id, r3.id],
                       "another sensor's or imported readings do not close a gap")
        XCTAssertEqual(LiveAppServices.storedGapStarts(in: [r0, r1, reading(600), reading(1_050)], serial: PipelineFixtures.serial), [],
                       "450 s is not a gap")
        XCTAssertEqual(LiveAppServices.storedGapStarts(in: [r2], serial: PipelineFixtures.serial), [])
        XCTAssertEqual(LiveAppServices.storedGapStarts(in: [], serial: PipelineFixtures.serial), [])
    }

    /// After each store write the gap starts go to the sensor source with the floor.
    func test_storedGapStartsAreReportedAfterAStoreWrite() async throws {
        let now = Date()
        let persistence = LiveServicesHarness.Persistence(now: now)
        let harness = LiveServicesHarness(persistence)
        await harness.services.bootstrap()
        await harness.deliver(state: harness.activeState)
        let beforeGap = persistence.reading(.mgdl(120), at: now.addingTimeInterval(-1_500))
        await harness.deliver(persistence.reading(.mgdl(118), at: now.addingTimeInterval(-1_800)))
        await harness.deliver(beforeGap)
        await harness.deliver(persistence.reading(.mgdl(125), at: now.addingTimeInterval(-300)))
        await waitUntil("gap start reported") {
            harness.sensor.storedGapStartsCalls.last.map { $0.serial == PipelineFixtures.serial && $0.readings.map(\.id) == [beforeGap.id] } ?? false
        }
    }
}
