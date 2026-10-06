import GlucoseCore
import XCTest
@testable import GlucoseStore

/// PROGRESS.md D33: a batch with a non-finite trend rate or a future-dated reading is rejected
/// whole, and `insert` returns readings exactly as passed (nothing rewritten).
final class StoreValidationTests: XCTestCase {
    func test_S2_nonFiniteTrendRateRejectsWholeBatch() async throws {
        for rate in [Double.nan, .infinity, -.infinity] {
            let store = try GlucoseStore.productionInMemory(now: testClock)
            let batch = [sensorReading(at: 0), sensorReading(at: 300, trendRate: rate), sensorReading(at: 600)]
            do {
                _ = try await store.insert(batch)
                XCTFail("accepted trend rate \(rate)")
            } catch let error as GlucoseReadingRepositoryError {
                XCTAssertEqual(error, .nonFiniteTrendRate)
            }
            let count = try await store.summary().readingCount
            XCTAssertEqual(count, 0, "nothing stored for trend rate \(rate)")
        }
    }

    func test_S2_insertReturnsReadingsExactlyAsPassed() async throws {
        let store = try GlucoseStore.productionInMemory(now: testClock)
        let passed: [GlucoseReading] = [
            sensorReading(at: 900, .aboveRange, trendRate: nil, isBackfill: true),
            GlucoseReading(
                id: "3M1234:34", date: Date(timeIntervalSinceReferenceDate: 790_171_234.123_456_7), value: .mgdl(101),
                trendRate: -1.234_567_890_123, isBackfill: false, source: .sensor, sensorSerial: testSerial
            ),
            importedReading(at: -3_600.000_4, .belowRange, origin: .clarityCSV),
            sensorReading(at: 600, .mgdl(400), trendRate: 2.9999999999),
        ]

        let returned = try await store.insert(passed)

        let expected = passed.sorted { $0.date < $1.date }
        XCTAssertEqual(returned, expected)
        for (got, want) in zip(returned, expected) {
            XCTAssertEqual(got.date.timeIntervalSinceReferenceDate.bitPattern, want.date.timeIntervalSinceReferenceDate.bitPattern)
            XCTAssertEqual(got.trendRate?.bitPattern, want.trendRate?.bitPattern)
        }
    }

    func test_S2_equalDatesAreReturnedInTheOrderPassed() async throws {
        let store = try GlucoseStore.productionInMemory(now: testClock)
        let date = referenceInstant
        let second = GlucoseReading(id: "B:10", date: date, value: .mgdl(120), trendRate: nil, isBackfill: false, source: .sensor, sensorSerial: "B")
        let first = GlucoseReading(id: "A:9", date: date, value: .mgdl(110), trendRate: nil, isBackfill: false, source: .sensor, sensorSerial: "A")
        let returned = try await store.insert([second, first])
        XCTAssertEqual(returned, [second, first], "ties keep the order passed, not id order")
    }

    func test_S5_futureDatedReadingRejectsWholeBatch() async throws {
        let now = referenceInstant
        let atLimit = sensorReading(at: LiveReadingGate.futureTolerance)          // now + 60 s: accepted
        let beyond = sensorReading(at: LiveReadingGate.futureTolerance + 1)       // now + 61 s: rejected
        XCTAssertEqual(LiveReadingGate.futureTolerance, 60)

        let accepting = try GlucoseStore.productionInMemory(now: { now })
        let stored = try await accepting.insert([sensorReading(at: 0), atLimit])
        XCTAssertEqual(stored, [sensorReading(at: 0), atLimit], "exactly +60 s is accepted")

        for batch in [[beyond], [sensorReading(at: 0), beyond], [importedReading(at: -600), beyond]] {
            let store = try GlucoseStore.productionInMemory(now: { now })
            do {
                _ = try await store.insert(batch)
                XCTFail("accepted a reading 61 s in the future")
            } catch let error as GlucoseReadingRepositoryError {
                XCTAssertEqual(error, .futureDated(beyond.date))
            }
            let count = try await store.summary().readingCount
            XCTAssertEqual(count, 0, "nothing from the batch is stored")
        }
    }

    func test_futureCheckUsesTheStoreClockAtInsertTime() async throws {
        // A reading that was in the future when the store opened is fine once the clock catches up.
        let clock = TestClock(referenceInstant)
        let store = try GlucoseStore.productionInMemory(now: { clock.now })
        let reading = sensorReading(at: 3_600)
        do {
            _ = try await store.insert([reading])
            XCTFail("expected futureDated")
        } catch let error as GlucoseReadingRepositoryError {
            XCTAssertEqual(error, .futureDated(reading.date))
        }
        clock.now = referenceInstant.addingTimeInterval(3_600)
        let stored = try await store.insert([reading])
        XCTAssertEqual(stored, [reading])
    }
}
