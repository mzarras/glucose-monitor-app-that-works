// Settings › Import history: the onboarding import step on its own (HANDOFF §4.5). Imported
// readings feed charts and statistics only (S6).

import SwiftUI
import WidgetCore

struct ImportHistorySheet: View {
    let state: OnboardingState
    let actions: OnboardingActions
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: Layout.minTarget, height: Layout.minTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close"))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ImportStep(state: state, actions: actions, next: close, skipTitle: "Close")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 24)
            }
        }
        .padding(.horizontal, Layout.sideMargin)
        .padding(.top, 12)
        .editorialScreen()
    }
}
