// Test hook: views mark text whose full visibility matters (the hero number, the header wordmark,
// tab titles) with `.layoutProbe("name")`. When a test puts a `LayoutProbe` in the environment, the
// rendered size of each marked view is reported, so the test can compare it with the text's ideal
// size at an accessibility text size. In the app no probe is set and the modifier does nothing.

import SwiftUI

struct LayoutProbe: Sendable {
    let report: @MainActor @Sendable (_ name: String, _ size: CGSize) -> Void
}

private struct LayoutProbeKey: EnvironmentKey {
    static let defaultValue: LayoutProbe? = nil
}

extension EnvironmentValues {
    var layoutProbe: LayoutProbe? {
        get { self[LayoutProbeKey.self] }
        set { self[LayoutProbeKey.self] = newValue }
    }
}

private struct LayoutProbeModifier: ViewModifier {
    let name: String
    @Environment(\.layoutProbe) private var probe

    func body(content: Content) -> some View {
        if let probe {
            content.onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                probe.report(name, size)
            }
        } else {
            content
        }
    }
}

extension View {
    func layoutProbe(_ name: String) -> some View {
        modifier(LayoutProbeModifier(name: name))
    }
}
