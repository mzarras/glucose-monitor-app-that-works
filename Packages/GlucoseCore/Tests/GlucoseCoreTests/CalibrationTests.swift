import XCTest
@testable import GlucoseCore

final class CalibrationTests: XCTestCase {
    func test_calibrationTypesRoundTripThroughCodable() throws {
        let request = CalibrationRequest(mgdl: 120, takenAt: Date(timeIntervalSince1970: 1_758_000_000))
        XCTAssertEqual(try JSONDecoder().decode(CalibrationRequest.self, from: JSONEncoder().encode(request)), request)
        let update = CalibrationUpdate(requestID: request.id, status: .rejected(code: 3, reason: "glucose changing too fast"))
        XCTAssertEqual(try JSONDecoder().decode(CalibrationUpdate.self, from: JSONEncoder().encode(update)), update)
    }
}
