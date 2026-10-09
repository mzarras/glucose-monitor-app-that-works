// Text-only tab bar "Now · Predict · Trends · Settings" (HANDOFF §7.3 as changed by PROGRESS D56),
// 44 pt minimum targets. Alerts lives in Settings › Alerts since D56.

import SwiftUI
import WidgetCore

enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case now
    case predict
    case trends
    case settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .now: return "Now"
        case .predict: return "Predict"
        case .trends: return "Trends"
        case .settings: return "Settings"
        }
    }
}

/// Which tabs show the red "needs attention" dot. Pure: recomputed from the current view states on
/// every render, so a dot clears the moment its cause does (no flag to reset, no relaunch).
enum TabAttention {
    /// - Now: any S5 banner is showing (a problem is visible from any tab).
    /// - Settings: the alarm volume is too low (D55: no longer a Now banner; Settings shows the
    ///   notice and the red "Alarm volume" row).
    static func tabs(nowBanners: [AppBanner], settings: SettingsViewState) -> Set<AppTab> {
        var tabs: Set<AppTab> = []
        if !nowBanners.isEmpty { tabs.insert(.now) }
        if settings.needsAttention { tabs.insert(.settings) }
        return tabs
    }
}

struct SensorTabBar: View {
    static let maxTypeSize = DynamicTypeSize.xxxLarge

    let selected: AppTab
    /// Tabs that show the red dot (`TabAttention.tabs`).
    let attention: Set<AppTab>
    let select: (AppTab) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 0) {
                ForEach(AppTab.allCases) { tab in
                    let isSelected = tab == selected
                    let needsAttention = attention.contains(tab)
                    Button {
                        select(tab)
                    } label: {
                        HStack(spacing: 5) {
                            Text(verbatim: tab.title)
                                .font(Typography.body(size: 13, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.muted))
                                .lineLimit(1)
                                .fixedSize()
                                .layoutProbe("tab.title.\(tab.rawValue)")
                            if needsAttention {
                                Circle().fill(Theme.alert).frame(width: 6, height: 6)
                                    .layoutProbe("tab.dot.\(tab.rawValue)")
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: Layout.minTarget + 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Like the system tab bar: titles stop growing at xxxLarge; at accessibility
                    // sizes a long press shows the Large Content Viewer (review m9).
                    .dynamicTypeSize(...Self.maxTypeSize)
                    .accessibilityShowsLargeContentViewer {
                        Text(verbatim: tab.title)
                    }
                    .accessibilityLabel(Text(verbatim: Self.accessibilityLabel(tab, needsAttention: needsAttention)))
                    .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
                }
            }
        }
        .background(Theme.background)
    }

    /// "Settings" or "Settings, needs attention".
    static func accessibilityLabel(_ tab: AppTab, needsAttention: Bool) -> String {
        needsAttention ? "\(tab.title), needs attention" : tab.title
    }
}
