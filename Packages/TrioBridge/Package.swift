// swift-tools-version: 6.0
// TrioBridge — writes valid sensor readings into Trio's App Group (HANDOFF §8).
// Owner: WS6. See HANDOFF.md §4.2.
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
        .testTarget(name: "TrioBridgeTests", dependencies: ["TrioBridge"]),
    ]
)
