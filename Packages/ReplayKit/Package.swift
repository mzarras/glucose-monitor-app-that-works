// swift-tools-version: 6.0
// ReplayKit — DEBUG-only CGMSource implementations (Nightscout JSON export, scripted scenarios).
// Every source file is wrapped in #if DEBUG, so Release builds contain no replay code (S6);
// scripts/check.sh verifies with nm. Owner: WS2. See HANDOFF.md §4.2, §9.3 and docs/replay.md.
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
        .testTarget(
            name: "ReplayKitTests",
            dependencies: ["ReplayKit", "GlucoseCore"],
            // Synthetic Nightscout export (no personal data). Test-only, so no replay data ships
            // in any app bundle.
            resources: [.copy("Fixtures")]
        ),
    ]
)
