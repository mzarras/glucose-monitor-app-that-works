import GlucoseCore
import GRDB
import XCTest
@testable import GlucoseStore

/// The two repository roles (GlucoseReadingRepository doc, PROGRESS.md D20): production stores
/// only `.sensor`/`.imported`; the DEBUG replay store only `.replay`/`.mock`. Never mixed.
final class StoreRoleTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func count(_ store: GlucoseStore) async throws -> Int {
        try await store.summary().readingCount
    }

    /// Writes a row directly, bypassing the role check: simulates a DEBUG build from before roles
    /// existed having written replay rows into the production file.
    private func writeRawRow(_ reading: GlucoseReading, into store: GlucoseStore) async throws {
        let row = ReadingRow(reading)
        try await store.writer.write { db in
            try db.execute(sql: "INSERT INTO reading (\(ReadingRow.selectColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                           arguments: row.insertArguments)
        }
    }

    // MARK: Production

    func test_S6_productionStoreRefusesReplayAndMock() async throws {
        for source: ReadingSource in [.replay, .mock] {
            var store: GlucoseStore? = try GlucoseStore.productionInMemory()
            let changes = store!.changes()
            // A valid sensor reading in the same call: the whole call fails, nothing is written.
            let batch = [sensorReading(at: 0), replayReading(at: 300, source: source)]

            do {
                _ = try await store!.insert(batch)
                XCTFail("production store accepted \(source)")
            } catch let error as GlucoseReadingRepositoryError {
                XCTAssertEqual(error, .sourceNotAllowed(source))
            }

            let stored = try await count(store!)
            XCTAssertEqual(stored, 0, "nothing written for \(source)")
            store = nil
            var yields = 0
            for await _ in changes { yields += 1 }
            XCTAssertEqual(yields, 0)
        }
    }

    func test_S6_mixedBatchIsRejectedWhole() async throws {
        // Production: allowed readings first and last, one mock in the middle.
        let production = try GlucoseStore.productionInMemory()
        let mixed = [sensorReading(at: 0), replayReading(at: 300, source: .mock), importedReading(at: 3_600)]
        do {
            _ = try await production.insert(mixed)
            XCTFail("mixed batch accepted by the production store")
        } catch let error as GlucoseReadingRepositoryError {
            XCTAssertEqual(error, .sourceNotAllowed(.mock))
        }
        let productionRows = try await count(production)
        XCTAssertEqual(productionRows, 0, "nothing from the batch is stored")

        #if DEBUG
        // Replay store: the mirror image.
        let replay = try GlucoseStore.replay()
        let mixedReplay = [replayReading(at: 0), sensorReading(at: 300), replayReading(at: 600, source: .mock)]
        do {
            _ = try await replay.insert(mixedReplay)
            XCTFail("mixed batch accepted by the replay store")
        } catch let error as GlucoseReadingRepositoryError {
            XCTAssertEqual(error, .sourceNotAllowed(.sensor))
        }
        let replayRows = try await count(replay)
        XCTAssertEqual(replayRows, 0, "nothing from the batch is stored")
        #endif
    }

    func test_S6_productionStorePurgesReplayRowsOnOpen() async throws {
        let url = directory.appendingPathComponent("readings.sqlite")
        let sensor = sensorReading(at: 0)
        let imported = importedReading(at: -3_600)
        do {
            let store = try await GlucoseStore.production(at: url)
            _ = try await store.insert([sensor, imported])
            try await writeRawRow(replayReading(at: 600), into: store)
            try await writeRawRow(replayReading(at: 900, source: .mock), into: store)
            let rows = try await count(store)
            XCTAssertEqual(rows, 4)
        }

        let log = RecordingDiagnosticLog()
        let reopened = try await GlucoseStore.production(at: url, diagnostics: log, now: { referenceInstant })

        let remaining = try await reopened.readings(from: referenceInstant.addingTimeInterval(-86_400), to: referenceInstant.addingTimeInterval(86_400))
        XCTAssertEqual(remaining, [imported, sensor])
        XCTAssertEqual(log.recorded, [DiagnosticEvent(
            date: referenceInstant, category: .store,
            message: "Removed 2 replay/mock reading(s) from the production database on open (S6)"
        )])
    }

    func test_productionOpenWithNothingToPurgeRecordsNothing() async throws {
        let log = RecordingDiagnosticLog()
        _ = try GlucoseStore.productionInMemory(diagnostics: log)
        XCTAssertEqual(log.recorded, [])
    }

    func test_S6_latestLiveReadingIsSensorOnlyInProduction() async throws {
        let store = try GlucoseStore.productionInMemory()
        let sensor = sensorReading(at: 0)
        _ = try await store.insert([sensor, importedReading(at: 3_600)])
        // Even a (forbidden) replay row newer than everything is not returned.
        try await writeRawRow(replayReading(at: 7_200), into: store)

        let latest = try await store.latestLiveReading()
        XCTAssertEqual(latest, sensor)
        XCTAssertEqual(latest?.source, .sensor)
    }

    // MARK: Replay (DEBUG only: the replay role and its factories do not exist in Release)

    #if DEBUG
    func test_S1_replayStoreRefusesSensorAndImported() async throws {
        let store = try GlucoseStore.replay()
        for reading in [sensorReading(at: 0), importedReading(at: 600, origin: .nightscout), importedReading(at: 1_200, origin: .clarityCSV)] {
            do {
                _ = try await store.insert([replayReading(at: 3_000), reading])
                XCTFail("replay store accepted \(reading.source)")
            } catch let error as GlucoseReadingRepositoryError {
                XCTAssertEqual(error, .sourceNotAllowed(reading.source))
            }
        }
        let stored = try await count(store)
        XCTAssertEqual(stored, 0)
    }

    func test_replayStoreRefusesAFileHoldingLiveData() async throws {
        let url = directory.appendingPathComponent("readings.sqlite")
        do {
            let production = try await GlucoseStore.production(at: url)
            _ = try await production.insert([sensorReading(at: 0), importedReading(at: 600)])
        }
        do {
            _ = try await GlucoseStore.replay(at: url)
            XCTFail("replay store opened the production file")
        } catch let error as GlucoseStoreError {
            XCTAssertEqual(error, .replayStoreFileContainsLiveData(rowCount: 2))
        }
        let reopened = try await GlucoseStore.production(at: url)
        let rows = try await count(reopened)
        XCTAssertEqual(rows, 2, "the production rows are untouched")
    }

    func test_replayStoreInItsOwnFileKeepsReplayRows() async throws {
        let url = directory.appendingPathComponent("replay.sqlite")
        do {
            let store = try await GlucoseStore.replay(at: url)
            _ = try await store.insert([replayReading(at: 0)])
        }
        let reopened = try await GlucoseStore.replay(at: url)
        let latest = try await reopened.latestLiveReading()
        XCTAssertEqual(latest, replayReading(at: 0))
    }

    func test_replayStoreLatestLiveReadingIsTheNewestReplayOrMockRow() async throws {
        let store = try GlucoseStore.replay()
        _ = try await store.insert([replayReading(at: 0)])
        var latest = try await store.latestLiveReading()
        XCTAssertEqual(latest, replayReading(at: 0))
        _ = try await store.insert([replayReading(at: 300, source: .mock)])
        latest = try await store.latestLiveReading()
        XCTAssertEqual(latest?.source, .mock)
        XCTAssertEqual(latest?.source.isLiveSensor, false, "LiveReadingGate.validate still refuses it downstream")
    }

    func test_replayReadingsDedupeByIDButSkipTheImportOverlapRule() async throws {
        let store = try GlucoseStore.replay()
        let first = replayReading(at: 0)
        let near = replayReading(at: 30, source: .mock)
        let newlyStored = try await store.insert([near, first, first])
        XCTAssertEqual(newlyStored, [first, near])
        let again = try await store.insert([first])
        XCTAssertEqual(again, [])
    }
    #endif
}
