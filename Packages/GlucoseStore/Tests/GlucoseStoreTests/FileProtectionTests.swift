import GlucoseCore
import os
import XCTest
@testable import GlucoseStore

/// HANDOFF §4.5: the database and its -wal/-shm files get `completeUntilFirstUserAuthentication`
/// (background BLE writes happen while locked), and are not excluded from backup.
/// These host tests prove what is requested; the real behaviour must be verified on a device
/// (HANDOFF §11 step 3a: readings keep saving while the phone stays locked for hours).
final class FileProtectionTests: XCTestCase {
    private final class Recorder: FileProtectionApplying {
        struct Call: Equatable {
            let protection: FileProtectionType
            let fileName: String
        }
        private let calls = OSAllocatedUnfairLock<[Call]>(initialState: [])
        var recorded: [Call] { calls.withLock { $0 } }

        func apply(_ protection: FileProtectionType, toItemAt url: URL) throws {
            calls.withLock { $0.append(Call(protection: protection, fileName: url.lastPathComponent)) }
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func test_requiredProtectionIsCompleteUntilFirstUserAuthentication() {
        XCTAssertEqual(StoreFileProtection.required, .completeUntilFirstUserAuthentication)
        XCTAssertNotEqual(StoreFileProtection.required, .complete, "complete would make locked background writes fail")
    }

    func test_openRequestsProtectionForTheDatabaseAndItsWALFiles() async throws {
        let recorder = Recorder()
        let log = RecordingDiagnosticLog()
        let url = directory.appendingPathComponent("Store/readings.sqlite")

        _ = try await GlucoseStore.production(at: url, diagnostics: log, fileProtection: recorder)

        XCTAssertEqual(recorder.recorded, [
            .init(protection: .completeUntilFirstUserAuthentication, fileName: "readings.sqlite"),
            .init(protection: .completeUntilFirstUserAuthentication, fileName: "readings.sqlite-wal"),
            .init(protection: .completeUntilFirstUserAuthentication, fileName: "readings.sqlite-shm"),
        ])
        XCTAssertEqual(log.recorded, [], "all three files existed when protection was applied")
    }

    func test_reopeningAppliesProtectionAgain() async throws {
        let recorder = Recorder()
        let url = directory.appendingPathComponent("readings.sqlite")
        do { _ = try await GlucoseStore.production(at: url, fileProtection: recorder) }
        _ = try await GlucoseStore.production(at: url, fileProtection: recorder)
        XCTAssertEqual(recorder.recorded.count, 6)
    }

    func test_databaseIsNotExcludedFromBackup() async throws {
        let url = directory.appendingPathComponent("readings.sqlite")
        let store = try await GlucoseStore.production(at: url)
        _ = try await store.insert([sensorReading(at: 0)])
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, false)
    }

    func test_summaryReportsBytesOnDisk() async throws {
        let url = directory.appendingPathComponent("readings.sqlite")
        let store = try await GlucoseStore.production(at: url)
        _ = try await store.insert((0..<100).map { sensorReading(at: TimeInterval($0) * 300) })
        let summary = try await store.summary()
        XCTAssertEqual(summary.readingCount, 100)
        let size = try XCTUnwrap(summary.fileSizeBytes)
        XCTAssertGreaterThan(size, 0)
    }
}
