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
/// `authenticated` is byte 1 == 0x01 (AuthChallengeRxMessage.swift:25). `paired` is byte 2 == 0x01,
/// as LoopKit G7SensorKit reads it (Messages/AuthChallengeRxMessage.swift:24-25). Sensor change:
/// xDrip4iOS reads paired as byte 2 != 0x02 (:26). The two agree on 0x01 and 0x02, the only values in
/// any capture; for any other byte the strict reading treats the client as not paired, which leads
/// to a clean full bootstrap instead of trusting an unknown status.
struct G7AuthStatusMessage: Equatable {
    let authenticated: Bool
    let paired: Bool

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 3, bytes[0] == G7Opcode.authStatus.rawValue else { return nil }
        authenticated = bytes[1] == 0x01
        paired = bytes[2] == 0x01
    }
}
