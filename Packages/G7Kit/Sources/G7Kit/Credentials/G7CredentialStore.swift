// Original to Sensor (no ported code). Replaces xDrip4iOS's UserDefaults key storage
// (DexcomG7AuthBridge.m:505-562) and Core Data pairing fields.

import Foundation

/// Everything needed to reconnect to the paired sensor without the user: the pairing code (the
/// J-PAKE secret, needed again only for a full bootstrap), the confirmed J-PAKE shared key (needed
/// for the short authentication path on every ~5-minute connection), and what identifies the sensor.
///
/// "Bonding data": iOS keeps the Bluetooth link keys (the system pairing) itself; apps cannot read
/// or store them. The only bonding material this app owns is `sharedKey`.
public struct G7PairingRecord: Sendable, Equatable, Codable {
    /// 4 ASCII digits from the applicator.
    public var pairingCode: String
    public var slot: G7AuthenticationSlot
    /// Advertised name ("DXCMxx"), known after the first connection.
    public var sensorName: String?
    /// iOS peripheral identifier, known after the first connection; used for pending reconnects.
    public var peripheralIdentifier: UUID?
    /// Fixed at the first authenticated connection; see `G7SensorSerial`.
    public var serial: String?
    /// 16-byte J-PAKE key, stored only after the sensor confirmed ownership (`06 01` / `08 01`).
    public var sharedKey: Data?
    /// Set when the sensor refused our saved key or our pairing code for a known sensor. Automatic
    /// reconnection stops until the user pairs again (CGMG7Transmitter.swift:969-979: xDrip4iOS
    /// stops reconnecting so it does not keep fighting another collector for the slot).
    public var requiresNewPairing: Bool
    /// Session length and warm-up the sensor reported in `0x52`, once known.
    public var reportedSessionLength: TimeInterval?
    public var reportedWarmUp: TimeInterval?
    /// Session start derived from the sensor clock (G7ReadingPipeline), kept so `currentSession`
    /// survives disconnects and app relaunches (D28) and later anchors are checked against it.
    public var sessionStart: Date?
    /// The sensor reported the session over (expired, failed, stopped) twice, at least 60 s of sensor
    /// time apart (G7ReadingPipeline): `currentSession` stays nil and the ended state is shown, also
    /// after a relaunch.
    public var sessionEnd: G7SessionEnd?
    /// A first end report waiting for its confirmation (kept across relaunches).
    public var unconfirmedSessionEnd: G7UnconfirmedSessionEnd?
    /// The newest published reading, so dates stay in sensor-time order across relaunches (S3).
    public var newestReading: G7ReadingMark?
    /// Set when the sensor's `0x52` reported a session length other than the 10-day sensor's. Optional
    /// in storage so records saved before this field existed still decode.
    private var unsupported: Bool?

    public var sessionEnded: Bool { sessionEnd != nil }

    /// The sensor was refused as not a G7 10-day sensor (`.failed(unsupportedSensor)`).
    public var isUnsupportedSensor: Bool {
        get { unsupported ?? false }
        set { unsupported = newValue ? true : nil }
    }

    public init(pairingCode: String, slot: G7AuthenticationSlot) {
        self.pairingCode = pairingCode
        self.slot = slot
        self.requiresNewPairing = false
    }
}

/// Where the pairing record lives. Implementations must be safe to call from any thread.
public protocol G7CredentialStore: Sendable {
    func load() throws -> G7PairingRecord?
    func save(_ record: G7PairingRecord) throws
    func delete() throws
}
