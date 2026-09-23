// Small building blocks of the Editorial design (HANDOFF §7): rules, mono labels, the text
// segment picker (3H/6H…, 1D/3D…), status rows, buttons. All targets are ≥ 44 pt.

import SwiftUI
import WidgetCore

/// Minimum tap target (HANDOFF §7.3: 44 pt).
enum Layout {
    static let minTarget: CGFloat = 44
    static let sideMargin: CGFloat = 20
    static let sectionSpacing: CGFloat = 18
}

/// 1 pt horizontal line in the `rule` token (or `ink` for section tops, as in the mockups).
struct Hairline: View {
    var strong = false

    var body: some View {
        Rectangle()
            .fill(strong ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.rule))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// Upper-case mono label in the muted colour, e.g. "TODAY SO FAR".
struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(verbatim: text)
            .monoLabel(size: 11)
            .foregroundStyle(Theme.muted)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Row of text buttons with the selected one underlined in the accent (mockup "3H 6H 12H 24H").
struct TextSegmentPicker<Option: Identifiable & Equatable>: View {
    /// A compact control: labels grow with Dynamic Type up to this size, then stay put so the
    /// segments never run together; each segment is still ≥ 44 pt.
    static var maxTypeSize: DynamicTypeSize { .xxxLarge }

    let options: [Option]
    let selected: Option
    let label: (Option) -> String
    let spokenLabel: (Option) -> String
    let select: (Option) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                let isSelected = option == selected
                Button {
                    select(option)
                } label: {
                    Text(verbatim: label(option))
                        .font(Typography.label(size: 12, medium: isSelected))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.muted))
                        .padding(.bottom, 3)
                        .overlay(alignment: .bottom) {
                            if isSelected {
                                Rectangle().fill(Theme.accent).frame(height: 2).offset(y: 3)
                            }
                        }
                        .frame(minWidth: Layout.minTarget, minHeight: Layout.minTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: spokenLabel(option)))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityShowsLargeContentViewer {
                    Text(verbatim: label(option))
                }
            }
        }
        .dynamicTypeSize(...Self.maxTypeSize)
    }
}

/// "SENSOR          day 6 of 10 · 4d 7h left"
struct StatusRow: View {
    let label: String
    let value: String
    var valueIsAlert = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: label)
                .monoLabel(size: 11)
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 12)
            Text(verbatim: value)
                .font(Typography.label(size: 11))
                .foregroundStyle(valueIsAlert ? AnyShapeStyle(Theme.alert) : AnyShapeStyle(Theme.ink))
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Filled accent button (background-coloured text on the accent; ≥ 4.5:1, see the contrast test).
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.body(size: 15, weight: .semibold))
            .foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity, minHeight: Layout.minTarget)
            .padding(.horizontal, 16)
            .background(Theme.accent)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
    }
}

/// Outlined ink button.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.body(size: 15, weight: .medium))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: Layout.minTarget)
            .padding(.horizontal, 16)
            .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
    }
}

/// Underlined accent text button (banner actions, inline links).
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.body(size: 13, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .underline()
            .frame(minHeight: Layout.minTarget)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Screen background and ink text, applied once per screen root. Concrete colours (not the token
/// styles) so UIKit-backed controls inside — text fields, menus, pickers — inherit them too.
struct EditorialScreen: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Theme.ink.color(for: colorScheme))
            .background(Theme.background.color(for: colorScheme), ignoresSafeAreaEdges: .all)
    }
}

extension View {
    func editorialScreen() -> some View { modifier(EditorialScreen()) }
}
