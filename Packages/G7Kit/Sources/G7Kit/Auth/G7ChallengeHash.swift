//
//  AESCrypt.m
//  xDripG5
//
//  Created by Nate Racklyeft on 6/17/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/AESCrypt.m @ 7.1.0 (0370937)
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/DexcomG7AuthBridge.m @ 7.1.0 (0370937)
// Changes: Objective-C → Swift; one function for the challenge hash (DexcomG7AuthBridge.m
// `challengeHashForChallenge:usingKey:`) on top of the AES-128-ECB call (AESCrypt.m).

import CommonCrypto
import Foundation

/// The Dexcom challenge hash: AES-128-ECB(key, challenge || challenge), first 8 bytes.
///
/// Used for both the `0x04` challenge response and the optional check of the sensor's token hash
/// (DexcomG7AuthBridge.m:579-598). The G6 uses the same construction with a key derived from the
/// transmitter ID, which gives an independent known-answer vector: LoopKit CGMBLEKit
/// CGMBLEKitTests/TransmitterIDTests.swift:14-17 (`testComputeHash`), key "00123456" + "00123456",
/// input 0123456789abcdef → e60d4a7999b0fbb2.
enum G7ChallengeHash {
    /// - Returns: nil if the key is not 16 bytes, the challenge is not 8 bytes, or CommonCrypto fails.
    static func hash(_ challenge: [UInt8], key: [UInt8]) -> [UInt8]? {
        guard key.count == kCCKeySizeAES128, challenge.count == 8 else { return nil }
        guard let block = aes128ECBEncrypt(challenge + challenge, key: key) else { return nil }
        return Array(block[0..<8])
    }

    /// One AES-128 block in ECB mode without padding (AESCrypt.m:14-31: kCCOptionECBMode only).
    static func aes128ECBEncrypt(_ block: [UInt8], key: [UInt8]) -> [UInt8]? {
        guard block.count == kCCBlockSizeAES128, key.count == kCCKeySizeAES128 else { return nil }
        var output = [UInt8](repeating: 0, count: block.count + kCCBlockSizeAES128)
        var written = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),
            key, key.count,
            nil,
            block, block.count,
            &output, output.count,
            &written
        )
        guard status == kCCSuccess, written == kCCBlockSizeAES128 else { return nil }
        return Array(output[0..<written])
    }
}
