//
//  NSData+CRC.swift
//  xDripG5
//
//  Created by Nathan Racklyeft on 4/7/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/NSData+CRC.swift @ 7.1.0 (0370937)
// Changes: free functions over [UInt8] instead of Collection/Data extensions.

/// CRC-16 CCITT (XModem): polynomial 0x1021, initial value 0, no reflection, no final XOR.
/// Appended little-endian after the payload of CRC-framed commands (G7 uses it only for the
/// `0x34` calibration command in this package). Source: NSData+CRC.swift:11-36 and :55-60.
enum G7CRC16 {
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if crc & 0x8000 != 0 {
                    crc = crc << 1 ^ 0x1021
                } else {
                    crc = crc << 1
                }
            }
        }
        return crc
    }

    /// `payload || crc16(payload)` with the CRC little-endian (NSData+CRC.swift:55-60).
    static func appending(to payload: [UInt8]) -> [UInt8] {
        payload + G7Bytes.littleEndian(checksum(payload))
    }

    /// True when the last two bytes are the little-endian CRC of the bytes before them.
    static func isValid(_ bytes: [UInt8]) -> Bool {
        guard bytes.count > 2 else { return false }
        let payload = Array(bytes.dropLast(2))
        return G7Bytes.uint16(bytes, at: bytes.count - 2) == checksum(payload)
    }
}
