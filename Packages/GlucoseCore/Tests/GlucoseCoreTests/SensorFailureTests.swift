import XCTest
@testable import GlucoseCore

final class SensorFailureTests: XCTestCase {
    func test_S5_onlyEndedSensorsAndLostPairingsRaiseTheSensorAlert() {
        let alerting: Set<SensorFailure.Kind> = [.sensorFailed, .sessionStopped, .unsupportedSensor,
                                                 .pairingRejected, .pairingCodeNeeded, .bondRemoved, .other]
        for kind in SensorFailure.Kind.allCases {
            let failure = SensorFailure(kind: kind, message: "m")
            XCTAssertEqual(failure.raisesSensorAlert, alerting.contains(kind), "\(kind)")
            XCTAssertFalse(failure.requiresSensorReplacement && failure.requiresPairing, "\(kind)")
        }
    }

    func test_sensorStateRoundTripsThroughCodable() throws {
        let states: [SensorState] = [
            .failed(SensorFailure(kind: .clockMismatch, message: "Check the phone's clock.")),
            .calibrationNeeded(code: 4), .calibrationError(code: 8),
        ]
        for state in states {
            XCTAssertEqual(try JSONDecoder().decode(SensorState.self, from: JSONEncoder().encode(state)), state)
        }
    }
}
