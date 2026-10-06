// SwiftUI previews for every widget family and state, light and dark (HANDOFF §7.4).
// DEBUG only: samples are made up (WidgetSamples).

#if DEBUG
import SwiftUI
import WidgetCore
import WidgetKit

// MARK: Real widget chrome, all states as a timeline (use the canvas appearance toggle for dark)

#Preview("Medium", as: .systemMedium) {
    GlucoseWidget()
} timeline: {
    for state in WidgetSamples.State.allCases {
        GlucoseEntry(WidgetSamples.content(state, now: .now))
    }
}

#Preview("Small", as: .systemSmall) {
    GlucoseWidget()
} timeline: {
    for state in WidgetSamples.State.allCases {
        GlucoseEntry(WidgetSamples.content(state, now: .now))
    }
}

#Preview("Lock Screen rectangular", as: .accessoryRectangular) {
    GlucoseWidget()
} timeline: {
    for state in WidgetSamples.State.allCases {
        GlucoseEntry(WidgetSamples.content(state, now: .now))
    }
}

#Preview("Lock Screen inline", as: .accessoryInline) {
    GlucoseWidget()
} timeline: {
    for state in WidgetSamples.State.allCases {
        GlucoseEntry(WidgetSamples.content(state, now: .now))
    }
}

// MARK: Every state side by side, explicitly light and dark

private struct WidgetStateGallery: View {
    enum Family { case medium, small, rectangular, inline }
    let family: Family

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(WidgetSamples.State.allCases) { state in
                    let content = WidgetSamples.content(state, now: .now)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: state.rawValue).font(.caption2).foregroundStyle(.secondary)
                        tile(content)
                    }
                }
            }
            .padding()
        }
        .background(Color(white: 0.5))
    }

    @ViewBuilder
    private func tile(_ content: WidgetEntryContent) -> some View {
        switch family {
        case .medium:
            MediumWidgetView(content: content).padding(16).frame(width: 364, height: 170).background(Theme.background).clipShape(RoundedRectangle(cornerRadius: 22))
        case .small:
            SmallWidgetView(content: content).padding(16).frame(width: 170, height: 170).background(Theme.background).clipShape(RoundedRectangle(cornerRadius: 22))
        case .rectangular:
            RectangularAccessoryView(content: content).frame(width: 172, height: 76).foregroundStyle(.white).padding(6).background(.black.opacity(0.6))
        case .inline:
            InlineAccessoryText.text(content).foregroundStyle(.white).padding(6).background(.black.opacity(0.6))
        }
    }
}

#Preview("Medium · all states · light") { WidgetStateGallery(family: .medium).environment(\.colorScheme, .light) }
#Preview("Medium · all states · dark") { WidgetStateGallery(family: .medium).environment(\.colorScheme, .dark) }
#Preview("Small · all states · light") { WidgetStateGallery(family: .small).environment(\.colorScheme, .light) }
#Preview("Small · all states · dark") { WidgetStateGallery(family: .small).environment(\.colorScheme, .dark) }
#Preview("Rectangular · all states · light") { WidgetStateGallery(family: .rectangular).environment(\.colorScheme, .light) }
#Preview("Rectangular · all states · dark") { WidgetStateGallery(family: .rectangular).environment(\.colorScheme, .dark) }
#Preview("Inline · all states · light") { WidgetStateGallery(family: .inline).environment(\.colorScheme, .light) }
#Preview("Inline · all states · dark") { WidgetStateGallery(family: .inline).environment(\.colorScheme, .dark) }
#endif
