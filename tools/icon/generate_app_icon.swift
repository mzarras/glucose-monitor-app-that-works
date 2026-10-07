// Sensor — app icon generator (PROGRESS.md D52).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Draws the app icon from code: the Now screen's trend arrow with "mg/dL" under it, in the light
// theme. No glucose number appears anywhere in the icon (safety rule S1).
//
//   swift tools/icon/generate_app_icon.swift            # (re)write the icon set and the previews
//   swift tools/icon/generate_app_icon.swift --check    # verify the committed icons match, exit 1 if not
//
// Design sources (the icon copies these; change them there first):
//   Arrow     TrendArrowShape, Packages/WidgetCore/Sources/WidgetCore/Views/TrendArrowView.swift:
//             a 24 × 24 grid, shaft (2, 12) → (22, 12), open chevron (15, 5) → (22, 12) → (15, 19),
//             stroked with round caps and joins. The Now hero (App/Sources/Screens/Now/NowScreen.swift,
//             `arrow(_:)`) draws it pointing right at size 32 with a 2 pt line (1.5 grid units) in
//             Theme.accent. The icon uses the same geometry with a thicker line so it reads at 60 px.
//   "mg/dL"   GlucoseText.unit, set like the hero caption (`caption(_:)`): Typography.label, i.e.
//             IBM Plex Mono Regular (Resources/Fonts/IBMPlexMono-Regular.ttf, SIL OFL 1.1, credited
//             in NOTICE.md), in Theme.ink, under the arrow.
//   Colours   docs/design-tokens.md. Light: background #F4F1EA, accent.forest #2F6B4F, ink #1B1A17.
//             Dark: background #161513, accent.forest #4BAA7E, ink #EDE8DE.
//
// Output:
//   App/Assets.xcassets/AppIcon.appiconset/AppIcon.png          1024 × 1024, sRGB, opaque: no alpha
//                                                               channel (App Store rule). Square
//                                                               corners; iOS applies its own mask.
//   App/Assets.xcassets/AppIcon.appiconset/AppIcon-Dark.png     iOS 18+ dark appearance, opaque.
//   App/Assets.xcassets/AppIcon.appiconset/AppIcon-Tinted.png   iOS 18+ tinted appearance: grayscale
//                                                               glyph on transparent (Apple HIG).
//   docs/screenshots/app-icon-candidates/                       every candidate at 1024, 180, 120 and
//                                                               60 px (corners masked like iOS), the
//                                                               chosen design's dark and tinted
//                                                               variants, and overview.png.
//
// Determinism: fixed geometry, a bundled font, no randomness, no timestamps in the PNGs. Re-running
// produces identical bytes; `--check` proves it against the committed icon files.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Design tokens (docs/design-tokens.md)

struct RGB {
    let r: CGFloat, g: CGFloat, b: CGFloat
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }
    var cgColor: CGColor { CGColor(colorSpace: sRGB, components: [r, g, b, 1])! }
}

struct Palette {
    /// nil = transparent (the tinted appearance).
    let background: RGB?
    let arrow: RGB
    let text: RGB

    static let light = Palette(background: RGB(0xF4F1EA), arrow: RGB(0x2F6B4F), text: RGB(0x1B1A17))
    static let dark = Palette(background: RGB(0x161513), arrow: RGB(0x4BAA7E), text: RGB(0xEDE8DE))
    /// Apple HIG, tinted icons: a grayscale image the system tints; white glyph on transparent.
    static let tinted = Palette(background: nil, arrow: RGB(0xFFFFFF), text: RGB(0xFFFFFF))
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let canvas: CGFloat = 1024

// MARK: - Designs

/// One composition: the arrow over "mg/dL". Lengths are pixels on the 1024 canvas unless noted.
struct Design {
    let name: String
    let summary: String
    /// Pixels per TrendArrowShape grid unit (the grid is 24 units square).
    let gridUnit: CGFloat
    /// Stroke width in grid units. The hero's 2 pt line at size 32 is 1.5 units.
    let lineWidthUnits: CGFloat
    /// Point size of "mg/dL" in pixels.
    let textSize: CGFloat
    /// IBM Plex Mono Medium instead of Regular (the hero uses Regular).
    let mediumText: Bool
    /// Gap between the bottom of the arrow's ink and the top of the text's ink.
    let gap: CGFloat
    /// Arrow and text share a left edge, as in the hero's side column; otherwise both are centred.
    let leadingAligned: Bool
}

let designs: [Design] = [
    Design(name: "A", summary: "hero stack: left-aligned like the Now screen, 2-unit line, Plex Mono Regular a little wider than the arrow",
           gridUnit: 24, lineWidthUnits: 2.0, textSize: 186, mediumText: false, gap: 96, leadingAligned: true),
    Design(name: "B", summary: "centred, 2.75-unit line, Plex Mono Regular a little narrower than the arrow",
           gridUnit: 25, lineWidthUnits: 2.75, textSize: 162, mediumText: false, gap: 80, leadingAligned: false),
    Design(name: "C", summary: "centred, heavy 3.5-unit line, larger Plex Mono Medium, tight gap",
           gridUnit: 23, lineWidthUnits: 3.5, textSize: 172, mediumText: true, gap: 70, leadingAligned: false),
]

/// The design that becomes AppIcon.png (and its dark and tinted variants).
let chosenName = "A"

// MARK: - Font

func registerFonts(root: URL) {
    for file in ["IBMPlexMono-Regular.ttf", "IBMPlexMono-Medium.ttf"] {
        let url = root.appendingPathComponent("Resources/Fonts/\(file)")
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            fatal("could not register \(url.path): \(String(describing: error?.takeRetainedValue()))")
        }
    }
}

