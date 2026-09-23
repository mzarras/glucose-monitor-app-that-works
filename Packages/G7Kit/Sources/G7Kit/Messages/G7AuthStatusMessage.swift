//
//  AuthChallengeRxMessage.swift
//  xDrip5
//
//  Created by Nathan Racklyeft on 11/22/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/AuthChallengeRxMessage.swift @ 7.1.0 (0370937)
// Changes: renamed; reads [UInt8].

import Foundation

/// The sensor's `0x05` authentication status: `05 || authenticated || paired`.
///
/// `authenticated` is byte 1 == 0x01 and `paired` is byte 2 != 0x02, exactly as xDrip4iOS primary
/// mode decides (AuthChallengeRxMessage.swift:25-26). LoopKit G7SensorKit reads byte 2 == 0x01 as
/// "bonded" instead (G7SensorKit Messages/AuthChallengeRxMessage.swift:24-25); the two agree on
/// 0x01 and 0x02, the only values in any capture. This package follows xDrip4iOS because its
/// primary-mode state machine (DexcomG7AuthSession.swift:463-475) was validated with it.
struct G7AuthStatusMessage: Equatable {
    let authenticated: Bool
    let paired: Bool

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 3, bytes[0] == G7Opcode.authStatus.rawValue else { return nil }
        authenticated = bytes[1] == 0x01
        paired = bytes[2] != 0x02
    }
}
