// Trend arrow glyph, drawn like the mockup's (designs/now-screen.reference.html: a thin shaft with
// an open chevron head). The arrow comes from `TrendArrow`, i.e. from the sensor-reported rate;
// this view only draws it (HANDOFF §7.5).

import GlucoseCore
import SwiftUI

/// One arrow pointing right, on a 24 × 24 design grid, centred in the rect.
struct TrendArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        let originX = rect.midX - 12 * unit
        let originY = rect.midY - 12 * unit
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * unit, y: originY + y * unit)
        }
        var path = Path()
        path.move(to: point(2, 12))
        path.addLine(to: point(22, 12))
        path.move(to: point(15, 5))
        path.addLine(to: point(22, 12))
        path.addLine(to: point(15, 19))
        return path
    }
}

/// Draws `arrow` in the current foreground style. Draws nothing for `.notComputable` (the sensor
/// reported no rate). Hidden from VoiceOver: the surrounding label speaks the trend word.
public struct TrendArrowView: View {
    public let arrow: TrendArrow
    public let size: CGFloat
    public let lineWidth: CGFloat

    public init(arrow: TrendArrow, size: CGFloat = 28, lineWidth: CGFloat = 2) {
        self.arrow = arrow
        self.size = size
        self.lineWidth = lineWidth
    }

    public var body: some View {
        HStack(spacing: -size * 0.45) {
            ForEach(0..<Self.count(arrow), id: \.self) { _ in
                TrendArrowShape()
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(Self.degrees(arrow)))
            }
        }
        .accessibilityHidden(true)
    }

    /// Clockwise rotation from "pointing right". Up is −90°.
    static func degrees(_ arrow: TrendArrow) -> Double {
        switch arrow {
        case .doubleUp, .singleUp: return -90
        case .fortyFiveUp: return -45
        case .flat, .notComputable: return 0
        case .fortyFiveDown: return 45
        case .singleDown, .doubleDown: return 90
        }
    }

    static func count(_ arrow: TrendArrow) -> Int {
        switch arrow {
        case .doubleUp, .doubleDown: return 2
        case .notComputable: return 0
        default: return 1
        }
    }
}