/// PostScript names as in Typography.FontName (monoRegular, monoMedium).
func plexMono(size: CGFloat, medium: Bool) -> CTFont {
    let name = medium ? "IBMPlexMono-Medm" : "IBMPlexMono"
    let font = CTFontCreateWithName(name as CFString, size, nil)
    // CoreText silently substitutes a fallback for an unknown name; refuse that.
    guard CTFontCopyPostScriptName(font) as String == name else { fatal("font \(name) not registered") }
    return font
}

// MARK: - Drawing

/// TrendArrowShape's path, pointing right, with grid point (x, y) at origin + (x, -y) · unit
/// (CoreGraphics is y-up; the grid is y-down like SwiftUI).
func arrowPath(gridOrigin origin: CGPoint, unit: CGFloat) -> CGPath {
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * unit, y: origin.y - y * unit) }
    let path = CGMutablePath()
    path.move(to: point(2, 12))
    path.addLine(to: point(22, 12))
    path.move(to: point(15, 5))
    path.addLine(to: point(22, 12))
    path.addLine(to: point(15, 19))
    return path
}

/// Draws `design` in `palette` on a 1024 canvas. Opaque palettes give an image with no alpha channel.
func render(_ design: Design, _ palette: Palette) -> CGImage {
    let size = Int(canvas)
    let alpha: CGImageAlphaInfo = palette.background == nil ? .premultipliedLast : .noneSkipLast
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: alpha.rawValue) else { fatal("no bitmap context") }
    let bounds = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    if let background = palette.background {
        context.setFillColor(background.cgColor)
        context.fill(bounds)
    } else {
        context.clear(bounds)
    }

    // Arrow ink, in grid units: x 2 … 22, y 5 … 19, plus half the line on every side (round caps/joins).
    let unit = design.gridUnit
    let lineWidth = design.lineWidthUnits * unit
    let arrowInk = CGSize(width: 20 * unit + lineWidth, height: 14 * unit + lineWidth)

    // Text ink, from the glyph outlines (relative to the baseline origin, y-up).
    let font = plexMono(size: design.textSize, medium: design.mediumText)
    let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: palette.text.cgColor] as CFDictionary
    let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "mg/dL" as CFString, attributes)!)
    let textInk = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

    // Stack: arrow ink, gap, text ink; the whole block centred on the canvas.
    let blockHeight = arrowInk.height + design.gap + textInk.height
    let blockWidth = max(arrowInk.width, textInk.width)
    let blockTop = (canvas + blockHeight) / 2
    let arrowLeft = design.leadingAligned ? (canvas - blockWidth) / 2 : (canvas - arrowInk.width) / 2
    let textLeft = design.leadingAligned ? (canvas - blockWidth) / 2 : (canvas - textInk.width) / 2

    // Grid origin so the ink's top-left corner (grid 2 − w/2, 5 − w/2) lands at (arrowLeft, blockTop).
    let origin = CGPoint(x: arrowLeft - 2 * unit + lineWidth / 2, y: blockTop + 5 * unit - lineWidth / 2)
    context.addPath(arrowPath(gridOrigin: origin, unit: unit))
    context.setStrokeColor(palette.arrow.cgColor)
    context.setLineWidth(lineWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    let textTop = blockTop - arrowInk.height - design.gap
    context.textPosition = CGPoint(x: textLeft - textInk.minX, y: textTop - textInk.maxY)
    CTLineDraw(line, context)

    guard let image = context.makeImage() else { fatal("no image") }
    return image
}

/// `image` scaled to `pixels` square the way the system shrinks a 1024 icon, optionally with the
/// home-screen corner mask (a plain rounded rectangle, radius 22.37 % — close to iOS's squircle).
/// `backdrop` fills behind transparent pixels (for previewing the tinted variant).
func scaled(_ image: CGImage, to pixels: Int, masked: Bool, backdrop: RGB? = nil) -> CGImage {
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatal("no context") }
    let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    context.interpolationQuality = .high
    if masked {
        let radius = CGFloat(pixels) * 0.2237
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
    }
    if let backdrop {
        context.setFillColor(backdrop.cgColor)
        context.fill(rect)
    }
    context.draw(image, in: rect)
    return context.makeImage()!
}

