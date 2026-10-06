// What `LiveAppServices` needs from the CGM source beyond `CGMSource`: pairing, forgetting, the
// Trio heartbeat target, the stored-sensor facts for routing pairing retries, and calibration.
// `G7CGMSource` is the only production conformer; launch-order tests use a scripted double.

import G7Kit
import GlucoseCore

protocol SensorDevice: CalibratingCGMSource {
    /// Pairs a new sensor (throws `G7StartError`).
    func pair(code: String) async throws
    /// Pairs the stored sensor again (throws `G7StartError`, incl. `.noSensorToPairAgain`).
    func pairAgain(code: String) async throws
    func forgetSensor() async
    /// The values Trio's heartbeat needs, nil without an authenticated pairing.
    var heartbeatTarget: G7HeartbeatTarget? { get async }
    var hasStoredSensor: Bool { get async }
    var storedSensorSerial: String? { get async }
}

extension G7CGMSource: SensorDevice {}
