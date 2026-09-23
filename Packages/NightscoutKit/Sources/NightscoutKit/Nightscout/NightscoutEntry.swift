// A Nightscout `entries` document as returned by GET /api/v1/entries.json, and its mapping to an
// imported `GlucoseReading` (HANDOFF §4.5 steps 1 and 3).
//
// Entry fields (cgm-remote-monitor 15.0.8): `type` is "sgv" | "mbg" | "cal" (lib/api/entries/
// index.js:484-486), `sgv` is mg/dL, `date` is epoch milliseconds (lib/server/entries.js:187 parses
// it as an integer in queries; lib/server/query.js:195 `useEpoch`), `direction` is the arrow name.
// Nightscout defines no rate-of-change field: `direction`/`trend` are arrow buckets and `delta`
// (some uploaders) is a difference between readings, so imported readings get `trendRate: nil`.

import Foundation
import GlucoseCore

/// One entry. Every field is optional and decoded leniently (numbers may arrive as JSON numbers or
/// numeric strings), so one odd document never fails a whole page; mapping decides what is usable.
struct NightscoutEntry: Decodable, Sendable, Equatable {
    let id: String?
    let type: String?
    let sgv: Double?
    /// Epoch milliseconds.
    let date: Double?
    let direction: String?
    let device: String?

    init(id: String? = nil, type: String?, sgv: Double?, date: Double?, direction: String? = nil, device: String? = nil) {
        self.id = id
        self.type = type
        self.sgv = sgv
        self.date = date
        self.direction = direction
        self.device = device
    }

    private enum CodingKeys: String, CodingKey {
        case id = "_id", type, sgv, date, direction, device
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        sgv = Self.lenientNumber(container, .sgv)
        date = Self.lenientNumber(container, .date)
        direction = try? container.decodeIfPresent(String.self, forKey: .direction)
        device = try? container.decodeIfPresent(String.self, forKey: .device)
    }

    private static func lenientNumber(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let number = try? container.decodeIfPresent(Double.self, forKey: key) { return number }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return Double(text) }
        return nil
    }
}

/// Why an entry did not become a reading. Counted in import progress.
public enum NightscoutEntrySkipReason: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    /// `type` is not "sgv" (e.g. "mbg" fingersticks, "cal" calibrations) — ignored by design.
    case notSGV
    /// No usable `date` (missing, not a number, or not after 1970).
    case missingDate
    /// No usable `sgv`.
    case missingValue
    /// `sgv` below 39: a Dexcom error code, not glucose (lib/plugins/errorcodes.js:13-22).
    case errorCode
}

enum NightscoutEntryMapper {
    enum Result: Sendable, Equatable {
        case reading(GlucoseReading)
        case skipped(NightscoutEntrySkipReason)
    }

    /// Maps one entry to an imported reading: `source: .imported(.nightscout)`, id from
    /// `GlucoseReading.importedID(origin:date:)`, `trendRate: nil`, `isBackfill: false`,
    /// `sensorSerial: ""` (brief §A). The timestamp is Nightscout's `date`, unchanged (S3).
    static func map(_ entry: NightscoutEntry) -> Result {
        guard entry.type == "sgv" else { return .skipped(.notSGV) }
        guard let milliseconds = entry.date, milliseconds.isFinite, milliseconds > 0 else {
            return .skipped(.missingDate)
        }
        guard let sgv = entry.sgv else { return .skipped(.missingValue) }
        let value: GlucoseValue
        switch NightscoutGlucoseEncoding.decode(sgv: sgv) {
        case .value(let decoded): value = decoded
        case .errorCode: return .skipped(.errorCode)
        case .invalid: return .skipped(.missingValue)
        }
        let date = Date(timeIntervalSince1970: milliseconds.rounded() / 1000)
        return .reading(GlucoseReading(
            id: GlucoseReading.importedID(origin: .nightscout, date: date),
            date: date,
            value: value,
            trendRate: nil,
            isBackfill: false,
            source: .imported(.nightscout),
            sensorSerial: ""
        ))
    }
}
