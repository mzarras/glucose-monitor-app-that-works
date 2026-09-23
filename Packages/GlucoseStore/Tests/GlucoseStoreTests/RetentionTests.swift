import GlucoseCore
import XCTest
@testable import GlucoseStore

final class RetentionTests: XCTestCase {
    private let day: TimeInterval = 86_400

    func test_defaultIsTwoYears() {
        XCTAssertEqual(RetentionPolicy.default, .twoYears)
    }

    func test_maximumAges() {
        XCTAssertEqual(RetentionPolicy.days90.maximumAge, 90 * day)
        XCTAssertEqual(RetentionPolicy.oneYear.maximumAge, 365 * day)
        XCTAssertEqual(RetentionPolicy.twoYears.maximumAge, 730 * day)
        XCTAssertNil(RetentionPolicy.forever.maximumAge)
        XCTAssertNil(RetentionPolicy.forever.cutoff(now: referenceInstant))
    }

    func test_purgeDeletesOnlyReadingsOlderThanTheCutoff() async throws {
        let log = RecordingDiagnosticLog()
        // now = reference + 800 days, so the two-year cutoff is reference + 70 days.
        let now = referenceInstant.addingTimeInterval(800 * day)
        let store = try GlucoseStore.productionInMemory(diagnostics: log, now: { now })
        let tooOld = importedReading(at: 69 * day)
        let exactlyAtCutoff = importedReading(at: 70 * day)
        let recent = sensorReading(at: 71 * day)
        _ = try await store.insert([tooOld, exactlyAtCutoff, recent])

        let deleted = try await store.purge(keeping: .twoYears)

        XCTAssertEqual(deleted, 1)
        let remaining = try await store.readings(from: referenceInstant, to: now)
        XCTAssertEqual(remaining, [exactlyAtCutoff, recent], "a reading exactly at the cutoff is kept")
        XCTAssertEqual(log.recorded.map(\.message), ["Retention (twoYears) removed 1 reading(s) older than 2026-03-26T12:00:00.000Z"])
    }

    func test_purgeAppliesToSensorAndImportedAlike() async throws {
        let now = referenceInstant.addingTimeInterval(100 * day)
        let store = try GlucoseStore.productionInMemory(now: { now })
        let old: [GlucoseReading] = [
            sensorReading(at: 0),
            importedReading(at: 300, origin: .nightscout),
            importedReading(at: 600, origin: .clarityCSV),
        ]
        _ = try await store.insert(old)
        let deleted = try await store.purge(keeping: .days90)
        XCTAssertEqual(deleted, 3)
        let count = try await store.summary().readingCount
        XCTAssertEqual(count, 0)
    }

    #if DEBUG
    func test_purgeWorksInTheReplayStore() async throws {
        let now = referenceInstant.addingTimeInterval(100 * day)
        let store = try GlucoseStore.replay(now: { now })
        _ = try await store.insert([replayReading(at: 0), replayReading(at: 99 * day)])
        let deleted = try await store.purge(keeping: .days90)
        XCTAssertEqual(deleted, 1)
    }
    #endif

    func test_foreverPurgesNothing() async throws {
        let store = try GlucoseStore.productionInMemory(now: { referenceInstant.addingTimeInterval(10_000 * 86_400) })
        _ = try await store.insert([sensorReading(at: 0)])
        let deleted = try await store.purge(keeping: .forever)
        XCTAssertEqual(deleted, 0)
        let count = try await store.summary().readingCount
        XCTAssertEqual(count, 1)
    }

    func test_summaryReportsCountAndDateRange() async throws {
        let store = try GlucoseStore.productionInMemory(now: testClock)
        let empty = try await store.summary()
        XCTAssertEqual(empty, StoreSummary(readingCount: 0, earliest: nil, latest: nil, fileSizeBytes: nil))

        _ = try await store.insert([sensorReading(at: 600), importedReading(at: -3_600), sensorReading(at: 300)])
        let summary = try await store.summary()
        XCTAssertEqual(summary.readingCount, 3)
        XCTAssertEqual(summary.earliest, referenceInstant.addingTimeInterval(-3_600))
        XCTAssertEqual(summary.latest, referenceInstant.addingTimeInterval(600))
        XCTAssertNil(summary.fileSizeBytes, "in-memory store has no file")
    }
}
