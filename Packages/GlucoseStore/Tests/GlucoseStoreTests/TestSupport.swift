import Foundation
import GlucoseCore
import GRDB
import os
@testable import GlucoseStore

/// 2026-01-15T12:00:00Z. A fixed instant so every expected value is hand-computable.
let referenceInstant = Date(timeIntervalSince1970: 1_768_478_400)

let testSerial = "3M1234"

/// The stores' clock in tests: 2030-01-01T00:00:00Z, later than every fixture date, so the
/// future-date check (D33) only trips in tests that set the clock themselves. Tests never use the
/// wall clock.
let testClockNow = Date(timeIntervalSince1970: 1_893_456_000)
let testClock: @Sendable () -> Date = { testClockNow }

/// A live sensor reading `secondsAfterReference` after `referenceInstant`. The id follows
/// `GlucoseReading.sensorID`, with the sensor timestamp equal to the offset (session started at
/// the reference instant).
func sensorReading(
    at secondsAfterReference: TimeInterval,
    _ value: GlucoseValue = .mgdl(110),
    trendRate: Double? = 0.2,
    isBackfill: Bool = false,
    serial: String = testSerial
) -> GlucoseReading {
    GlucoseReading(
        id: GlucoseReading.sensorID(serial: serial, sensorTimestamp: UInt32(secondsAfterReference)),
        date: referenceInstant.addingTimeInterval(secondsAfterReference),
        value: value,
        trendRate: trendRate,
        isBackfill: isBackfill,
        source: .sensor,
        sensorSerial: serial
    )
}

/// An imported reading built the way the importer builds them (HANDOFF §4.5 step 3).
func importedReading(
    at secondsAfterReference: TimeInterval,
    _ value: GlucoseValue = .mgdl(120),
    origin: ImportOrigin = .nightscout
) -> GlucoseReading {
    let date = referenceInstant.addingTimeInterval(secondsAfterReference)
    return GlucoseReading(
        id: GlucoseReading.importedID(origin: origin, date: date),
        date: date,
        value: value,
        trendRate: nil,
        isBackfill: false,
        source: .imported(origin),
        sensorSerial: ""
    )
}

/// A replay-store reading (DEBUG replay role only accepts `.replay` / `.mock`).
func replayReading(
    at secondsAfterReference: TimeInterval,
    _ value: GlucoseValue = .mgdl(110),
    source: ReadingSource = .replay
) -> GlucoseReading {
    GlucoseReading(
        id: GlucoseReading.sensorID(serial: "REPLAY-TEST", sensorTimestamp: UInt32(secondsAfterReference)),
        date: referenceInstant.addingTimeInterval(secondsAfterReference),
        value: value,
        trendRate: nil,
        isBackfill: false,
        source: source,
        sensorSerial: "REPLAY-TEST"
    )
}

/// A settable clock for tests that move time (never the wall clock).
final class TestClock: Sendable {
    private let current: OSAllocatedUnfairLock<Date>
    init(_ start: Date) { current = OSAllocatedUnfairLock(initialState: start) }
    var now: Date {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
}

/// Collects diagnostic events so tests can assert on them.
final class RecordingDiagnosticLog: DiagnosticLog {
    private let events = OSAllocatedUnfairLock<[DiagnosticEvent]>(initialState: [])

    func record(_ event: DiagnosticEvent) {
        events.withLock { $0.append(event) }
    }

    var recorded: [DiagnosticEvent] {
        events.withLock { $0 }
    }
}

/// A fresh directory under the system temporary directory, removed by the caller.
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("GlucoseStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A database at the v1 schema only, as a build from before migration v2 left it, with rows written
/// directly (including numbers v1 still allowed but v2 does not). WAL mode (`DatabasePool`), like
/// every production file.
func makeV1Database(at url: URL, rows: [(id: String, date: Double, kind: String, mgdl: Int?, source: String, origin: String?)]) throws {
    let pool = try DatabasePool(path: url.path)
    try StoreSchema.makeMigrator().migrate(pool, upTo: StoreSchema.v1CreateReading)
    try pool.write { db in
        for row in rows {
            try db.execute(sql: """
                INSERT INTO reading (id, date, valueKind, mgdl, trendRate, isBackfill, sourceKind, importOrigin, sensorSerial)
                VALUES (?, ?, ?, ?, 0.2, 0, ?, ?, 'S')
                """, arguments: [row.id, row.date, row.kind, row.mgdl, row.source, row.origin])
        }
    }
    try pool.close()
}
