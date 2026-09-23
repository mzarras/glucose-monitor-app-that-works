import GlucoseCore
import XCTest
@testable import GlucoseStore

/// S3: dedupe by sensor-reported timestamp (the id), keep the first stored copy, ascending order.
final class DedupeTests: XCTestCase {
    func test_S3_insertingTheSameReadingsTwiceChangesNothing() async throws {
        let store = try GlucoseStore.productionInMemory()
        let batch = [sensorReading(at: 0), sensorReading(at: 300), sensorReading(at: 600, .belowRange)]

        let first = try await store.insert(batch)
        XCTAssertEqual(first, batch)

        let second = try await store.insert(batch)
        XCTAssertEqual(second, [], "a re-delivered reading is never reported as new")

        let stored = try await store.readings(from: referenceInstant, to: referenceInstant.addingTimeInterval(3_600))
        XCTAssertEqual(stored, batch)
        let summary = try await store.summary()
        XCTAssertEqual(summary.readingCount, 3)
    }

    func test_S3_sameIDWithDifferentContentKeepsTheStoredRowAndRecordsDiagnostic() async throws {
        let log = RecordingDiagnosticLog()
        let store = try GlucoseStore.productionInMemory(diagnostics: log, now: { referenceInstant })
        let live = sensorReading(at: 300, .mgdl(110), trendRate: 0.2, isBackfill: false)
        // Same sensor timestamp (same id), arriving again through backfill with other content.
        let backfilled = GlucoseReading(
            id: live.id, date: live.date.addingTimeInterval(1), value: .mgdl(111), trendRate: nil,
            isBackfill: true, source: .sensor, sensorSerial: testSerial
        )

        _ = try await store.insert([live])
        let newlyStored = try await store.insert([backfilled])

        XCTAssertEqual(newlyStored, [])
        let latest = try await store.latestLiveReading()
        XCTAssertEqual(latest, live, "the original row is kept")
        XCTAssertEqual(log.recorded.count, 1)
        XCTAssertEqual(log.recorded.first?.category, .store)
        XCTAssertEqual(log.recorded.first?.date, referenceInstant)
        XCTAssertEqual(
            log.recorded.first?.message,
            "Kept stored reading \(live.id); a re-delivered copy differed in: date, value, trendRate, isBackfill"
        )
    }

    func test_S3_identicalRedeliveryRecordsNoDiagnostic() async throws {
        let log = RecordingDiagnosticLog()
        let store = try GlucoseStore.productionInMemory(diagnostics: log)
        _ = try await store.insert([sensorReading(at: 300)])
        _ = try await store.insert([sensorReading(at: 300)])
        XCTAssertEqual(log.recorded, [])
    }

    func test_S3_duplicateIDWithinOneBatchIsStoredOnce() async throws {
        let store = try GlucoseStore.productionInMemory()
        let reading = sensorReading(at: 300)
        let newlyStored = try await store.insert([reading, reading])
        XCTAssertEqual(newlyStored, [reading])
        let count = try await store.summary().readingCount
        XCTAssertEqual(count, 1)
    }

    func test_S3_insertReturnsOnlyNewReadingsAscendingByDate() async throws {
        let store = try GlucoseStore.productionInMemory()
        let r0 = sensorReading(at: 0), r1 = sensorReading(at: 300), r2 = sensorReading(at: 600)
        let r3 = sensorReading(at: 900), r4 = sensorReading(at: 1_200)

        let first = try await store.insert([r3, r1, r2])
        XCTAssertEqual(first, [r1, r2, r3])

        // Backfill arriving after newer live readings, mixed with a re-delivery.
        let second = try await store.insert([r2, r4, r0])
        XCTAssertEqual(second, [r0, r4])
    }

    func test_S3_rangeQueryIsAscendingWhateverTheInsertOrder() async throws {
        let store = try GlucoseStore.productionInMemory()
        let readings = (0..<12).map { sensorReading(at: TimeInterval($0) * 300) }
        for reading in readings.reversed() {
            _ = try await store.insert([reading])
        }
        let stored = try await store.readings(from: referenceInstant, to: referenceInstant.addingTimeInterval(3_600))
        XCTAssertEqual(stored, readings)
    }

    func test_S3_backfillFlagAndOriginalTimestampAreKept() async throws {
        let store = try GlucoseStore.productionInMemory()
        let backfilled = sensorReading(at: 1_500, .mgdl(95), trendRate: -0.4, isBackfill: true)
        _ = try await store.insert([sensorReading(at: 3_000)])
        let newlyStored = try await store.insert([backfilled])
        XCTAssertEqual(newlyStored, [backfilled])
        let stored = try await store.readings(from: referenceInstant, to: referenceInstant.addingTimeInterval(3_600))
        XCTAssertEqual(stored.first, backfilled)
        XCTAssertEqual(stored.first?.date, referenceInstant.addingTimeInterval(1_500))
        XCTAssertEqual(stored.first?.isBackfill, true)
    }

