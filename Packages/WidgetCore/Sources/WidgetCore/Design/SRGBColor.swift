// Plain sRGB colour value plus the WCAG 2.x contrast maths used to check the design tokens
// (HANDOFF §7.1). No UI framework here so the contrast test runs on the host.

import Foundation

/// An opaque sRGB colour, 8 bits per channel.
public struct SRGBColor: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    /// `SRGBColor(hex: 0x2F6B4F)` is `#2F6B4F`.
    public init(hex: UInt32) {
        red = UInt8((hex >> 16) & 0xFF)
        green = UInt8((hex >> 8) & 0xFF)
        blue = UInt8(hex & 0xFF)
    }

    /// `#RRGGBB`, upper case, as written in `docs/design-tokens.md`.
    public var hexString: String {
        func pair(_ value: UInt8) -> String {
            let digits = String(value, radix: 16, uppercase: true)
            return value < 16 ? "0" + digits : digits
        }
        return "#" + pair(red) + pair(green) + pair(blue)
    }

    public var description: String { hexString }

    /// WCAG 2.x relative luminance.
    /// Source: https://www.w3.org/TR/WCAG21/#dfn-relative-luminance
    public var relativeLuminance: Double {
        func linear(_ channel: UInt8) -> Double {
            let c = Double(channel) / 255
            // 0.04045 is the sRGB transfer-function breakpoint (the WCAG text says 0.03928, which
            // comes from an older sRGB draft; the result is identical for 8-bit values).
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2.x contrast ratio, 1...21, symmetric in its arguments.
    /// Source: https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio
    public static func contrastRatio(_ a: SRGBColor, _ b: SRGBColor) -> Double {
        let la = a.relativeLuminance
        let lb = b.relativeLuminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
