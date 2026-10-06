// Original to Sensor (no ported code).

import Foundation
import XCTest

/// S8 / licensing: every ported file names its source file and the xDrip4iOS release it came from,
/// keeps the original copyright header where the original had one, and nothing is left unmarked.
final class G7AttributionTests: XCTestCase {
    private static let xdrip = "xDrip/BluetoothTransmitter/CGM/Dexcom/"

    /// Ported files → the upstream files they came from, and the original header text they keep
    /// (nil where the upstream file had no header). This list is the audit trail for NOTICE.md.
    private static let manifest: [String: (upstream: [String], header: String?)] = [
        "Sources/G7ECC/DexcomG7ECC.c": ([xdrip + "Generic/DexcomG7ECC.c"], nil),
        "Sources/G7ECC/include/DexcomG7ECC.h": ([xdrip + "Generic/DexcomG7ECC.h"], nil),
        "Sources/G7Kit/Auth/G7AuthenticationSlot.swift": ([xdrip + "Generic/AuthRequestTxMessage.swift"], "Copyright © 2015 Nathan Racklyeft"),
        "Sources/G7Kit/Auth/G7AuthSession.swift": ([xdrip + "Generic/DexcomG7AuthSession.swift"], nil),
        "Sources/G7Kit/Auth/G7ChallengeHash.swift": ([xdrip + "Generic/AESCrypt.m", xdrip + "Generic/DexcomG7AuthBridge.m"], "Copyright © 2016 Nathan Racklyeft"),
        "Sources/G7Kit/Auth/G7JPAKEClient.swift": ([xdrip + "Generic/DexcomG7AuthBridge.m"], nil),
        "Sources/G7Kit/Auth/G7OwnershipCredentials.swift": ([xdrip + "Generic/DexcomG7AuthBridge.m", xdrip + "Generic/DexcomG7ProofSigner.swift"], nil),
        "Sources/G7Kit/Calibration/G7CalibrationQueue.swift": ([xdrip + "G7/CGMG7Transmitter.swift"], nil),
        "Sources/G7Kit/Connection/G7Characteristic.swift": ([xdrip + "G7/CGMG7Transmitter.swift"], nil),
        "Sources/G7Kit/Connection/G7ConnectionCycle.swift": ([xdrip + "G7/CGMG7Transmitter.swift"], nil),
        "Sources/G7Kit/Connection/G7ListenCycle.swift": ([xdrip + "G7/CGMG7Transmitter.swift"], nil),
        "Sources/G7Kit/Messages/G7AlgorithmState.swift": ([xdrip + "Generic/DexcomAlgorithmState.swift"], "Copyright © 2021 Johan Degraeve"),
        "Sources/G7Kit/Messages/G7AuthChallengeMessages.swift": ([xdrip + "Generic/AuthRequestRxMessage.swift", xdrip + "Generic/DexcomG7AuthBridge.m"], "Copyright © 2015 Nathan Racklyeft"),
        "Sources/G7Kit/Messages/G7AuthStatusMessage.swift": ([xdrip + "Generic/AuthChallengeRxMessage.swift"], "Copyright © 2015 Nathan Racklyeft"),
        "Sources/G7Kit/Messages/G7BackfillMessage.swift": ([xdrip + "Generic/DexcomG7BackfillMessage.swift"], nil),
        "Sources/G7Kit/Messages/G7CalibrationMessages.swift": ([xdrip + "Generic/DexcomG7CalibrationMessages.swift"], nil),
        "Sources/G7Kit/Messages/G7ControlRequests.swift": ([xdrip + "G7/CGMG7Transmitter.swift"], nil),
        "Sources/G7Kit/Messages/G7CoexistenceMessages.swift": (
            [xdrip + "Generic/DexcomG7GlucoseDataRxMessage.swift", xdrip + "Generic/DexcomTransmitterTimeRxMessage.swift"],
            "Copyright © 2024 Johan Degraeve"
        ),
        "Sources/G7Kit/Messages/G7CRC16.swift": ([xdrip + "Generic/NSData+CRC.swift"], "Copyright © 2016 Nathan Racklyeft"),
        "Sources/G7Kit/Messages/G7ExtendedVersionMessage.swift": ([xdrip + "Generic/DexcomG7ExtendedVersionMessage.swift"], nil),
        "Sources/G7Kit/Messages/G7GlucoseMessage.swift": ([xdrip + "Generic/DexcomG7GlucoseDataRxMessage.swift"], "Copyright © 2024 Johan Degraeve"),
        "Sources/G7Kit/Messages/G7Opcode.swift": ([xdrip + "Generic/DexcomTransmitterOpCode.swift"], "Copyright © 2018 LoopKit Authors"),
        "Sources/G7Kit/Messages/G7OwnershipMessages.swift": (
            [xdrip + "Generic/DexcomG7AuthSession.swift", xdrip + "Generic/DexcomG7AuthBridge.m",
             xdrip + "Generic/KeepAliveTxMessage.swift", xdrip + "Generic/PairRequestTxMessage.swift"],
            "Copyright © 2015 Nathan Racklyeft"
        ),
        "Sources/G7Kit/Session/G7ReadingPipeline.swift": ([xdrip + "G7/CGMG7Transmitter.swift"], nil),
        "Sources/G7Kit/Session/G7SensorLifetime.swift": ([xdrip + "Generic/DexcomG7ExtendedVersionMessage.swift"], nil),
        "Sources/G7Kit/Session/G7SessionClock.swift": ([xdrip + "Generic/DexcomG7CalibrationMessages.swift"], nil),
        "Sources/G7Kit/Source/G7Controller.swift": ([xdrip + "G7/CGMG7Transmitter.swift"], nil),
        "Sources/G7Kit/Source/G7CoreBluetoothCentral.swift": (["xDrip/BluetoothTransmitter/Generic/BluetoothTransmitter.swift"], nil),
        "Sources/G7Kit/Source/G7HeartbeatTarget.swift": ([xdrip + "G7/CGMG7Transmitter.swift"], nil),
    ]

