// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// The enum below comes from AuthRequestTxMessage.swift, whose header reads:
//   AuthRequestTxMessage.swift, xDrip5. Created by Nathan Racklyeft on 11/22/15.
//   Copyright © 2015 Nathan Racklyeft. All rights reserved.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/AuthRequestTxMessage.swift @ 7.1.0 (0370937)
// CGMBLEKit lineage: CGMBLEKit/Messages/AuthRequestTxMessage.swift (LoopKit CGMBLEKit, formerly xDripG5;
//   MIT, Packages/G7Kit/licenses/CGMBLEKit-LICENSE), reached through xDrip4iOS;
//   compared with loopandlearn/CGMBLEKit @ 98fae79 (Trio submodule).
// Changes: public, renamed cases, documentation of the slot findings (docs/g7-protocol.md "Slot choice").

/// The G7 authentication slot ("Bluetooth channel" in xDrip4iOS): the last byte of the `0x02`
/// authentication request (DexcomG7AuthBridge.m:203-218).
///
/// Each slot is an independent authentication identity inside the sensor (CGMG7Transmitter.swift:11-13,
/// :164-165; DexcomG7AuthSession.swift:158-167). A confirmed J-PAKE key belongs to one sensor and one
/// slot (DexcomG7AuthBridge.m:149-161, :505-519). Per xDrip4iOS, pairing into a slot replaces whatever
/// collector owned that slot before: its saved key stops being accepted (DexcomG7AuthSession.swift:296-306,
/// :409-420).
///
/// Which device uses which slot is a hypothesis from xDrip4iOS's names and UI text only
/// (AuthRequestTxMessage.swift:37-50, TextsBluetoothPeripheralView.swift:340-378), not verified on
/// hardware (docs/g7-protocol.md §9). Recommended default: `.mobileApp` — per that naming the slot the
/// Dexcom G7 app uses (so that app must be removed, HANDOFF §4.6), leaving `.receiverOrPump` to a G7
/// receiver for the side-by-side check in HANDOFF §11; and the only slot xDrip4iOS 7.1.0 calls
/// validated (TextsBluetoothPeripheralView.swift:368-370).
public enum G7AuthenticationSlot: UInt8, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Slot 1: per xDrip4iOS, the identity for a Dexcom receiver or a Dexcom-integrated insulin pump
    /// (AuthRequestTxMessage.swift:42-43). Pairing here would evict a paired receiver/pump.
    case receiverOrPump = 0x01
    /// Slot 2: the phone-app identity; xDrip4iOS default (AuthRequestTxMessage.swift:39-40, :48-49).
    case mobileApp = 0x02
    /// Slot 3: per xDrip4iOS, the identity for a directly connected smart watch
    /// (AuthRequestTxMessage.swift:45-46).
    case smartWatch = 0x03

    /// `.mobileApp`, see the type documentation.
    public static let recommendedDefault: G7AuthenticationSlot = .mobileApp
}
