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
    public let background: SRGBColor
    public let ink: SRGBColor
    public let muted: SRGBColor
    /// Hairlines and dividers. Decorative only; never used for text.
    public let rule: SRGBColor
    /// Fill of the 70–180 target band in charts. Decorative only; never used for text.
    public let rangeBand: SRGBColor
    /// < 54 mg/dL and the sensor LOW flag.
    public let veryLow: SRGBColor
    /// 54–69 mg/dL.
    public let low: SRGBColor
    /// 181–250 mg/dL.
    public let high: SRGBColor
    /// > 250 mg/dL and the sensor HIGH flag.
    public let veryHigh: SRGBColor

    public static let light = Palette(
        background: SRGBColor(hex: 0xF4F1EA),
        ink: SRGBColor(hex: 0x1B1A17),
        muted: SRGBColor(hex: 0x6B665C),
        rule: SRGBColor(hex: 0xD9D3C7),
        rangeBand: SRGBColor(hex: 0xE8E2D5),
        veryLow: SRGBColor(hex: 0x7A2418),
        low: SRGBColor(hex: 0xB3412E),
        high: SRGBColor(hex: 0xB07B26),
        veryHigh: SRGBColor(hex: 0x754D0F)
    )

    public static let dark = Palette(
        background: SRGBColor(hex: 0x161513),
        ink: SRGBColor(hex: 0xEDE8DE),
        muted: SRGBColor(hex: 0xA39C8E),
        rule: SRGBColor(hex: 0x2E2B26),
        rangeBand: SRGBColor(hex: 0x24211C),
        veryLow: SRGBColor(hex: 0xE0786A),
        low: SRGBColor(hex: 0xE89080),
        high: SRGBColor(hex: 0xE0B060),
        veryHigh: SRGBColor(hex: 0xD49A40)
    )

    /// Colour for a consensus range bin. `.inRange` uses the accent, as in the mockups.
    public func color(for band: GlucoseBand, accent: SRGBColor) -> SRGBColor {
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

    public var light: SRGBColor {
        switch self {
        case .forest: return SRGBColor(hex: 0x2F6B4F)
        case .rust: return SRGBColor(hex: 0x9A4A26)
        case .navy: return SRGBColor(hex: 0x2D4E7A)
        case .ink: return SRGBColor(hex: 0x1B1A17)
        }
    }

    public var dark: SRGBColor {
        switch self {
        case .forest: return SRGBColor(hex: 0x4BAA7E)
        case .rust: return SRGBColor(hex: 0xD57B53)
        case .navy: return SRGBColor(hex: 0x6A92C8)
        // The ink accent follows the ink token so it stays visible on the dark background.
        case .ink: return SRGBColor(hex: 0xEDE8DE)
        }
    }
}
