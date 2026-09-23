// swift-tools-version: 6.0
// GlucoseStats — pure statistics functions for HANDOFF §6. No UI, no storage.
// Owner: WS3. See HANDOFF.md §4.2.
import PackageDescription

let package = Package(
    name: "GlucoseStats",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "GlucoseStats", targets: ["GlucoseStats"]),
    ],
    dependencies: [
        .package(path: "../GlucoseCore"),
    ],
    targets: [
        .target(name: "GlucoseStats", dependencies: ["GlucoseCore"]),
        .testTarget(name: "GlucoseStatsTests", dependencies: ["GlucoseStats"]),
    ]
)
