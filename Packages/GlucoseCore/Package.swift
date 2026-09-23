// swift-tools-version: 6.0
// GlucoseCore — domain types and the contracts every other module builds against (HANDOFF §4.3).
// No I/O. No dependencies.
import PackageDescription

let package = Package(
    name: "GlucoseCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "GlucoseCore", targets: ["GlucoseCore"]),
    ],
    targets: [
        .target(name: "GlucoseCore"),
        .testTarget(name: "GlucoseCoreTests", dependencies: ["GlucoseCore"]),
    ]
)
