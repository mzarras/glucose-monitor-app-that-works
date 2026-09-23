// swift-tools-version: 6.0
// G7Kit — BLE scan/connect, J-PAKE auth, bonding, G7 message parsing, glucose + backfill (ported from xDrip4iOS).
// Owner: WS1. See HANDOFF.md §4.2.
import PackageDescription

let package = Package(
    name: "G7Kit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "G7Kit", targets: ["G7Kit"]),
    ],
    dependencies: [
        .package(path: "../GlucoseCore"),
    ],
    targets: [
        .target(name: "G7Kit", dependencies: ["GlucoseCore"]),
        .testTarget(name: "G7KitTests", dependencies: ["G7Kit"]),
    ]
)
