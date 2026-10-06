// Original to Sensor (no ported code).

/// Who owns the sensor connection (D45). Chosen by the app; G7Kit never switches by itself.
public enum G7ConnectionMode: Sendable, Equatable, Hashable {
    /// This app pairs with the sensor (J-PAKE, 4-digit code) in `slot`, owns the connection,
    /// requests readings and backfill, and can calibrate.
    case primary(slot: G7AuthenticationSlot)
    /// Listen mode: the Dexcom app on this phone owns the connection. This app only observes it —
    /// it never writes to the sensor, never pairs and never uses a slot — and publishes a reading
    /// only after it observed that the connection is authenticated and bonded (S2). No backfill, no
    /// calibration. docs/g7-protocol.md §14.
    case listen

    /// A short description for status lines and diagnostics.
    public var summary: String {
        switch self {
        case .primary: return "Connected directly to the sensor"
        case .listen: return "Listening; the Dexcom app owns the connection"
        }
    }
}

/// Settings given when the G7 source is created (the mode and raw recording can change later
/// through `G7CGMSource`).
public struct G7Configuration: Sendable, Equatable {
    /// The CoreBluetooth state-restoration identifier. It must stay the same across app versions:
    /// iOS matches it to relaunch the app for this central's events after the system terminated the
    /// app (HANDOFF §4.6). Changing it orphans the previous central's restoration once.
    public static let defaultRestoreIdentifier = "com.mzarras.sensor.g7kit.central"

    public var restoreIdentifier: String
    /// Primary (default, slot 2) or listen mode (D45). A stored pairing of the other mode is dropped
    /// when the source loads it in this one.
    public var mode: G7ConnectionMode
    /// D47: log the hex of every received glucose packet (`0x4E`; in listen mode also `0x31` and
    /// `0x25`) to the diagnostic log, with its time. Off by default; for capturing a real LOW/HIGH
    /// (D31).
    public var recordsRawGlucosePackets: Bool

    /// The slot of primary mode: which G7 authentication slot to pair into. Default `.mobileApp`
    /// (slot 2), see `G7AuthenticationSlot` and docs/g7-protocol.md "Slot choice". Changing it needs a
    /// new pairing: keys belong to one slot (DexcomG7AuthBridge.m:149-161). Setting it selects
    /// primary mode.
    public var authenticationSlot: G7AuthenticationSlot {
        get {
            if case .primary(let slot) = mode { return slot }
            return .recommendedDefault
        }
        set { mode = .primary(slot: newValue) }
    }

    public init(
        restoreIdentifier: String = G7Configuration.defaultRestoreIdentifier,
        mode: G7ConnectionMode = .primary(slot: .recommendedDefault),
        recordsRawGlucosePackets: Bool = false
    ) {
        self.restoreIdentifier = restoreIdentifier
        self.mode = mode
        self.recordsRawGlucosePackets = recordsRawGlucosePackets
    }

    public init(
        restoreIdentifier: String = G7Configuration.defaultRestoreIdentifier,
        authenticationSlot: G7AuthenticationSlot,
        recordsRawGlucosePackets: Bool = false
    ) {
        self.init(restoreIdentifier: restoreIdentifier, mode: .primary(slot: authenticationSlot),
                  recordsRawGlucosePackets: recordsRawGlucosePackets)
    }
}