// MARK: - Overview sheet

/// Every candidate at 180, 120 and 60 px, masked, on a light and a dark wallpaper, then the chosen
/// design's dark and tinted variants. Labels in Plex Mono.
func overview(candidates: [(Design, CGImage)], dark: CGImage, tinted: CGImage) -> CGImage {
    let sizes = [180, 120, 60]
    let pad = 40, labelWidth = 260, rowHeight = 180 + pad
    let panelWidth = labelWidth + sizes.reduce(0, +) + pad * sizes.count
    let rows = candidates.count + 1
    let width = panelWidth * 2, height = pad + rows * rowHeight
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatal("no context") }
    let walls = [(RGB(0xD8D8DC), RGB(0x1B1A17)), (RGB(0x2C2C2E), RGB(0xEDE8DE))]
    for (panel, (wall, ink)) in walls.enumerated() {
        let x0 = panel * panelWidth
        context.setFillColor(wall.cgColor)
        context.fill(CGRect(x: x0, y: 0, width: panelWidth, height: height))
        var entries: [(String, CGImage)] = candidates.map { design, image in
            ("\(design.name)\(design.name == chosenName ? " (chosen)" : "")", image)
        }
        entries.append(panel == 0 ? ("\(chosenName) tinted", tinted) : ("\(chosenName) dark", dark))
        for (row, (label, image)) in entries.enumerated() {
            let top = height - pad - row * rowHeight
            let attributes = [kCTFontAttributeName: plexMono(size: 26, medium: false),
                              kCTForegroundColorAttributeName: ink.cgColor] as CFDictionary
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, label as CFString, attributes)!)
            context.textPosition = CGPoint(x: x0 + pad, y: top - 100)
            CTLineDraw(line, context)
            var x = x0 + labelWidth
            for size in sizes {
                let backdrop: RGB? = label.hasSuffix("tinted") ? RGB(0x000000) : nil
                let icon = scaled(image, to: size, masked: true, backdrop: backdrop)
                context.draw(icon, in: CGRect(x: x, y: top - 180 + (180 - size) / 2, width: size, height: size))
                x += size + pad
            }
        }
    }
    return context.makeImage()!
}

// MARK: - Files

func pngData(_ image: CGImage) -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { fatal("no PNG encoder") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatal("PNG encoding failed") }
    return data as Data
}

func write(_ image: CGImage, to url: URL) {
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pngData(image).write(to: url)
    } catch {
        fatal("could not write \(url.path): \(error)")
    }
    print("wrote \(url.path)")
}

func fatal(_ message: String) -> Never {
    FileHandle.standardError.write(Data("generate_app_icon: \(message)\n".utf8))
    exit(1)
}

// MARK: - Main

// The repository root is two levels above this file (tools/icon/).
let root = URL(fileURLWithPath: #filePath).standardizedFileURL
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
guard FileManager.default.fileExists(atPath: root.appendingPathComponent("project.yml").path) else {
    fatal("repository root not found from \(#filePath)")
}
registerFonts(root: root)

guard let chosen = designs.first(where: { $0.name == chosenName }) else { fatal("no design \(chosenName)") }
let iconSet = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
let icons: [(String, CGImage)] = [
    ("AppIcon.png", render(chosen, .light)),
    ("AppIcon-Dark.png", render(chosen, .dark)),
    ("AppIcon-Tinted.png", render(chosen, .tinted)),
]

if CommandLine.arguments.contains("--check") {
    var mismatches = 0
    for (file, image) in icons {
        let url = iconSet.appendingPathComponent(file)
        if (try? Data(contentsOf: url)) != pngData(image) {
            print("MISMATCH \(url.path)")
            mismatches += 1
        } else {
            print("ok       \(url.path)")
        }
    }
    exit(mismatches == 0 ? 0 : 1)
}

for (file, image) in icons {
    write(image, to: iconSet.appendingPathComponent(file))
}

let previews = root.appendingPathComponent("docs/screenshots/app-icon-candidates")
var rendered: [(Design, CGImage)] = []
for design in designs {
    let image = render(design, .light)
    rendered.append((design, image))
    write(image, to: previews.appendingPathComponent("candidate-\(design.name)-1024.png"))
    for pixels in [180, 120, 60] {
        write(scaled(image, to: pixels, masked: true), to: previews.appendingPathComponent("candidate-\(design.name)-\(pixels).png"))
    }
}
let dark = icons[1].1, tinted = icons[2].1
for pixels in [180, 60] {
    write(scaled(dark, to: pixels, masked: true), to: previews.appendingPathComponent("chosen-dark-\(pixels).png"))
    write(scaled(tinted, to: pixels, masked: true, backdrop: RGB(0x000000)),
          to: previews.appendingPathComponent("chosen-tinted-\(pixels).png"))
}
write(overview(candidates: rendered, dark: dark, tinted: tinted), to: previews.appendingPathComponent("overview.png"))
