// Original to Sensor (no ported code).

/// Settings fixed when the G7 source is created.
public struct G7Configuration: Sendable, Equatable {
    /// The CoreBluetooth state-restoration identifier. It must stay the same across app versions:
    /// iOS matches it to relaunch the app for this central's events after the system terminated the
    /// app (HANDOFF §4.6). Changing it orphans the previous central's restoration once.
    public static let defaultRestoreIdentifier = "com.mzarras.sensor.g7kit.central"

    public var restoreIdentifier: String
    /// Which G7 authentication slot to pair into. Default `.mobileApp` (slot 2): see
    /// `G7AuthenticationSlot` and docs/g7-protocol.md "Slot choice". Changing it needs a new pairing:
    /// keys belong to one slot (DexcomG7AuthBridge.m:149-161).
    public var authenticationSlot: G7AuthenticationSlot

    public init(
        restoreIdentifier: String = G7Configuration.defaultRestoreIdentifier,
        authenticationSlot: G7AuthenticationSlot = .recommendedDefault
    ) {
        self.restoreIdentifier = restoreIdentifier
        self.authenticationSlot = authenticationSlot
    }
}
