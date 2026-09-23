// Original to Sensor (no ported code).

/// The `reason` strings G7Kit puts in `SensorState.failed(reason:)` (S5). Public so the UI and alert
/// engine can match them exactly; the wording is written for the person wearing the sensor.
public enum G7FailureReason {
    /// Full J-PAKE finished but the sensor answered "not authenticated" (DexcomG7AuthSession.swift:436-441).
    public static let pairingCodeRejected =
        "The sensor did not accept the pairing code. Check the 4-digit code on the applicator and pair again."
    /// The confirmed key was refused on a later connection: another device probably paired into the
    /// same slot. Automatic reconnection stops, as in xDrip4iOS (CGMG7Transmitter.swift:969-979).
    public static let savedKeyRejected =
        "The sensor no longer accepts this phone. Another device may have paired in the same slot. Pair again to reconnect."
    /// The user cancelled (or ignored) the iOS Bluetooth pairing request.
    public static let bluetoothPairingNotCompleted =
        "Bluetooth pairing with the sensor was not completed. Accept the pairing request when it appears at the next sensor connection (within about 5 minutes)."
    /// iOS reports the sensor removed its bond with this phone.
    public static let bondRemovedBySensor =
        "The sensor removed its Bluetooth pairing with this phone. Forget the sensor in iOS Settings > Bluetooth, then pair again."
    /// `0x52` reported a session length other than 10 days (+12 h grace).
    public static let unsupportedSensor =
        "This sensor is not a G7 10-day sensor. Only the G7 10-day sensor is supported; no readings are used from it."
    /// Authentication failed for a protocol reason (details in the diagnostic log).
    public static let authenticationFailed =
        "Authentication with the sensor failed. It will be retried at the next sensor connection."
    /// No pairing code is stored but the sensor needs a full pairing.
    public static let pairingCodeNeeded =
        "The sensor needs to be paired again. Enter the 4-digit code from the applicator."
    /// The sensor clock disagrees with the session start by more than 30 s, or a reading would be
    /// dated before the last one (phone clock changed): readings are withheld until clocks agree.
    public static let sensorClockMismatch =
        "The sensor's clock and the phone's clock disagree, so readings are being held back. Check that the phone's date and time are set automatically."
    /// The sensor said OK but sent no usable glucose number (D31: 0, 0x0FFF, 0xFFFE or none).
    public static let noGlucoseValue =
        "The sensor sent a reading without a usable glucose value. It was not used."
    /// The sensor has not reported its session length (`0x52`), so no reading can be checked yet.
    public static let sessionLengthUnknown =
        "The sensor has not reported its session length yet, so readings are held back. This normally clears at the next sensor connection."
    /// The pairing record could not be read (for example, the Keychain is locked before the first
    /// unlock after a restart). Not the same as "not paired".
    public static let credentialsUnavailable =
        "The sensor's pairing could not be read from the Keychain. Unlock the phone; if this persists, pair the sensor again."
}
