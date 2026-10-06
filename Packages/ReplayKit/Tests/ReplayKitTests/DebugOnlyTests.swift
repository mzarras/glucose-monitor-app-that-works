#if DEBUG
import Foundation
import XCTest

/// S6: replay code must not exist in Release. scripts/check.sh proves it on the compiled objects
/// with nm; this test proves the source-level rule it depends on: every ReplayKit source file is
/// wrapped entirely in `#if DEBUG … #endif`.
final class DebugOnlyTests: XCTestCase {
    private var sourcesDirectory: URL {
        // <package>/Tests/ReplayKitTests/DebugOnlyTests.swift → <package>/Sources/ReplayKit
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ReplayKit")
    }

    func test_S6_everyReplayKitSourceFileIsWrappedInIfDebug() throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sourcesDirectory, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 12, "found \(files.count) source files; the scan must not pass vacuously")

        for file in files {
            let name = file.lastPathComponent
            let lines = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let code = lines.filter { !$0.isEmpty && !$0.hasPrefix("//") }
            XCTAssertEqual(code.first, "#if DEBUG", "\(name): the first line of code must be #if DEBUG")
            XCTAssertEqual(code.last, "#endif", "\(name): the last line must be the matching #endif")
            let opened = code.filter { $0.hasPrefix("#if") }.count
            let closed = code.filter { $0.hasPrefix("#endif") }.count
            XCTAssertEqual(opened, closed, "\(name): unbalanced #if/#endif")
            XCTAssertFalse(code.contains { $0.hasPrefix("#else") || $0.hasPrefix("#elseif") }, "\(name): no #else branch that would compile in Release")
        }
    }
}
#endif
