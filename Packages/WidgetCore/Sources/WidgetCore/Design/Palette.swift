// Design tokens (HANDOFF §7.1), final values. Contrast ratios for every text/background pair are
// asserted in `DesignTokenContrastTests` and recorded in `docs/design-tokens.md`.
//
// Deviations from the §7.1 table (both forced by WCAG AA, see docs/design-tokens.md):
//   light `high`     #C58A2B → #B07B26  (2.64:1 → 3.26:1 on background; §7.1 value fails 3:1)
//   light `veryHigh` #8A5A12 → #754D0F  (keeps the ~2:1 separation from `high` the table had)
// Dark accents are the "lightened equivalents, same hues" §7.1 asks for (HLS lightness raised,
// hue and saturation unchanged).

import GlucoseCore

/// One colour scheme's worth of tokens (accent excluded; see `AccentChoice`).
public struct Palette: Sendable, Equatable {
    public let background: RGBColor
    public let ink: RGBColor
    public let muted: RGBColor
    /// Hairlines and dividers. Decorative only; never used for text.
    public let rule: RGBColor
    /// Fill of the 70–180 target band in charts. Decorative only; never used for text.
    public let rangeBand: RGBColor
    /// < 54 mg/dL and the sensor LOW flag.
    public let veryLow: RGBColor
    /// 54–69 mg/dL.
    public let low: RGBColor
    /// 181–250 mg/dL.
    public let high: RGBColor
    /// > 250 mg/dL and the sensor HIGH flag.
    public let veryHigh: RGBColor

    public static let light = Palette(
        background: RGBColor(hex: 0xF4F1EA),
        ink: RGBColor(hex: 0x1B1A17),
        muted: RGBColor(hex: 0x6B665C),
        rule: RGBColor(hex: 0xD9D3C7),
        rangeBand: RGBColor(hex: 0xE8E2D5),
        veryLow: RGBColor(hex: 0x7A2418),
        low: RGBColor(hex: 0xB3412E),
        high: RGBColor(hex: 0xB07B26),
        veryHigh: RGBColor(hex: 0x754D0F)
    )

    public static let dark = Palette(
        background: RGBColor(hex: 0x161513),
        ink: RGBColor(hex: 0xEDE8DE),
        muted: RGBColor(hex: 0xA39C8E),
        rule: RGBColor(hex: 0x2E2B26),
        rangeBand: RGBColor(hex: 0x24211C),
        veryLow: RGBColor(hex: 0xE0786A),
        low: RGBColor(hex: 0xE89080),
        high: RGBColor(hex: 0xE0B060),
        veryHigh: RGBColor(hex: 0xD49A40)
    )

    /// Colour for a consensus range bin. `.inRange` uses the accent, as in the mockups.
    public func color(for band: GlucoseBand, accent: RGBColor) -> RGBColor {
        switch band {
        case .veryLow: return veryLow
        case .low: return low
        case .inRange: return accent
        case .high: return high
        case .veryHigh: return veryHigh
        }
    }
}

/// The user-selectable accent (HANDOFF §7.1, Settings → Accent colour).
public enum AccentChoice: String, Sendable, Equatable, Hashable, Codable, CaseIterable, Identifiable {
    case forest
    case rust
    case navy
    case ink

    public static let `default`: AccentChoice = .forest

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .forest: return "Forest"
        case .rust: return "Rust"
        case .navy: return "Navy"
        case .ink: return "Ink"
        }
    }

    public var light: RGBColor {
        switch self {
        case .forest: return RGBColor(hex: 0x2F6B4F)
        case .rust: return RGBColor(hex: 0x9A4A26)
        case .navy: return RGBColor(hex: 0x2D4E7A)
        case .ink: return RGBColor(hex: 0x1B1A17)
        }
    }

    public var dark: RGBColor {
        switch self {
        case .forest: return RGBColor(hex: 0x4BAA7E)
        case .rust: return RGBColor(hex: 0xD57B53)
        case .navy: return RGBColor(hex: 0x6A92C8)
        // The ink accent follows the ink token so it stays visible on the dark background.
        case .ink: return RGBColor(hex: 0xEDE8DE)
        }
    }
}
