import Foundation
import GlucoseCore
import os
@testable import GlucoseStore

/// 2026-01-15T12:00:00Z. A fixed instant so every expected value is hand-computable.
let referenceInstant = Date(timeIntervalSince1970: 1_768_478_400)

let testSerial = "3M1234"

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
