// Contract (HANDOFF §4.3, S1, S3). Owned by the orchestrator; change only through PROGRESS.md.

import Foundation

/// One glucose reading. Readings are facts reported by a sensor (or imported history);
/// nothing in this codebase may create a synthetic one (S1).
public struct GlucoseReading: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// Stable dedupe key (S3). Build it with `GlucoseReading.sensorID(...)` or
    /// `GlucoseReading.importedID(...)`; never from wall-clock time for sensor readings.
    public let id: String
    /// Derived from the sensor session start plus the sensor-reported offset (S3), never assumed.
    public let date: Date
    public let value: GlucoseValue
    /// mg/dL per minute exactly as reported by the sensor; `nil` if the sensor did not report one.
    public let trendRate: Double?
    /// True when the reading arrived through backfill. It keeps its original timestamp (S3).
    public let isBackfill: Bool
    public let source: ReadingSource
    /// Transmitter/sensor serial. Empty string when unknown (e.g. imported history).
    public let sensorSerial: String

    public init(
        id: String,
        date: Date,
        value: GlucoseValue,
        trendRate: Double?,
        isBackfill: Bool,
        source: ReadingSource,
        sensorSerial: String
    ) {
        self.id = id
        self.date = date
        self.value = value
        self.trendRate = trendRate
        self.isBackfill = isBackfill
        self.source = source
        self.sensorSerial = sensorSerial
    }
}

extension GlucoseReading {
    /// Dedupe key for a live or backfilled sensor reading: `<serial>:<sensorTimestamp>` (S3).
    ///
    /// - Parameter sensorTimestamp: the sensor-reported time of the reading, in seconds since
    ///   the sensor session started, exactly as it appears in the message. Because it comes from
    ///   the sensor, a backfilled copy of a reading gets the same id as the live copy.
    public static func sensorID(serial: String, sensorTimestamp: UInt32) -> String {
        "\(serial):\(sensorTimestamp)"
    }

    /// Dedupe key for imported history: `imported:<origin>:<epoch-ms>` (HANDOFF §4.5 step 3).
    public static func importedID(origin: ImportOrigin, date: Date) -> String {
        "imported:\(origin.rawValue):\(epochMilliseconds(date))"
    }

    /// Milliseconds since 1970, rounded to the nearest millisecond.
    public static func epochMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
