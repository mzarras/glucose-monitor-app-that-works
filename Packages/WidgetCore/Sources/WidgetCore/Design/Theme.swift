// SwiftUI access to the design tokens. Each token is a `ShapeStyle` that resolves against the
// view's environment (colour scheme and accent choice), so it works the same in the app, in the
// widget extension, in previews, and in `ImageRenderer` screenshots.
//
// Usage: `.foregroundStyle(Theme.ink)`, `.background(Theme.background)`,
//        `.foregroundStyle(Theme.band(.low))`.

import GlucoseCore
import SwiftUI

/// A design token: one colour for light mode, one for dark.
public struct TokenStyle: ShapeStyle, Sendable {
    public let light: RGBColor
    public let dark: RGBColor

    public init(light: RGBColor, dark: RGBColor) {
        self.light = light
        self.dark = dark
    }

    public func resolve(in environment: EnvironmentValues) -> Color {
        Color(rgb: environment.colorScheme == .dark ? dark : light)
    }
}

/// The accent colour the user picked (read from the environment), or a band colour that uses it.
public struct AccentStyle: ShapeStyle, Sendable {
    public init() {}

    public func resolve(in environment: EnvironmentValues) -> Color {
        let accent = environment.accentChoice
        return Color(rgb: environment.colorScheme == .dark ? accent.dark : accent.light)
    }
}

/// Colour of a consensus range bin; `.inRange` follows the accent.
public struct BandStyle: ShapeStyle, Sendable {
    public let band: GlucoseBand

    public init(band: GlucoseBand) {
        self.band = band
    }

    public func resolve(in environment: EnvironmentValues) -> Color {
        let dark = environment.colorScheme == .dark
        let palette = dark ? Palette.dark : Palette.light
        let accent = dark ? environment.accentChoice.dark : environment.accentChoice.light
        return Color(rgb: palette.color(for: band, accent: accent))
    }
}

public enum Theme {
    public static let background = TokenStyle(light: Palette.light.background, dark: Palette.dark.background)
    public static let ink = TokenStyle(light: Palette.light.ink, dark: Palette.dark.ink)
    public static let muted = TokenStyle(light: Palette.light.muted, dark: Palette.dark.muted)
    public static let rule = TokenStyle(light: Palette.light.rule, dark: Palette.dark.rule)
    public static let rangeBand = TokenStyle(light: Palette.light.rangeBand, dark: Palette.dark.rangeBand)
    public static let accent = AccentStyle()

    /// Text or marks for warnings and errors (S5 banners, stale/no-data dots). Uses the `low` token.
    public static let alert = TokenStyle(light: Palette.light.low, dark: Palette.dark.low)

    public static func band(_ band: GlucoseBand) -> BandStyle { BandStyle(band: band) }
}

extension Color {
    public init(rgb: RGBColor) {
        self.init(
            .sRGB,
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255,
            opacity: 1
        )
    }
}

// MARK: - Accent in the environment

private struct AccentChoiceKey: EnvironmentKey {
    static let defaultValue: AccentChoice = .default
}

extension EnvironmentValues {
    /// The accent the user picked in Settings. The app sets it at the root; the widget sets it
    /// from the snapshot.
    public var accentChoice: AccentChoice {
        get { self[AccentChoiceKey.self] }
        set { self[AccentChoiceKey.self] = newValue }
    }
}
