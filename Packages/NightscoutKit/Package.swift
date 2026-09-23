// swift-tools-version: 6.0
// NightscoutKit — Nightscout import + upload, Clarity CSV import, Dexcom Share upload (HANDOFF §4.5, §8A).
// Owner: WS7. See HANDOFF.md §4.2.
import PackageDescription

let package = Package(
    name: "NightscoutKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NightscoutKit", targets: ["NightscoutKit"]),
    ],
    dependencies: [
        .package(path: "../GlucoseCore"),
    ],
    targets: [
        .target(name: "NightscoutKit", dependencies: ["GlucoseCore"]),
        .testTarget(name: "NightscoutKitTests", dependencies: ["NightscoutKit"]),
    ]
)
