import GlucoseCore
import XCTest
@testable import GlucoseStore

/// S3 + HANDOFF §4.5 step 3 as defined in GlucoseReadingRepository.swift: |Δt| ≤ 150 s inclusive;
/// an imported reading is skipped when any stored reading of any source lies within ±150 s; a new
/// sensor reading deletes imported readings within ±150 s; a batch is applied in date order.
final class ImportOverlapTests: XCTestCase {
    private func allStored(_ store: GlucoseStore) async throws -> [GlucoseReading] {
        try await store.readings(from: referenceInstant.addingTimeInterval(-86_400), to: referenceInstant.addingTimeInterval(86_400))
    }

    func test_S3_importedReadingSkippedWhenSensorReadingWithin150sInclusive() async throws {
        let store = try GlucoseStore.productionInMemory()
        let sensor = sensorReading(at: 0)
        _ = try await store.insert([sensor])

        for offset in [-150, -149, -1, 0, 1, 149, 150] as [TimeInterval] {
            let newlyStored = try await store.insert([importedReading(at: offset)])
            XCTAssertEqual(newlyStored, [], "imported reading \(offset) s from a sensor reading is skipped")
        }
        let stored = try await allStored(store)
        XCTAssertEqual(stored, [sensor])
    }

    func test_S3_importedReadingStoredAt151sFromSensorReading() async throws {
        let store = try GlucoseStore.productionInMemory()
        _ = try await store.insert([sensorReading(at: 0)])

        let justOutside = [importedReading(at: -151), importedReading(at: 151)]
        let newlyStored = try await store.insert(justOutside)
        XCTAssertEqual(newlyStored, justOutside)
    }

    func test_S3_sensorReadingDeletesImportedReadingsWithin150sInclusive() async throws {
        let log = RecordingDiagnosticLog()
        let store = try GlucoseStore.productionInMemory(diagnostics: log, now: { referenceInstant })
        let removed = [importedReading(at: -150), importedReading(at: 150)]
        let kept = [importedReading(at: -600), importedReading(at: 600)]
        _ = try await store.insert(removed + kept)

        let sensor = sensorReading(at: 0)
        let newlyStored = try await store.insert([sensor])

        XCTAssertEqual(newlyStored, [sensor])
        let stored = try await allStored(store)
        XCTAssertEqual(stored, [kept[0], sensor, kept[1]])
        XCTAssertEqual(log.recorded.map(\.message), ["Removed 2 imported reading(s) within ±150 s of new sensor readings"])
    }

    func test_S3_sensorReadingKeepsImportedReadingsAt151s() async throws {
        let store = try GlucoseStore.productionInMemory()
        let before = importedReading(at: -151)
        let after = importedReading(at: 151)
        _ = try await store.insert([before, after])

        _ = try await store.insert([sensorReading(at: 0)])

        let stored = try await allStored(store)
        XCTAssertEqual(stored, [before, sensorReading(at: 0), after])
    }

    func test_S3_withinOneBatchImportedAfterSensorIsSkipped() async throws {
        let sensor = sensorReading(at: 0)
        let imported = importedReading(at: 60)
        for batch in [[imported, sensor], [sensor, imported]] {
            let fresh = try GlucoseStore.productionInMemory()
            let newlyStored = try await fresh.insert(batch)
            XCTAssertEqual(newlyStored, [sensor])
            let stored = try await allStored(fresh)
            XCTAssertEqual(stored, [sensor])
        }
    }

    func test_S3_withinOneBatchImportedBeforeSensorIsReplacedAndNotReported() async throws {
        // Date order: the imported reading (t = 0) is stored first, then the sensor reading
        // (t = 60) deletes it. It must not appear in the returned "newly stored" list.
        let imported = importedReading(at: 0)
        let sensor = sensorReading(at: 60)
        for batch in [[imported, sensor], [sensor, imported]] {
            let fresh = try GlucoseStore.productionInMemory()
            let newlyStored = try await fresh.insert(batch)
            XCTAssertEqual(newlyStored, [sensor])
            let stored = try await allStored(fresh)
            XCTAssertEqual(stored, [sensor])
        }
    }

    func test_S3_crossOriginImportOfTheSamePeriodIsSkipped() async throws {
        let store = try GlucoseStore.productionInMemory()
        // Nightscout history every 5 min for an hour, with a 30-minute hole at 20–45 min.
        let nightscout = [0, 5, 10, 15, 50, 55].map { importedReading(at: TimeInterval($0 * 60), origin: .nightscout) }
        _ = try await store.insert(nightscout)

        // Clarity export of the same period: same readings, timestamps 20 s apart from Nightscout's,
        // plus the readings Nightscout is missing.
        let clarityOverlapping = [0, 5, 10, 15, 50, 55].map { importedReading(at: TimeInterval($0 * 60 + 20), origin: .clarityCSV) }
        let clarityFillingTheHole = [20, 25, 30, 35, 40, 45].map { importedReading(at: TimeInterval($0 * 60 + 20), origin: .clarityCSV) }
        let newlyStored = try await store.insert(clarityOverlapping + clarityFillingTheHole)

        XCTAssertEqual(newlyStored, clarityFillingTheHole)
        let stored = try await allStored(store)
        XCTAssertEqual(stored.count, 12)
    }

    func test_S3_nearDuplicateImportsInOneBatchKeepTheEarliest() async throws {
        // Two uploaders posted the same reading to Nightscout 4 s apart.
        let store = try GlucoseStore.productionInMemory()
        let first = importedReading(at: 0, .mgdl(120))
        let duplicate = importedReading(at: 4, .mgdl(120))
        let newlyStored = try await store.insert([duplicate, first])
        XCTAssertEqual(newlyStored, [first])
    }

    func test_S3_redeliveredSensorReadingDoesNotReportRemovals() async throws {
        let log = RecordingDiagnosticLog()
        let store = try GlucoseStore.productionInMemory(diagnostics: log)
        _ = try await store.insert([sensorReading(at: 0)])
        _ = try await store.insert([sensorReading(at: 0)])
        XCTAssertEqual(log.recorded, [])
    }

    func test_S3_reimportIsIdempotent() async throws {
        let store = try GlucoseStore.productionInMemory()
        let history = (0..<10).map { importedReading(at: TimeInterval($0) * 300) }
        let first = try await store.insert(history)
        let second = try await store.insert(history)
        XCTAssertEqual(first, history)
        XCTAssertEqual(second, [])
    }
}
