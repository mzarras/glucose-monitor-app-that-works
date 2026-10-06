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
    /// D45: primary (this app pairs) or listen (the Dexcom app owns the connection).
    var mode: G7ConnectionMode { get async }
    /// D45: stops, drops the other mode's stored pairing and session, reports `.notPaired` (primary)
    /// or `.searching` (listen). Throws `G7StartError.credentialStoreFailed` (nothing switched).
    func setMode(_ mode: G7ConnectionMode) async throws
    /// False in listen mode.
    var supportsCalibration: Bool { get async }
    /// D47: log the hex of every received glucose packet.
    func setRecordsRawGlucosePackets(_ enabled: Bool) async
    /// Audit m1: the newest reading durably stored for `serial` (nil: none) — the floor above which
    /// backfill the sensor sends again is published again.
    func setLatestStoredReading(_ reading: GlucoseReading?, forSerial serial: String) async
}

extension G7CGMSource: SensorDevice {}
