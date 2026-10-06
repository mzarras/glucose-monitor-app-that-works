// Ported from xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0, like this project.
// The original files have no copyright header.
// Ported from xDrip4iOS xDrip/Managers/DexcomShare/BgReading+DexcomShare.swift @ 7.1.0 (0370937)
// Ported from xDrip4iOS xDrip/Core Data/classes/BgReading+CoreDataClass.swift @ 7.1.0 (0370937)
//   (slopeOrdinal, lines 89-110 and 349-373)
//
// UNOFFICIAL AND SUBJECT TO BREAKING — see DexcomShareServer.swift.
//
// One EGV record in a PostReceiverEgvRecords body (BgReading+DexcomShare.swift:6-21):
//   { "Trend": 4, "ST": "/Date(1758636300000)/", "DT": "/Date(1758636300000)/", "Value": 123,
//     "direction": "Flat" }
// Differences from xDrip4iOS, on purpose:
//   - The arrow comes from the sensor-reported rate through TrendArrow (the app's single §7.5
//     threshold table) instead of xDrip4iOS's own slope thresholds, so Share shows the same arrow
//     as the app, Nightscout and Trio.
//   - LOW → Value 39, HIGH → Value 401 (PROGRESS D30), never 40/400 (S4). UNVERIFIED: Share's upload
//     format is a bare integer "Value" and no source documents how Share or the Dexcom Follow app
//     render a posted 39/401. The evidence is the reading side: LoopKit dexcom-share-client-swift
//     treats Share values < 40 as below range and > 400 as above range
//     (ShareClient/ShareGlucose+GlucoseKit.swift:13-16, 52-60), and 39/401 are the ecosystem's
//     LOW/HIGH values (Nightscout lib/sandbox.js:249-252; Trio payload, D21). §11 step 4a must
//     confirm with a real follower that Dexcom Follow shows LOW/HIGH (not "39"/"401") and alarms;
//     if it does not, revert to withholding LOW/HIGH: make `value(for:)` return nil for them,
//     which also makes `DexcomShareUploadDestination.canRepresent` false.

import Foundation
import GlucoseCore

struct DexcomShareEGV: Encodable, Equatable, Sendable {
    let trend: Int
    let systemTime: String
    let displayTime: String
    let value: Int
    let direction: String

    private enum CodingKeys: String, CodingKey {
        case trend = "Trend"
        case systemTime = "ST"
        case displayTime = "DT"
        case value = "Value"
        case direction
    }

    /// Share "Value" for the sensor LOW flag (D30, unverified — see file comment).
    static let lowValue = 39
    /// Share "Value" for the sensor HIGH flag (D30, unverified — see file comment).
    static let highValue = 401

    /// `nil` only for a number outside 40...400 (which `LiveReadingGate` already refuses).
    init?(reading: GlucoseReading) {
        guard let value = Self.value(for: reading.value) else { return nil }
        let arrow = TrendArrow(rate: reading.trendRate)
        let date = Self.shareDate(reading.date)
        self.trend = Self.trendCode(arrow)
        self.systemTime = date
        self.displayTime = date
        self.value = value
        self.direction = arrow.nightscoutDirection
    }

    /// LOW → 39, HIGH → 401, a number 40...400 → itself, anything else → `nil` (S4: never 40/400
    /// for a flag, never a flag for a number).
    static func value(for glucose: GlucoseValue) -> Int? {
        switch glucose {
        case .belowRange: return lowValue
        case .aboveRange: return highValue
        case .mgdl(let mgdl): return GlucoseValue.sensorReportableRange.contains(mgdl) ? mgdl : nil
        }
    }

    /// Dexcom trend code (BgReading+CoreDataClass.swift:349-373 `slopeOrdinal`; the same numbering
    /// as share2nightscout-bridge index.js:57-68 `DIRECTIONS`). xDrip4iOS sends 0 ("NONE") when
    /// the slope is hidden (`hideSlope`), which is our "no rate reported".
    static func trendCode(_ arrow: TrendArrow) -> Int {
        switch arrow {
        case .doubleUp: return 1
        case .singleUp: return 2
        case .fortyFiveUp: return 3
        case .flat: return 4
        case .fortyFiveDown: return 5
        case .singleDown: return 6
        case .doubleDown: return 7
        case .notComputable: return 0
        }
    }

    /// `/Date(<epoch ms rounded down to the whole second>)/` (BgReading+DexcomShare.swift:9). The
    /// reading's own timestamp: a backfilled reading keeps it (S3).
    static func shareDate(_ date: Date) -> String {
        let milliseconds = GlucoseReading.epochMilliseconds(date)
        let wholeSeconds = milliseconds >= 0 ? milliseconds / 1000 : (milliseconds - 999) / 1000
        return "/Date(\(wholeSeconds * 1000))/"
    }
}

/// Body of PostReceiverEgvRecords (DexcomShareUploadManager.swift:362-367).
struct DexcomShareUploadBody: Encodable, Equatable, Sendable {
    let egvs: [DexcomShareEGV]
    let serialNumber: String
    let ta: Int

    private enum CodingKeys: String, CodingKey {
        case egvs = "Egvs"
        case serialNumber = "SN"
        case ta = "TA"
    }
}
