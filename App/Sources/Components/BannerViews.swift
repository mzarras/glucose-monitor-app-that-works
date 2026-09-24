// S5 banners and the DEBUG build banner.

import SwiftUI
import WidgetCore

struct BannerView: View {
    let banner: AppBanner
    let perform: (AppBanner.Action) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(banner.severity == .critical ? AnyShapeStyle(Theme.band(.veryLow)) : AnyShapeStyle(Theme.band(.high)))
                .frame(width: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: banner.title)
                    .font(Typography.body(size: 14, weight: .semibold))
                    .foregroundStyle(banner.severity == .critical ? AnyShapeStyle(Theme.alert) : AnyShapeStyle(Theme.ink))
                Text(verbatim: banner.detail)
                    .font(Typography.body(size: 13))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = banner.action, let title = banner.actionTitle {
                    Button(title) { perform(action) }
                        .buttonStyle(LinkButtonStyle())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.trailing, 12)
        .overlay(Rectangle().stroke(Theme.rule, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(banner.severity == .critical ? "Alert" : "Warning"): \(banner.title). \(banner.detail)"))
    }
}

/// Unmissable strip at the top of every tab in DEBUG builds (PROGRESS D19). Ink background,
/// background-coloured text: the inverse of everything else on screen.
struct BuildBannerView: View {
    let banner: BuildBanner

    var body: some View {
        VStack(spacing: 2) {
            Text(verbatim: banner.title)
                .monoLabel(size: 12, medium: true)
            Text(verbatim: banner.detail)
                .font(Typography.body(size: 12))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(Theme.background)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Theme.ink)
        // Stays unmissable without taking over the screen at accessibility sizes.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .layoutProbe("build.banner")
        .accessibilityElement(children: .combine)
    }
}
