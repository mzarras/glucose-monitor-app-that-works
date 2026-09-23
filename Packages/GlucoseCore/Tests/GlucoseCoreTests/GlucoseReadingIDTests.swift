import XCTest
@testable import GlucoseCore

final class GlucoseReadingIDTests: XCTestCase {
    func test_S3_sensorIDDependsOnlyOnSerialAndSensorTimestamp() {
        XCTAssertEqual(GlucoseReading.sensorID(serial: "3M1234", sensorTimestamp: 86_400), "3M1234:86400")
        XCTAssertEqual(
            GlucoseReading.sensorID(serial: "3M1234", sensorTimestamp: 300),
            GlucoseReading.sensorID(serial: "3M1234", sensorTimestamp: 300),
            "live and backfilled copies of one reading must collide"
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
