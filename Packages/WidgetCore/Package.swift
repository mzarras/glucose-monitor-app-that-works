// swift-tools-version: 6.0
// WidgetCore — widget snapshot model, App Group snapshot I/O, timeline entry generation (HANDOFF §7.4). Added in Phase 0 so widget logic is unit-testable on the host.
// Owner: WS5. See HANDOFF.md §4.2.
import PackageDescription

let package = Package(
    name: "WidgetCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WidgetCore", targets: ["WidgetCore"]),
    ],
    dependencies: [
        .package(path: "../GlucoseCore"),
    ],
    targets: [
        .target(name: "WidgetCore", dependencies: ["GlucoseCore"]),
        .testTarget(name: "WidgetCoreTests", dependencies: ["WidgetCore"]),
    ]
)
