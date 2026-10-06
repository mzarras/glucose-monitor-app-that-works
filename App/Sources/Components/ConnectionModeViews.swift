// D45/D47 controls shared by onboarding and Settings: the listen/pair choice, the calm listening
// status line, and the notes that replace pairing-only actions while listening. Shown only when
// the matching view state is non-nil (ConnectionMode.swift).

import SwiftUI
import WidgetCore

/// The two ways to connect, each with its one-line explanation. Tapping the other choice asks
/// `select`; the caller decides whether to confirm first (Settings) or move on (onboarding).
struct ConnectionModeChoices: View {
    let selected: SensorConnectionMode?
    let select: @MainActor (SensorConnectionMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SensorConnectionMode.allCases) { mode in
                Button { select(mode) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: selected == mode ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(selected == mode ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.muted))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: ConnectionModeText.title(mode))
                                .font(Typography.body(size: 15, weight: .medium))
                                .foregroundStyle(Theme.ink)
                            Text(verbatim: ConnectionModeText.explanation(mode))
                                .font(Typography.body(size: 12))
                                .foregroundStyle(Theme.muted)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    .frame(minHeight: Layout.minTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected == mode ? .isSelected : [])
                .accessibilityIdentifier("connection.\(mode.rawValue)")
                Hairline()
            }
        }
    }
}

/// "Listening — the Dexcom app owns the connection": calm (ink on the page, no alert colour).
struct ListeningStatusLine: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Theme.accent).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(verbatim: ConnectionModeText.listeningStatus)
                .font(Typography.body(size: 13))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connection.listeningStatus")
    }
}

/// A muted one-line explanation in place of a control that isn't offered.
struct ExplanationNote: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(Typography.body(size: 12))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
