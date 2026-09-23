// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// The original file carries no copyright header of its own.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/DexcomG7ExtendedVersionMessage.swift @ 7.1.0 (0370937)
// Changes: only the 10-day product is supported (HANDOFF §1.1); constants cite their sources;
// the reported warm-up is used (xDrip4iOS only traced it).

import Foundation
import GlucoseCore

/// Session timing for a G7 10-day sensor.
///
/// The sensor reports its session length (grace included) and warm-up in the `0x52` response, which
/// is requested before GetData until it has been answered once (G7ConnectionCycle). No reading is
/// handled without it: there are no assumed defaults. Any other reported session length (a 15-day G7,
/// ONE+, Stelo, or something new) is refused: the source then publishes no readings (HANDOFF §1.1).
/// The warm-up is whatever the sensor reports — 1 620 s (27 min) for a 10-day sensor, as in the
/// captured `0x52` and G7SensorKit G7Sensor.swift:68 — not Dexcom's user-facing "30 minutes", which
/// would refuse the first valid readings at about 28 min (G7SensorKit G7GlucoseMessageTests.swift:40-77).
enum G7SensorLifetime {
    /// 10 days + 12 h grace = 907 200 s, the value a 10-day sensor reports in `0x52`.
    /// xDrip4iOS ConstantsDexcomG7.swift:15-16 (10.5 days) and DexcomG7ExtendedVersionMessage.swift:61-62;
    /// captured `5200c0d70d00…` = 0x000DD7C0 = 907 200 (xDrip Tests/DexcomG7CalibrationTests.swift:231-236).
    static let tenDaySessionLength: TimeInterval = 907_200

    /// Grace period after the rated life. Constant, not reported separately: the reported session
    /// length includes it (DexcomG7ExtendedVersionMessage.swift:3-5, :14-15; G7SensorKit
    /// G7Sensor.swift:69 `gracePeriod = 12 h`, G7CGMManager.swift:115-117 `lifetime = sessionLength - gracePeriod`).
    static let gracePeriod: TimeInterval = 12 * 3600

    struct Parameters: Equatable, Sendable {
        /// Rated life, grace excluded (10 days).
        let lifetime: TimeInterval
        let gracePeriod: TimeInterval
        let warmUp: TimeInterval
    }

    /// Parameters from a `0x52` response, or nil if this is not a supported 10-day sensor or the
    /// reported warm-up would make the session malformed.
    static func parameters(reportedSessionLength: TimeInterval, reportedWarmUp: TimeInterval) -> Parameters? {
        guard reportedSessionLength == tenDaySessionLength else { return nil }
        let lifetime = reportedSessionLength - gracePeriod
        guard reportedWarmUp >= 0, reportedWarmUp <= lifetime else { return nil }
        return Parameters(lifetime: lifetime, gracePeriod: gracePeriod, warmUp: reportedWarmUp)
    }

    /// The `SensorSession` for a session start derived from the sensor clock (G7SessionClock).
    /// Always well formed: parameters guarantee 0 ≤ warm-up ≤ lifetime and grace ≥ 0.
    static func session(serial: String, start: Date, parameters: Parameters) -> SensorSession {
        let expiresAt = start.addingTimeInterval(parameters.lifetime)
        return SensorSession(
            serial: serial,
            start: start,
            warmUpEndsAt: start.addingTimeInterval(parameters.warmUp),
            expiresAt: expiresAt,
            gracePeriodEndsAt: expiresAt.addingTimeInterval(parameters.gracePeriod)
        )
    }
}
