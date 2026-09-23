// swift-tools-version: 6.0
// AlertEngine — alert rules, state machine, sound selection, notification scheduling (HANDOFF §5, §4.7).
// Owner: WS4. See HANDOFF.md §4.2.
import PackageDescription

let package = Package(
    name: "AlertEngine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AlertEngine", targets: ["AlertEngine"]),
    ],
    dependencies: [
        .package(path: "../GlucoseCore"),
    ],
    targets: [
        .target(name: "AlertEngine", dependencies: ["GlucoseCore"]),
        .testTarget(name: "AlertEngineTests", dependencies: ["AlertEngine"]),
    ]
)
