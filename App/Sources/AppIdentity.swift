// The app's name lives in one place: APP_DISPLAY_NAME in Config/Base.xcconfig, which becomes
// CFBundleDisplayName. UI copy reads it from here, so a rename touches no Swift code.

import Foundation

enum AppIdentity {
    /// Fallback when the bundle has no display name (unit-test hosts, previews).
    static let fallbackName = "Sensor"

    static var displayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
    }

    /// "0.1.0 (1)"
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// Deep links from the widget (HANDOFF §7.4: tapping a widget opens Now).
enum DeepLink {
    /// `<scheme>://now`. The scheme is `$(BUNDLE_ID_PREFIX)` (App/Info.plist CFBundleURLTypes).
    static let nowHost = "now"

    static func tab(for url: URL) -> AppTab? {
        url.host == nowHost ? .now : nil
    }
}
