// swift-tools-version: 6.0
// TrioBridge — writes valid sensor readings into Trio's App Group (HANDOFF §8).
// Owner: WS6. See HANDOFF.md §4.2 and docs/trio-bridge.md.
import PackageDescription

let package = Package(
    name: "TrioBridge",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TrioBridge", targets: ["TrioBridge"]),
    ],
    dependencies: [
        .package(path: "../GlucoseCore"),
    ],
    targets: [
        .target(name: "TrioBridge", dependencies: ["GlucoseCore"]),
        .testTarget(
            name: "TrioBridgeTests",
            dependencies: ["TrioBridge", "GlucoseCore"],
            // Golden payload the bridge must reproduce byte for byte (HANDOFF §8 step 4).
            resources: [.copy("Fixtures")]
        ),
    ]
)
