import XCTest
@testable import WidgetCore

/// WCAG AA for every text/background pair the design uses, in both modes (HANDOFF §7.1).
/// Body text needs 4.5:1; text ≥ 24 pt and graphical marks (chart lines, range-bar segments,
/// dots) need 3:1. Values and ratios are recorded in docs/design-tokens.md.
final class DesignTokenContrastTests: XCTestCase {
    private let schemes: [(name: String, palette: Palette, accent: (AccentChoice) -> SRGBColor)] = [
        ("light", .light, { $0.light }),
        ("dark", .dark, { $0.dark }),
    ]

    func test_contrastMathMatchesWCAGReferencePoints() {
        let black = SRGBColor(hex: 0x000000)
        let white = SRGBColor(hex: 0xFFFFFF)
        XCTAssertEqual(SRGBColor.contrastRatio(black, white), 21, accuracy: 0.0001)
        XCTAssertEqual(SRGBColor.contrastRatio(white, white), 1, accuracy: 0.0001)
        // #777777 on white is the textbook "just fails 4.5:1" grey (4.48:1).
        XCTAssertEqual(SRGBColor.contrastRatio(SRGBColor(hex: 0x777777), white), 4.48, accuracy: 0.01)
        XCTAssertEqual(SRGBColor(hex: 0x2F6B4F).hexString, "#2F6B4F")
        XCTAssertEqual(SRGBColor(hex: 0x07000A).hexString, "#07000A")
    }

    /// Small text: ink, muted, the alert colour (banners, stale labels), the LOW/HIGH chart-marker
    /// colours (veryLow/veryHigh at 8–10 pt), and every accent (e.g. "+4 pts vs prior 14d").
    func test_bodyTextPairsMeetAA_4_5() {
        for scheme in schemes {
            let p = scheme.palette
            var pairs: [(String, SRGBColor)] = [
                ("ink", p.ink), ("muted", p.muted), ("alert(low)", p.low),
                ("veryLow", p.veryLow), ("veryHigh", p.veryHigh),
            ]
            for accent in AccentChoice.allCases {
                pairs.append(("accent.\(accent.rawValue)", scheme.accent(accent)))
            }
            for (name, color) in pairs {
                let ratio = SRGBColor.contrastRatio(color, p.background)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(scheme.name) \(name) \(color) on background \(p.background): \(ratio)")
            }
        }
    }

    /// Background-coloured text on an accent fill (primary buttons, selected accent swatch).
    func test_textOnAccentFillMeetsAA_4_5() {
        for scheme in schemes {
            for accent in AccentChoice.allCases {
                let fill = scheme.accent(accent)
                let ratio = SRGBColor.contrastRatio(scheme.palette.background, fill)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(scheme.name) background text on \(accent) \(fill): \(ratio)")
            }
        }
    }

    /// Large text (hero numbers coloured by range) and graphical marks: every band colour and
    /// accent on the background, and chart marks (ink line, accent dot) on the target band fill.
    func test_largeTextAndGraphicsMeetAA_3() {
        for scheme in schemes {
            let p = scheme.palette
            var onBackground: [(String, SRGBColor)] = [
                ("veryLow", p.veryLow), ("low", p.low), ("high", p.high), ("veryHigh", p.veryHigh),
            ]
            for accent in AccentChoice.allCases {
                onBackground.append(("accent.\(accent.rawValue)", scheme.accent(accent)))
            }
            for (name, color) in onBackground {
                let ratio = SRGBColor.contrastRatio(color, p.background)
                XCTAssertGreaterThanOrEqual(ratio, 3, "\(scheme.name) \(name) \(color) on background: \(ratio)")
            }
            var onBand: [(String, SRGBColor)] = [("ink line", p.ink)]
            for accent in AccentChoice.allCases {
                onBand.append(("accent dot \(accent.rawValue)", scheme.accent(accent)))
            }
            for (name, color) in onBand {
                let ratio = SRGBColor.contrastRatio(color, p.rangeBand)
                XCTAssertGreaterThanOrEqual(ratio, 3, "\(scheme.name) \(name) \(color) on range band \(p.rangeBand): \(ratio)")
            }
        }
    }

    /// The §7.1 light `high` (#C58A2B) fails 3:1; the adjusted value is recorded here so a
    /// "fix" back to the table value is caught.
    func test_adjustedTokensAreTheDocumentedValues() {
        XCTAssertLessThan(SRGBColor.contrastRatio(SRGBColor(hex: 0xC58A2B), Palette.light.background), 3)
        XCTAssertEqual(Palette.light.high.hexString, "#B07B26")
        XCTAssertEqual(Palette.light.veryHigh.hexString, "#754D0F")
    }

    /// Adjacent range-bar segments stay distinguishable from each other (not a WCAG rule; guards
    /// against a future tweak collapsing high and very high into one colour).
    func test_adjacentBandColoursStayDistinct() {
        for scheme in schemes {
            let p = scheme.palette
            XCTAssertGreaterThanOrEqual(SRGBColor.contrastRatio(p.high, p.veryHigh), 1.2, scheme.name)
            XCTAssertGreaterThanOrEqual(SRGBColor.contrastRatio(p.low, p.veryLow), 1.2, scheme.name)
        }
    }
}
