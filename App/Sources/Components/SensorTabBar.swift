// Text-only tab bar "Now · Trends · Alerts · Settings" (HANDOFF §7.3), 44 pt minimum targets.

import SwiftUI
import WidgetCore

enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case now
    case trends
    case alerts
    case settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .now: return "Now"
        case .trends: return "Trends"
        case .alerts: return "Alerts"
        case .settings: return "Settings"
        }
    }
}

struct SensorTabBar: View {
    let selected: AppTab
    /// Marks the Now tab while S5 banners are showing, so a problem is visible from any tab.
    let nowHasProblems: Bool
    let select: (AppTab) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 0) {
                ForEach(AppTab.allCases) { tab in
                    let isSelected = tab == selected
                    Button {
                        select(tab)
                    } label: {
                        HStack(spacing: 5) {
                            Text(verbatim: tab.title)
                                .font(Typography.body(size: 13, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.muted))
                            if tab == .now && nowHasProblems {
                                Circle().fill(Theme.alert).frame(width: 6, height: 6)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: Layout.minTarget + 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: tab == .now && nowHasProblems ? "\(tab.title), needs attention" : tab.title))
                    .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
                }
            }
        }
        .background(Theme.background)
    }
}
