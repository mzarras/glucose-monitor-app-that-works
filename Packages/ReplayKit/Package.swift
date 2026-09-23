// swift-tools-version: 6.0
// ReplayKit — DEBUG-only CGMSource implementations (Nightscout JSON export, scripted scenarios). All sources are wrapped in #if DEBUG (S6).
// Owner: WS2. See HANDOFF.md §4.2.
import PackageDescription

let package = Package(
    name: "ReplayKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReplayKit", targets: ["ReplayKit"]),
    ],
    dependencies: [
        .package(path: "../GlucoseCore"),
    ],
    targets: [
        .target(name: "ReplayKit", dependencies: ["GlucoseCore"]),
        .testTarget(name: "ReplayKitTests", dependencies: ["ReplayKit"]),
    ]
)
