import XCTest
@testable import GlucoseCore

final class GlucoseReadingIDTests: XCTestCase {
    // Format only. The S3 proof (a live and a backfilled packet for the same reading yield the same
    // id and date) belongs to the sources' fixture tests (G7Kit, ReplayKit) and the store's dedupe tests.
    func test_sensorIDFormat() {
        XCTAssertEqual(GlucoseReading.sensorID(serial: "3M1234", sensorTimestamp: 86_400), "3M1234:86400")
        XCTAssertNotEqual(
            GlucoseReading.sensorID(serial: "3M1234", sensorTimestamp: 300),
            GlucoseReading.sensorID(serial: "3M1235", sensorTimestamp: 300)
        )
    }

    func test_importedID_usesOriginAndEpochMilliseconds() {
        let date = Date(timeIntervalSince1970: 1_758_630_000.1234)
        XCTAssertEqual(GlucoseReading.importedID(origin: .nightscout, date: date), "imported:nightscout:1758630000123")
        XCTAssertEqual(GlucoseReading.importedID(origin: .clarityCSV, date: date), "imported:clarityCSV:1758630000123")
    }

    func test_S6_onlySensorIsLive() {
        XCTAssertTrue(ReadingSource.sensor.isLiveSensor)
        XCTAssertFalse(ReadingSource.imported(.nightscout).isLiveSensor)
        XCTAssertFalse(ReadingSource.imported(.clarityCSV).isLiveSensor)
        XCTAssertFalse(ReadingSource.replay.isLiveSensor)
        XCTAssertFalse(ReadingSource.mock.isLiveSensor)
    }
}
