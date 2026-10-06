//
//  AuthRequestRxMessage.swift
//  xDrip5
//
//  Created by Nathan Racklyeft on 11/22/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/AuthRequestRxMessage.swift @ 7.1.0 (0370937)
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/DexcomG7AuthBridge.m @ 7.1.0 (0370937)
// CGMBLEKit lineage: CGMBLEKit/Messages/AuthRequestRxMessage.swift (LoopKit CGMBLEKit, formerly xDripG5;
//   MIT, Packages/G7Kit/licenses/CGMBLEKit-LICENSE), reached through xDrip4iOS;
//   compared with loopandlearn/CGMBLEKit @ 98fae79 (Trio submodule).
// Changes: the 0x02 request and 0x04 response builders are Swift versions of
// DexcomG7AuthBridge.m `makeAuthRequest` and `authChallengeResponseForTokenHash`.

import Foundation

/// `02 || token(8) || slot(1)` on Receive_Authentication. Starts short authentication with a
/// confirmed key, and also closes J-PAKE phase 2 (DexcomG7AuthBridge.m:203-218, :432).
enum G7AuthRequest {
    static let tokenLength = 8

    /// - Parameter token: 8 single-use random bytes (xDrip4iOS uses the first 8 bytes of a UUID).
    static func make(token: [UInt8], slot: G7AuthenticationSlot) -> Data {
        precondition(token.count == tokenLength, "G7 auth token must be 8 bytes")
        return Data([G7Opcode.authRequest.rawValue] + token + [slot.rawValue])
    }
}

/// The sensor's `0x03` reply: `03 || tokenHash(8) || challenge(8)`
/// (AuthRequestRxMessage.swift:16-27).
struct G7AuthChallengeMessage: Equatable {
    /// AES hash of our token under the shared key. xDrip4iOS only logs a mismatch
    /// (DexcomG7AuthBridge.m:237-249) because captures disagree on it; so do we.
    let tokenHash: [UInt8]
    /// The 8-byte challenge we must answer.
    let challenge: [UInt8]

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 17, bytes[0] == G7Opcode.authChallenge.rawValue else { return nil }
        tokenHash = Array(bytes[1..<9])
        challenge = Array(bytes[9..<17])
    }
}

/// `04 || hash(8)`: our answer to the challenge (DexcomG7AuthBridge.m:251-260).
enum G7AuthChallengeResponse {
    static func make(hash: [UInt8]) -> Data {
        precondition(hash.count == 8, "G7 challenge hash must be 8 bytes")
        return Data([G7Opcode.authChallengeResponse.rawValue] + hash)
    }
}
