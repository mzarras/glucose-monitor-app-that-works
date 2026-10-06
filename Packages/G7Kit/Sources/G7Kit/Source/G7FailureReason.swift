// Original to Sensor (no ported code).

import GlucoseCore

/// Every `SensorFailure` G7Kit emits in `SensorState.failed(_:)` (S5, contract D36). Consumers decide
/// from `kind`; `message` is written for the person wearing the sensor. Two reasons share
/// `.pairingRejected` (a wrong code at pairing, a saved key refused later): both need a new pairing.
public enum G7FailureReason {
    /// Full J-PAKE finished but the sensor answered "not authenticated" (DexcomG7AuthSession.swift:436-441).
    public static let pairingCodeRejected = SensorFailure(
        kind: .pairingRejected,
        message: "The sensor did not accept the pairing code. Check the 4-digit code on the applicator and pair again."
    )
    /// During a new pairing, the previous (stored) sensor refused the new code and no sensor
    /// accepted it within `G7Controller.previousSensorSkipLimit` (re-review N1): either the person is
    /// re-pairing the sensor they wear with a mistyped code, or the new sensor's code is wrong.
    public static func previousSensorRejectedCode(sensorName: String) -> SensorFailure {
        SensorFailure(
            kind: .pairingRejected,
            message: "The sensor \(sensorName) refused the new code, and no other sensor accepted it. If you meant to keep using \(sensorName), enter its 4-digit code again. If you are pairing a new sensor, check the code on the new applicator."
        )
    }
    /// The confirmed key was refused on a later connection: another device probably paired into the
    /// same slot. Automatic reconnection stops, as in xDrip4iOS (CGMG7Transmitter.swift:969-979).
    public static let savedKeyRejected = SensorFailure(
        kind: .pairingRejected,
        message: "The sensor no longer accepts this phone. Another device may have paired in the same slot. Pair again to reconnect."
    )
    /// The user cancelled (or ignored) the iOS Bluetooth pairing request.
    public static let bluetoothPairingNotCompleted = SensorFailure(
        kind: .bluetoothPairingIncomplete,
        message: "Bluetooth pairing with the sensor was not completed. Accept the pairing request when it appears at the next sensor connection (within about 5 minutes)."
    )
    /// iOS reports the sensor removed its bond with this phone.
    public static let bondRemovedBySensor = SensorFailure(
        kind: .bondRemoved,
        message: "The sensor removed its Bluetooth pairing with this phone. Forget the sensor in iOS Settings > Bluetooth, then pair again."
    )
    /// `0x52` reported a session length other than 10 days (+12 h grace).
    public static let unsupportedSensor = SensorFailure(
        kind: .unsupportedSensor,
        message: "This sensor is not a G7 10-day sensor. Only the G7 10-day sensor is supported; no readings are used from it."
    )
    /// Authentication failed for a protocol reason (details in the diagnostic log).
    public static let authenticationFailed = SensorFailure(
        kind: .authenticationFailed,
        message: "Authentication with the sensor failed. It will be retried at the next sensor connection."
    )
    /// No pairing code is stored but the sensor needs a full pairing.
    public static let pairingCodeNeeded = SensorFailure(
        kind: .pairingCodeNeeded,
        message: "The sensor needs to be paired again. Enter the 4-digit code from the applicator."
    )
    /// The sensor clock disagrees with the session start by more than 30 s, or a reading would be
    /// dated before the last one (phone clock changed): readings are withheld until clocks agree.
    public static let sensorClockMismatch = SensorFailure(
        kind: .clockMismatch,
        message: "The sensor's clock and the phone's clock disagree, so readings are being held back. Check that the phone's date and time are set automatically."
    )
    /// The sensor said OK but sent no usable glucose number (D31: 0, 0x0FFF, 0xFFFE or none).
    public static let noGlucoseValue = SensorFailure(
        kind: .noGlucoseValue,
        message: "The sensor sent a reading without a usable glucose value. It was not used."
    )
    /// The sensor has not reported its session length (`0x52`), so no reading can be checked yet.
    public static let sessionLengthUnknown = SensorFailure(
        kind: .sessionLengthUnknown,
        message: "The sensor has not reported its session length yet, so readings are held back. This normally clears at the next sensor connection."
    )
    /// The sensor reported a failed state (G7AlgorithmState sensorFailed) twice (G7ReadingPipeline).
    public static let sensorFailed = SensorFailure(
        kind: .sensorFailed,
        message: "The sensor reported that it has failed. No more readings will come from it. Replace the sensor."
    )
    /// The sensor reported "session stopped" after warm-up twice (G7ReadingPipeline).
    public static let sessionStopped = SensorFailure(
        kind: .sessionStopped,
        message: "The sensor reported that its session has stopped. No more readings will come from it. Replace the sensor."
    )
    /// A `05` "not authenticated" arrived after this connection authenticated (safety review B1/N2).
    /// It may be the sensor refusing this phone or another app on the phone being refused on the
    /// shared Bluetooth link; the connection is ended and the next one checks this phone's key again.
    public static let rejectedAfterAuthentication = SensorFailure(
        kind: .rejectedAfterAuthentication,
        message: "The sensor refused a connection after it had started. The next sensor connection (within about 5 minutes) checks whether this phone is still accepted."
    )
    /// The same happened again although this phone's own authentication keeps succeeding: most likely
    /// another app on this phone is connecting to the sensor and being refused (safety review P9).
    public static let otherAppRejected = SensorFailure(
        kind: .otherAppRejected,
        message: "Another app on this phone seems to be connecting to the sensor and being refused, which cuts connections short. This phone is still accepted. Close or remove other Dexcom G7 apps."
    )
    /// Listen mode (D45, D49): the sensor's session length (`0x52`) is not known yet: no answer to
    /// another app's `52` was observed, and this app's one query (from the second wake with an
    /// observed authentication) has not been answered yet. Without it no reading can be checked
    /// against the session (S2).
    public static let listenSessionLengthUnknown = SensorFailure(
        kind: .sessionLengthUnknown,
        message: "Listening to the Dexcom app's connection, but the sensor's session length is not known yet, so readings are held back. It is normally learned from the sensor within a few sensor wakes (about 15 minutes)."
    )
    /// Listen mode (D45): two sensor wakes in a row without an observed authenticated connection.
    public static let listenNoAuthenticatedConnection = SensorFailure(
        kind: .authenticationFailed,
        message: "Listening for the Dexcom app's connection, but it was not seen authenticating the sensor at the last sensor wakes, so no readings are used. Keep the Dexcom app installed, signed in and running."
    )
    /// Listen mode (D45): the observed connection was refused after it had been authenticated.
    public static let listenConnectionRejected = SensorFailure(
        kind: .rejectedAfterAuthentication,
        message: "The sensor refused the Dexcom app's connection after it had started, so readings from this sensor wake are not used. The next sensor wake (within about 5 minutes) is checked again."
    )
    /// The pairing record could not be read (for example, the Keychain is locked before the first
    /// unlock after a restart; not the same as "not paired"), or saving it failed three times in a row
    /// (what was not saved would be lost at the next app restart).
    public static let credentialsUnavailable = SensorFailure(
        kind: .credentialsUnavailable,
        message: "The sensor's pairing could not be read from or saved to the Keychain. Unlock the phone. If this continues after unlocking, pair the sensor again from Settings › Sensor."
    )
}
