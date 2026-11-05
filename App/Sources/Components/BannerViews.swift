// S5 banners and the DEBUG build banner.

import GlucoseCore
import SwiftUI
import WidgetCore

struct BannerView: View {
    let banner: AppBanner
    let perform: (AppBanner.Action) -> Void

    var body: some View {
        Group {
            if banner.compact { compactBody } else { fullBody }
        }
        .overlay(Rectangle().stroke(Theme.rule, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(banner.severity == .critical ? "Alert" : "Warning"): \(banner.title). \(banner.detail)"))
    }

    private var fullBody: some View {
        HStack(alignment: .top, spacing: 12) {
            rule
            VStack(alignment: .leading, spacing: 4) {
                title(size: 14)
                detail(size: 13)
                actionButton
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.trailing, 12)
    }

    /// Title and detail with the action beside them. The rule is an overlay, not a row member, so
    /// the banner takes only its own height.
    private var compactBody: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                title(size: 13)
                detail(size: 12)
            }
            Spacer(minLength: 0)
            actionButton
        }
        .padding(.vertical, 6)
        .padding(.leading, 15)
        .padding(.trailing, 12)
        .overlay(alignment: .leading) { rule }
    }

    private var rule: some View {
        Rectangle()
            .fill(banner.severity == .critical ? AnyShapeStyle(Theme.band(.veryLow)) : AnyShapeStyle(Theme.band(.high)))
            .frame(width: 3)
            .accessibilityHidden(true)
    }

    private func title(size: CGFloat) -> some View {
        Text(verbatim: banner.title)
            .font(Typography.body(size: size, weight: .semibold))
            .foregroundStyle(banner.severity == .critical ? AnyShapeStyle(Theme.alert) : AnyShapeStyle(Theme.ink))
    }

    private func detail(size: CGFloat) -> some View {
        Text(verbatim: banner.detail)
            .font(Typography.body(size: size))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var actionButton: some View {
        if let action = banner.action, let title = banner.actionTitle {
            Button(title) { perform(action) }
                .buttonStyle(LinkButtonStyle())
        }
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
        .accessibilityIdentifier("build.banner")
    }
}
