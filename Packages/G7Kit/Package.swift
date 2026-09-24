// swift-tools-version: 6.0
// G7Kit — BLE scan/connect, J-PAKE auth, bonding, G7 message parsing, glucose + backfill,
// calibration (ported from xDrip4iOS 7.1.0). Owner: WS1. See HANDOFF.md §4.2 and docs/g7-protocol.md.
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
        // P-256 point/scalar arithmetic for J-PAKE (CryptoKit does not expose point addition).
        // micro-ecc (BSD-2-Clause, LICENSE.txt next to it) is compiled only through
        // DexcomG7ECC.c's #include, as one configured translation unit, exactly like xDrip4iOS.
        // Every vendored file is therefore excluded from direct compilation here.
        .target(
            name: "G7ECC",
            path: "Sources/G7ECC",
            exclude: [
                "micro-ecc/uECC.c",
                "micro-ecc/curve-specific.inc",
                "micro-ecc/platform-specific.inc",
                "micro-ecc/asm_arm.inc",
                "micro-ecc/asm_arm_mult_square.inc",
                "micro-ecc/asm_arm_mult_square_umaal.inc",
                "micro-ecc/LICENSE.txt",
                "micro-ecc/README.md",
            ],
            publicHeadersPath: "include"
        ),
        .target(name: "G7Kit", dependencies: ["GlucoseCore", "G7ECC"]),
        .testTarget(name: "G7KitTests", dependencies: ["G7Kit", "G7ECC"]),
    ]
)
