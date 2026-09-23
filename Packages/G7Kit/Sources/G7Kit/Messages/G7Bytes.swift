// Original to Sensor (no ported code).

import Foundation

/// Little-endian field readers and writers for G7 wire messages.
///
/// Every multi-byte G7 field is little-endian. Sources: xDrip4iOS
/// `xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/DexcomG7ExtendedVersionMessage.swift:35`
/// ("All multibyte fields in the G7 control response are little-endian") and xDrip4iOS
/// `xDrip/Extensions/Data.swift:82-96` (fields are copied into / out of native little-endian
/// integers). Callers check the message length before reading.
enum G7Bytes {
    static func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    static func uint24(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
    }

    static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        uint24(bytes, at: offset) | UInt32(bytes[offset + 3]) << 24
    }

    static func littleEndian(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    static func littleEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
    }
}
