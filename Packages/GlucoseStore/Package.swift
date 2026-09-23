// swift-tools-version: 6.0
// GlucoseStore — SQLite persistence (GRDB), dedupe, range queries, retention.
// Owner: WS2. See HANDOFF.md §4.2.
import PackageDescription

let package = Package(
    name: "GlucoseStore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "GlucoseStore", targets: ["GlucoseStore"]),
    ],
    dependencies: [
        .package(path: "../GlucoseCore"),
        // Pinned exactly so every build is auditable (S8). Bump deliberately.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "GlucoseStore", dependencies: ["GlucoseCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "GlucoseStoreTests", dependencies: ["GlucoseStore"]),
    ]
)
