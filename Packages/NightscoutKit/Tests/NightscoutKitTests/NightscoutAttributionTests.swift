// Original to Sensor (no ported code).

import Foundation
import XCTest

/// S8 / licensing (audit m11): every file ported from xDrip4iOS names its source file and the
/// release it came from, keeps the original copyright header where the original had one, and says
/// where it came from where it had none; every other file says it is original. Same rules as
/// G7Kit's G7AttributionTests.
final class NightscoutAttributionTests: XCTestCase {
    private static let share = "xDrip/Managers/DexcomShare/"

    /// Ported files → the upstream files they came from (in the order the port lines list them),
    /// and the original header text they keep (nil where the upstream file had no header). Checked
    /// against vendor-ref/xdripswift @ 7.1.0: only DexcomShareModels.swift has a copyright header.
    private static let manifest: [String: (upstream: [String], header: String?)] = [
        "Sources/NightscoutKit/DexcomShare/DexcomShareServer.swift": (
            ["xDrip/Constants/ConstantsDexcomShare.swift", share + "DexcomShareModels.swift"],
            "Copyright © 2025 Johan Degraeve"
        ),
        "Sources/NightscoutKit/DexcomShare/DexcomShareEGV.swift": (
            [share + "BgReading+DexcomShare.swift", "xDrip/Core Data/classes/BgReading+CoreDataClass.swift"],
            nil
        ),
        "Sources/NightscoutKit/DexcomShare/DexcomShareClient.swift": ([share + "DexcomShareUploadManager.swift"], nil),
        "Sources/NightscoutKit/DexcomShare/DexcomShareUploadDestination.swift": ([share + "DexcomShareUploadManager.swift"], nil),
    ]

    /// `// Ported from xDrip4iOS <path> @ 7.1.0 (0370937)` — the path may contain spaces
    /// ("Core Data").
    private static let portLine = try! NSRegularExpression(
        pattern: #"^// Ported from xDrip4iOS (\S.*\S) @ 7\.1\.0 \(0370937\)$"#, options: .anchorsMatchLines
    )

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func sourceFiles() throws -> [String] {
        var files: [String] = []
        for folder in ["Sources", "Tests"] {
            let root = packageRoot.appendingPathComponent(folder)
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                files.append(String(url.standardizedFileURL.path.dropFirst(packageRoot.standardizedFileURL.path.count + 1)))
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
        XCTAssertGreaterThan(files.count, 30)
        for file in files {
            let text = try String(contentsOf: packageRoot.appendingPathComponent(file), encoding: .utf8)
            let upstreams = portedUpstreams(in: text)
            let isOriginal = text.hasPrefix("// Original to Sensor")
            let markerLines = text.split(separator: "\n").filter { $0.hasPrefix("// Ported from") }
            XCTAssertEqual(markerLines.count, upstreams.count, "\(file): a 'Ported from' line does not match the required format")
            if let expected = Self.manifest[file] {
                XCTAssertEqual(upstreams, expected.upstream, "\(file): wrong or missing 'Ported from' lines")
                XCTAssertFalse(isOriginal, "\(file) is ported, not original")
                XCTAssertTrue(text.contains("GPL-3.0"), "\(file): must name the upstream license")
                if let header = expected.header {
                    XCTAssertTrue(text.contains(header), "\(file): original copyright header '\(header)' missing")
                } else {
                    XCTAssertTrue(text.hasPrefix("// Originally part of xDrip4iOS"), "\(file): upstream had no header; say where it came from")
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

    /// The Share port is marked unofficial where a reader of the code would look first (S8, §8A).
    func test_S8_dexcomSharePortIsMarkedUnofficial() throws {
        for file in Self.manifest.keys {
            let text = try String(contentsOf: packageRoot.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("UNOFFICIAL AND SUBJECT TO BREAKING"), "\(file)")
        }
    }
}