    private static let portLine = try! NSRegularExpression(pattern: #"^// Ported from xDrip4iOS (\S+) @ 7\.1\.0 \(0370937\)$"#, options: .anchorsMatchLines)

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func sourceFiles() throws -> [String] {
        var files: [String] = []
        for folder in ["Sources", "Tests"] {
            let root = packageRoot.appendingPathComponent(folder)
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where ["swift", "c", "h"].contains(url.pathExtension) {
                let relative = String(url.path.dropFirst(packageRoot.path.count + 1))
                if !relative.hasPrefix("Sources/G7ECC/micro-ecc/") { files.append(relative) }
            }
        }
        return files.sorted()
    }

    private func portedUpstreams(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return Self.portLine.matches(in: text, range: range).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }

    func test_S8_everyPortedFileCarriesAttribution() throws {
        let files = try sourceFiles()
        XCTAssertGreaterThan(files.count, 40)
        for file in files {
            let text = try String(contentsOf: packageRoot.appendingPathComponent(file), encoding: .utf8)
            let upstreams = portedUpstreams(in: text)
            let isOriginal = text.contains("// Original to Sensor")
            let markerLines = text.split(separator: "\n").filter { $0.hasPrefix("// Ported from") }
            XCTAssertEqual(markerLines.count, upstreams.count, "\(file): a 'Ported from' line does not match the required format")
            if let expected = Self.manifest[file] {
                XCTAssertEqual(upstreams, expected.upstream, "\(file): wrong or missing 'Ported from' lines")
                XCTAssertFalse(isOriginal, "\(file) is ported, not original")
                if let header = expected.header {
                    XCTAssertTrue(text.contains(header), "\(file): original copyright header '\(header)' missing")
                } else {
                    XCTAssertTrue(text.contains("Originally part of xDrip4iOS"), "\(file): upstream had no header; say where it came from")
                }
            } else {
                XCTAssertTrue(markerLines.isEmpty, "\(file) has a port line but is not in the manifest")
                XCTAssertTrue(isOriginal, "\(file) must say it is original or be listed as ported")
            }
        }
        for file in Self.manifest.keys {
            XCTAssertTrue(files.contains(file), "manifest lists a missing file: \(file)")
        }
    }

    /// Audit m7: code that reached xDrip4iOS from LoopKit CGMBLEKit (MIT) names its CGMBLEKit file in
    /// a lineage line, and CGMBLEKit's MIT notice ships with the package. Any file with a Racklyeft /
    /// LoopKit header must be in this list.
    private static let cgmbleKitLineage: [String: [String]] = [
        "Sources/G7Kit/Messages/G7Opcode.swift": ["CGMBLEKit/Opcode.swift"],
        "Sources/G7Kit/Messages/G7AuthStatusMessage.swift": ["CGMBLEKit/Messages/AuthChallengeRxMessage.swift"],
        "Sources/G7Kit/Messages/G7AuthChallengeMessages.swift": ["CGMBLEKit/Messages/AuthRequestRxMessage.swift"],
        "Sources/G7Kit/Auth/G7ChallengeHash.swift": ["CGMBLEKit/AESCrypt.m"],
        "Sources/G7Kit/Messages/G7CRC16.swift": ["CGMBLEKit/NSData+CRC.swift"],
        "Sources/G7Kit/Messages/G7OwnershipMessages.swift": ["CGMBLEKit/Messages/KeepAliveTxMessage.swift", "CGMBLEKit/Messages/BondRequestTxMessage.swift"],
        "Sources/G7Kit/Auth/G7AuthenticationSlot.swift": ["CGMBLEKit/Messages/AuthRequestTxMessage.swift"],
        "Sources/G7Kit/Messages/G7CoexistenceMessages.swift": ["CGMBLEKit/Messages/GlucoseRxMessage.swift", "CGMBLEKit/Messages/TransmitterTimeRxMessage.swift"],
    ]

    func test_S8_cgmbleKitDerivedFilesShipItsLicense() throws {
        let license = try String(contentsOf: packageRoot.appendingPathComponent("licenses/CGMBLEKit-LICENSE"), encoding: .utf8)
        XCTAssertTrue(license.contains("The MIT License (MIT)"))
        XCTAssertTrue(license.contains("Copyright (c) 2015 Nathan Racklyeft"))
        XCTAssertTrue(license.contains("The above copyright notice and this permission notice shall be included"))
        for file in try sourceFiles() where file.hasPrefix("Sources/") {
            let text = try String(contentsOf: packageRoot.appendingPathComponent(file), encoding: .utf8)
            let lineage = text.split(separator: "\n").filter { $0.hasPrefix("// CGMBLEKit lineage: ") }
                .map { String($0.dropFirst("// CGMBLEKit lineage: ".count).prefix { $0 != " " }) }
            if let expected = Self.cgmbleKitLineage[file] {
                XCTAssertEqual(lineage, expected, "\(file): CGMBLEKit lineage lines")
                XCTAssertTrue(text.contains("Packages/G7Kit/licenses/CGMBLEKit-LICENSE"), file)
                XCTAssertTrue(text.contains("loopandlearn/CGMBLEKit @ 98fae79"), file)
                XCTAssertNotNil(Self.manifest[file], "\(file) must also name its xDrip4iOS source")
            } else {
                XCTAssertTrue(lineage.isEmpty, "\(file) has a lineage line but is not listed")
                XCTAssertFalse(text.contains("Racklyeft") || text.contains("LoopKit Authors"),
                               "\(file) carries a CGMBLEKit-era header but no lineage line")
            }
        }
    }

    /// micro-ecc (BSD-2-Clause) keeps its license and pinned revision next to the vendored code.
    func test_S8_vendoredMicroECCKeepsItsLicense() throws {
        let folder = packageRoot.appendingPathComponent("Sources/G7ECC/micro-ecc")
        let license = try String(contentsOf: folder.appendingPathComponent("LICENSE.txt"), encoding: .utf8)
        XCTAssertTrue(license.contains("Copyright (c) 2014, Kenneth MacKay"))
        let readme = try String(contentsOf: folder.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("541b3a78026420a3e369c4c9281c396b5e531113"))
        let wrapper = try String(contentsOf: packageRoot.appendingPathComponent("Sources/G7ECC/DexcomG7ECC.c"), encoding: .utf8)
        XCTAssertTrue(wrapper.contains("#include \"micro-ecc/uECC.c\""))
    }
}
