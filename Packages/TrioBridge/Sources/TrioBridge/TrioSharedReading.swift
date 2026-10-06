// One element of the `latestReadings` array, and the encoder for the whole array.
//
// Shape: the Dexcom Share-style dictionary xDrip4iOS writes (`xDrip/Managers/Loop/LoopManager.swift:521-528`)
// and Trio parses (`Trio/Sources/APS/CGM/AppGroupSource.swift:54-99`). Example element:
//
//     {"DT":"/Date(1758002400000)/","ST":"/Date(1758002400000)/","Trend":4,"Value":112,"direction":"Flat"}
//
// Deliberately absent: "from". Trio drops an element whose "from" is present and differs from "xDrip"
// (`AppGroupSource.swift:83-85`) and accepts one without it, so leaving it out means this app never
// labels its readings as xDrip4iOS's (docs/trio-bridge.md, "Source identity").

import Foundation
import GlucoseCore

/// A reading exactly as it is written into Trio's App Group.
struct TrioSharedReading: Encodable, Equatable, Sendable {
    /// "Value": mg/dL as a JSON integer. Trio reads `sgv["Value"] as? Int` (`AppGroupSource.swift:63`),
    /// which silently skips a non-integral number, and treats it as mg/dL whatever Trio's display unit is
    /// (`AppGroupSource.swift:87-98`).
    let value: Int
    /// "DT": `/Date(<milliseconds since 1970>)/`. Trio takes the text between the parentheses and
    /// force-unwraps `Double(...)` (`AppGroupSource.swift:104-115`): anything other than an integer there
    /// (for example Dexcom Share's `/Date(1426292016000-0700)/` offset form) crashes Trio.
    let displayTime: String
    /// "ST": same value as "DT", as xDrip4iOS writes it (`LoopManager.swift:524-525`). Trio does not read it.
    let systemTime: String
    /// "Trend": Dexcom Share trend ordinal (share2nightscout-bridge `index.js:57-68`). Trio reads it only
    /// when "direction" is missing (`AppGroupSource.swift:70-79`); written so the element is complete.
    let trend: Int
    /// "direction": Nightscout direction name. Trio reads it first (`AppGroupSource.swift:71-72`) and maps it
    /// with `BloodGlucose.Direction(rawValue:)` (`Trio/Sources/Models/BloodGlucose.swift:6-18`).
    /// An element with neither "direction" nor a usable "Trend" is skipped (`AppGroupSource.swift:81`).
    let direction: String

    enum CodingKeys: String, CodingKey {
        case value = "Value"
        case displayTime = "DT"
        case systemTime = "ST"
        case trend = "Trend"
        case direction
    }

    /// Builds the element for a reading whose Trio value has already been decided (see `TrioBridge`).
    init(mgdl: Int, date: Date, trendRate: Double?) {
        let arrow = TrendArrow(rate: trendRate)
        let time = Self.dexcomDateString(date)
        value = mgdl
        displayTime = time
        systemTime = time
        trend = Self.dexcomShareTrend(arrow)
        direction = arrow.nightscoutDirection
    }

    /// `/Date(<ms>)/` with the reading's own timestamp in whole milliseconds (S3). xDrip4iOS floors to the
    /// second (`LoopManager.swift:521`); this bridge keeps the millisecond so the value Trio stores is the
    /// same instant this app stores. Trio parses any integer (`AppGroupSource.swift:113-114`).
    static func dexcomDateString(_ date: Date) -> String {
        "/Date(\(GlucoseReading.epochMilliseconds(date)))/"
    }

    /// Dexcom Share trend ordinal for an arrow (share2nightscout-bridge `index.js:57-68`), which is also
    /// LoopKit's `GlucoseTrend` raw value for 1...7 (`LoopKit/LoopKit/GlucoseKit/GlucoseTrend.swift:12-19`).
    static func dexcomShareTrend(_ arrow: TrendArrow) -> Int {
        switch arrow {
        case .doubleUp: return 1
        case .singleUp: return 2
        case .fortyFiveUp: return 3
        case .flat: return 4
        case .fortyFiveDown: return 5
        case .singleDown: return 6
        case .doubleDown: return 7
        case .notComputable: return 8 // "NOT COMPUTABLE"
        }
    }
}

enum TrioPayloadEncoder {
    /// Encodes the array Trio reads. Keys are sorted and slashes are not escaped so the bytes are
    /// deterministic (golden-file test); Trio parses with `JSONSerialization` (`AppGroupSource.swift:54`),
    /// for which key order and slash escaping make no difference.
    static func encode(_ readings: [TrioSharedReading]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(readings)
    }
}
