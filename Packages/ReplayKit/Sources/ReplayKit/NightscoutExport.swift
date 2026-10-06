// Parser for a Nightscout entries export (`GET /api/v1/entries.json`). DEBUG only (S6).
//
// Input: a JSON array of entries such as
//   {"type": "sgv", "sgv": 120, "date": 1768032000000, "dateString": "2026-01-10T08:00:00.000Z",
//    "direction": "Flat", "device": "…"}
// Nightscout returns newest first; order does not matter here.
//
// How Nightscout encodes values outside the CGM's range (cgm-remote-monitor 15.0.8, commit
// 92d0834, vendor-ref/cgm-remote-monitor):
// - sgv < 39: not glucose. Dexcom error/status codes — 1 SENSOR_NOT_ACTIVE, 2 MINIMAL_DEVIATION,
//   3 NO_ANTENNA, 5 SENSOR_NOT_CALIBRATED, 6 COUNTS_DEVIATION, 9 ABSOLUTE_DEVIATION,
//   10 POWER_DEVIATION, 12 BAD_RF (lib/plugins/errorcodes.js:13-22); anything `< 39` is treated as
//   an error code (errorcodes.js:42, lib/plugins/bgnow.js:99-100, lib/client/index.js:542-543).
// - sgv 39 (anything < 40): LOW (lib/client/index.js:544-545; lib/sandbox.js:249-250 `=== 39`).
// - sgv > 400 (uploaders send 401): HIGH (lib/client/index.js:546-547; lib/sandbox.js:251-252
//   `=== 401`).
// This parser maps LOW to `.belowRange` and HIGH to `.aboveRange` — flags, never numbers (S4) —
// and drops error codes (they are not readings, S1).
#if DEBUG
import Foundation
import GlucoseCore

public struct NightscoutExport: Sendable, Equatable {
    /// One usable sgv entry.
    public struct Entry: Sendable, Equatable {
        /// From the entry's `date` field: milliseconds since 1970, the canonical Nightscout time.
        /// `dateString` is ignored.
        public let date: Date
        public let value: GlucoseValue
    }

    public enum ParseError: Error, Equatable {
        case notAJSONArray
    }

    /// Usable sgv entries, ascending by date. Entries with exactly the same `date` as an earlier
    /// one are dropped (Nightscout often holds the same reading from two uploaders).
    public let entries: [Entry]
    /// Entries whose `type` is not "sgv" (mbg, cal, …) or missing.
    public let ignoredNonSGVCount: Int
    /// sgv entries holding a Dexcom error code (sgv < 39).
    public let skippedErrorCodeCount: Int
    /// sgv entries without a usable `sgv` or `date` number.
    public let skippedMalformedCount: Int
    /// sgv entries dropped because an earlier entry has exactly the same `date`.
    public let droppedDuplicateDateCount: Int

    public static func parse(_ data: Data) throws -> NightscoutExport {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw ParseError.notAJSONArray
        }
        var usable: [Entry] = []
        var ignoredNonSGV = 0, errorCodes = 0, malformed = 0

        for element in array {
            guard let object = element as? [String: Any], object["type"] as? String == "sgv" else {
                ignoredNonSGV += 1
                continue
            }
            guard let sgv = number(object["sgv"]), let milliseconds = number(object["date"]),
                  sgv.isFinite, milliseconds.isFinite else {
                malformed += 1
                continue
            }
            guard let value = glucoseValue(sgv: sgv) else {
                errorCodes += 1
                continue
            }
            usable.append(Entry(date: Date(timeIntervalSince1970: milliseconds / 1000), value: value))
        }

        // Stable sort keeps export order among equal dates, so "the earlier one" is well defined.
        let sorted = usable.enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)
        var entries: [Entry] = []
        var duplicates = 0
        for entry in sorted {
            if entry.date == entries.last?.date {
                duplicates += 1
            } else {
                entries.append(entry)
            }
        }

        return NightscoutExport(
            entries: entries,
            ignoredNonSGVCount: ignoredNonSGV,
            skippedErrorCodeCount: errorCodes,
            skippedMalformedCount: malformed,
            droppedDuplicateDateCount: duplicates
        )
    }

    /// Nightscout sgv → value, per the conventions above. nil = Dexcom error code, not a reading.
    /// A fractional sgv inside 40…400 is rounded to the nearest integer.
    public static func glucoseValue(sgv: Double) -> GlucoseValue? {
        if sgv < 39 { return nil }
        if sgv < 40 { return .belowRange }
        if sgv > 400 { return .aboveRange }
        return .mgdl(Int(sgv.rounded()))
    }

    /// A JSON number (or a numeric string, which some old uploaders wrote) as Double.
    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, !(value is Bool) { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
#endif
