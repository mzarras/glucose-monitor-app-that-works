// Type scale (HANDOFF §7.2). Fonts are bundled in Resources/Fonts and registered through
// UIAppFonts in App/Info.plist and Widgets/Info.plist; see Resources/Fonts/licenses/README.md.
// If a font is missing, SwiftUI falls back to the system font (no crash), which is what host tests
// and package previews see.

import SwiftUI

public enum Typography {
    /// PostScript names of the bundled fonts (read from each file's `name` table, ID 6).
    public enum FontName {
        /// Newsreader, 72 pt optical size, Light (300). Display numerals ≥ 100 pt.
        public static let displayLight = "Newsreader72pt-Light"
        /// Newsreader, 16 pt optical size, Regular. Titles and figures 20–36 pt.
        public static let serifRegular = "Newsreader16pt-Regular"
        /// Newsreader, 16 pt optical size, Italic. The "glucose" wordmark.
        public static let serifItalic = "Newsreader16pt-Italic"
        public static let sansRegular = "IBMPlexSans"
        public static let sansMedium = "IBMPlexSans-Medm"
        public static let sansSemiBold = "IBMPlexSans-SmBld"
        public static let monoRegular = "IBMPlexMono"
        public static let monoMedium = "IBMPlexMono-Medm"

        /// Every bundled font, for the registration check in the app's tests.
        public static let all = [
            displayLight, serifRegular, serifItalic,
            sansRegular, sansMedium, sansSemiBold,
            monoRegular, monoMedium,
        ]
    }

    /// Tracking for uppercase mono labels: +0.08 em (§7.2 allows 0.06–0.08).
    public static let labelTrackingEm: CGFloat = 0.08

    // MARK: Display (Newsreader)

    /// The current reading (~132 pt). Fixed size: it does not grow with Dynamic Type, and callers
    /// pair it with `.lineLimit(1).minimumScaleFactor(…)` so it never truncates (§7.2).
    public static func heroNumeral(size: CGFloat = 132) -> Font {
        .custom(FontName.displayLight, fixedSize: size)
    }

    /// Trends hero statistic (~104 pt). Fixed size, like `heroNumeral`.
    public static func statHero(size: CGFloat = 104) -> Font {
        .custom(FontName.displayLight, fixedSize: size)
    }

    /// Section titles and figures (20–36 pt). Scales with Dynamic Type relative to `.title`.
    public static func title(size: CGFloat) -> Font {
        .custom(FontName.serifRegular, size: size, relativeTo: .title)
    }

    /// Figures that sit in a fixed layout (widgets, "Today so far"). Fixed size.
    public static func figure(size: CGFloat) -> Font {
        .custom(FontName.serifRegular, fixedSize: size)
    }

    /// The italic "glucose" wordmark in the Now header.
    public static func wordmark(size: CGFloat = 22) -> Font {
        .custom(FontName.serifItalic, size: size, relativeTo: .title2)
    }

    // MARK: UI text (IBM Plex Sans)

    public enum SansWeight: Sendable {
        case regular, medium, semibold
    }

    /// Body text, 13–14 pt, scales with Dynamic Type.
    public static func body(size: CGFloat = 14, weight: SansWeight = .regular) -> Font {
        let name: String
        switch weight {
        case .regular: name = FontName.sansRegular
        case .medium: name = FontName.sansMedium
        case .semibold: name = FontName.sansSemiBold
        }
        return .custom(name, size: size, relativeTo: .body)
    }

    // MARK: Labels (IBM Plex Mono)

    /// Data labels, timestamps, axis labels, 10–12 pt, scales with Dynamic Type.
    public static func label(size: CGFloat = 11, medium: Bool = false) -> Font {
        .custom(medium ? FontName.monoMedium : FontName.monoRegular, size: size, relativeTo: .caption)
    }

    /// Mono at a fixed size, for chart axes and widgets where layout space is fixed.
    public static func fixedLabel(size: CGFloat = 10, medium: Bool = false) -> Font {
        .custom(medium ? FontName.monoMedium : FontName.monoRegular, fixedSize: size)
    }
}

extension View {
    /// Uppercase mono label styling: IBM Plex Mono, tracked +0.08 em. The caller passes text that
    /// is already upper case (so VoiceOver reads the same words the formatter produced).
    public func monoLabel(size: CGFloat = 11, medium: Bool = false) -> some View {
        font(Typography.label(size: size, medium: medium))
            .tracking(size * Typography.labelTrackingEm)
    }
}
