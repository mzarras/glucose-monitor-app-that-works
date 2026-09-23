// The shared-App-Group contract that Trio's "xDrip4iOS" CGM source reads (HANDOFF §8).
//
// Every constant cites where it is defined. Trio is AGPL-3.0: it was read to learn the contract,
// and nothing from it is copied here. References (read-only):
//   Trio      mzarras/Trio main @ 29350e31a (v0.8.4)   — the reader
//   xDrip4iOS 7.1.0 @ 0370937                            — the proven writer of the same contract
// The full write-up, with every rule Trio applies to these values, is docs/trio-bridge.md.

/// Keys, limits and value conventions of Trio's App Group CGM source.
public enum TrioAppGroupContract {
    /// UserDefaults key (in the suite named by the App Group ID) holding the readings as JSON `Data`.
    /// Trio `Trio/Sources/APS/CGM/AppGroupSource.swift:48`; xDrip4iOS `xDrip/Managers/Loop/LoopManager.swift:615`.
    public static let readingsKey = "latestReadings"

    /// Trio reads at most the first 60 array elements (`AppGroupSource.swift:40` passes 60, `:61`
    /// takes `prefix(count)`), so the array is newest first and never longer than this.
    /// xDrip4iOS caps at the same number (`xDrip/Constants/ConstantsShareWithLoop.swift:6`).
    public static let maxReadings = 60

    /// Heartbeat keys. When all three are present Trio's `HeartBeatManager` opens its own CoreBluetooth
    /// connection to that peripheral and polls the App Group on every disconnect or notification
    /// (`Trio/Sources/APS/CGM/HeartBeatManager.swift:4-8, :25-43, :45-75`;
    /// `Trio/Sources/APS/CGM/BluetoothTransmitter.swift:256-260`).
    /// xDrip4iOS writes them in `xDrip/Managers/BluetoothPeripheral/BluetoothPeripheralManager.swift:616-640`.
    /// The value is `CBPeripheral.identifier.uuidString` (Trio passes it to `retrievePeripherals(withIdentifiers:)`,
    /// `BluetoothTransmitter.swift:162-178`).
    public static let heartbeatDeviceAddressKey = "cgmTransmitterDeviceAddress"
    /// Service UUID string Trio discovers on the heartbeat peripheral (`HeartBeatManager.swift:6`).
    public static let heartbeatServiceUUIDKey = "cgmTransmitter_CBUUID_Service"
    /// Characteristic UUID string Trio subscribes to on the heartbeat peripheral (`HeartBeatManager.swift:8`).
    public static let heartbeatReceiveUUIDKey = "cgmTransmitter_CBUUID_Receive"

    /// The LOW code used across the Nightscout ecosystem: Nightscout displays exactly 39 as "LOW"
    /// (cgm-remote-monitor 15.0.8 `lib/sandbox.js:249-250`), LoopKit's Dexcom Share client treats
    /// values >= 39 as valid state (`dexcom-share-client-swift/ShareClient/ShareGlucose+GlucoseKit.swift:30-32`),
    /// Trio's `BloodGlucose.isStateValid` is `sgv >= 39` (`Trio/Sources/Models/BloodGlucose.swift:168`),
    /// and xDrip4iOS floors calibrated readings at 39 (`xDrip/Constants/ConstantsCalibrationAlgorithms.swift:8`).
    /// Written only when `OutOfRangePolicy.low == .writeSentinel` (the app's policy per PROGRESS.md D21;
    /// the package default withholds LOW).
    /// Never 38: oref treats 38 as a CGM error code (`trio-oref/lib/determine-basal/determine-basal.js:418-421, :443`).
    public static let lowSentinelMgdl = 39

    /// The HIGH code: Nightscout displays exactly 401 as "HIGH" (`lib/sandbox.js:251-252`) and treats any
    /// value > 400 as HIGH (`lib/client/index.js:546-547`). Written only when
    /// `OutOfRangePolicy.high == .writeSentinel` (the app's policy per D21; the package default withholds HIGH).
    public static let highSentinelMgdl = 401

    /// Trio's App Group ID must be exactly `group.org.nightscout.<TEAM ID>.trio.trio-app-group`
    /// (Trio `Config.xcconfig:16-18`; the same string in xDrip4iOS `xdrip.xcodeproj/project.pbxproj:5987`).
    /// Apple Team IDs are 10 upper-case letters or digits. Refusing anything else catches an unexpanded or
    /// empty `$(DEVELOPMENT_TEAM)` (e.g. an unsigned build yields `group.org.nightscout..trio.trio-app-group`),
    /// which would otherwise write into a suite Trio never reads.
    public static func isValidTrioAppGroupID(_ groupID: String) -> Bool {
        let prefix = "group.org.nightscout."
        let suffix = ".trio.trio-app-group"
        guard groupID.hasPrefix(prefix), groupID.hasSuffix(suffix),
              groupID.count == prefix.count + 10 + suffix.count
        else { return false }
        let team = groupID.dropFirst(prefix.count).dropLast(suffix.count)
        return team.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }
}
