// swift-tools-version: 6.0
// ForecastKit — fetches, validates and classifies the Zen Predict forecast feed for the Predict tab
// (PROGRESS D57). Owner: WS7. See docs/forecast.md.
//
// NO DEPENDENCIES, Foundation only. That is the structural half of D57's rule that a forecast is
// never a reading: without GlucoseCore, nothing here can build a `GlucoseReading`, and the types
// here cannot be passed where a reading is expected. scripts/check.sh (D57 forecast isolation)
// fails unless this manifest has exactly the two targets below, no package dependencies, no
// target dependency but the tests' on ForecastKit, and no unsafe flags, linked libraries or
// plugins; it also limits which files may import ForecastKit (docs/forecast.md "Enforcement").
import PackageDescription

let package = Package(
    name: "ForecastKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ForecastKit", targets: ["ForecastKit"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "ForecastKit"),
        .testTarget(
            name: "ForecastKitTests",
            dependencies: ["ForecastKit"],
            // zen-predict-infra's sample fixtures and synthetic documents in the live format.
            resources: [.copy("Fixtures")]
        ),
    ]
)