    func test_S3_datesRoundTripBitExact() async throws {
        let store = try GlucoseStore.productionInMemory()
        // A derived date with sub-millisecond detail, as G7 dates are (phone clock − session age).
        let date = Date(timeIntervalSinceReferenceDate: 790_171_234.123_456_7)
        let reading = GlucoseReading(
            id: "3M1234:34", date: date, value: .mgdl(100), trendRate: -1.25,
            isBackfill: false, source: .sensor, sensorSerial: testSerial
        )
        _ = try await store.insert([reading])
        let stored = try await store.latestLiveReading()
        XCTAssertEqual(
            stored?.date.timeIntervalSinceReferenceDate.bitPattern,
            date.timeIntervalSinceReferenceDate.bitPattern
        )
        XCTAssertEqual(stored, reading)
    }

    func test_nanTrendRateIsStoredAsNil() async throws {
        // SQLite stores NaN as NULL; the store normalises first so the same-id comparison and the
        // returned reading agree with what a later query returns.
        let store = try GlucoseStore.productionInMemory()
        let reading = sensorReading(at: 300, trendRate: .nan)
        let newlyStored = try await store.insert([reading])
        XCTAssertEqual(newlyStored.first?.trendRate, nil)
        let redelivered = try await store.insert([reading])
        XCTAssertEqual(redelivered, [])
        let latest = try await store.latestLiveReading()
        XCTAssertEqual(latest?.trendRate, nil)
    }

    func test_emptyInsertIsANoOp() async throws {
        let store = try GlucoseStore.productionInMemory()
        let newlyStored = try await store.insert([])
        XCTAssertEqual(newlyStored, [])
    }

    // MARK: Benign re-deliveries (a backfilled copy of a reading already stored live)

    private func copy(
        of reading: GlucoseReading, dateShift: TimeInterval = 0, value: GlucoseValue? = nil, trendRate: Double?? = nil,
        isBackfill: Bool = true, source: ReadingSource? = nil, serial: String? = nil
    ) -> GlucoseReading {
        GlucoseReading(
            id: reading.id, date: reading.date.addingTimeInterval(dateShift), value: value ?? reading.value,
            trendRate: trendRate ?? reading.trendRate, isBackfill: isBackfill, source: source ?? reading.source,
            sensorSerial: serial ?? reading.sensorSerial
        )
    }

    func test_S3_benignRedeliveriesAreCountedNotLoggedPerReading() async throws {
        let log = RecordingDiagnosticLog()
        let store = try GlucoseStore.productionInMemory(diagnostics: log, now: { referenceInstant })
        let live = [sensorReading(at: 0), sensorReading(at: 300), sensorReading(at: 600)]
        _ = try await store.insert(live)

        let redelivered = [
            copy(of: live[0]),                                        // isBackfill only
            copy(of: live[1], dateShift: 2.0),                        // + date exactly 2 s later
            copy(of: live[2], dateShift: -1.5, isBackfill: false),    // date only
        ]
        let newlyStored = try await store.insert(redelivered)

        XCTAssertEqual(newlyStored, [])
        let stored = try await store.readings(from: referenceInstant, to: referenceInstant.addingTimeInterval(3_600))
        XCTAssertEqual(stored, live, "the stored rows are kept as they were")
        XCTAssertEqual(log.recorded.map(\.message), [
            "Ignored 3 re-delivered reading(s) already stored (differing only in isBackfill and/or by ≤ 2 s in date)",
        ])
    }

    func test_S3_realDifferencesInARedeliveryStillRecordAFullDiagnostic() async throws {
        let base = sensorReading(at: 300, .mgdl(110), trendRate: 0.2)
        let cases: [(GlucoseReading, String)] = [
            (copy(of: base, value: .mgdl(111)), "value, isBackfill"),
            (copy(of: base, value: .belowRange), "value, isBackfill"),
            (copy(of: base, trendRate: .some(nil)), "trendRate, isBackfill"),
            (copy(of: base, trendRate: 0.4, isBackfill: false), "trendRate"),
            (copy(of: base, dateShift: 2.5), "date, isBackfill"),
            (copy(of: base, dateShift: -3, isBackfill: false), "date"),
            (copy(of: base, isBackfill: false, source: .imported(.nightscout)), "source"),
            (copy(of: base, isBackfill: false, serial: "OTHER"), "sensorSerial"),
        ]
        for (redelivery, fields) in cases {
            let log = RecordingDiagnosticLog()
            let store = try GlucoseStore.productionInMemory(diagnostics: log)
            _ = try await store.insert([base])
            let newlyStored = try await store.insert([redelivery])
            XCTAssertEqual(newlyStored, [])
            let latest = try await store.latestLiveReading()
            XCTAssertEqual(latest, base, "stored row kept (\(fields))")
            XCTAssertEqual(log.recorded.map(\.message), ["Kept stored reading \(base.id); a re-delivered copy differed in: \(fields)"])
        }
    }
}

