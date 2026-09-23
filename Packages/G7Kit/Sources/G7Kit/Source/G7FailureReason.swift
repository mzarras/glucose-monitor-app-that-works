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
}
