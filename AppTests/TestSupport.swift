import Foundation
import GlucoseCore
import WidgetCore
@testable import Sensor

/// Deterministic locale and zone for text assertions.
let testContext = DisplayContext(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)

/// 2026-09-23 12:35:00 UTC, whole seconds.
let t0 = Date(timeIntervalSince1970: 1_790_166_900)

func minutes(_ m: Double, from date: Date = t0) -> Date {
    date.addingTimeInterval(m * 60)
}

func latest(_ value: GlucoseValue, ageMinutes: Double, trend: TrendArrow = .flat, delta: GlucoseDelta? = GlucoseDelta(mgdl: -3, minutes: 5), now: Date = t0) -> LatestReading {
    LatestReading(date: minutes(-ageMinutes, from: now), value: value, trend: trend, delta: delta)
}

let activeSensor = SensorState.active(sessionStart: minutes(-(5 * 1_440 + 16 * 60)), expiresAt: minutes(4 * 1_440 + 7 * 60 + 20))

let healthy = ServiceHealth(
    trio: .ok(lastHandoff: minutes(-3)),
    nightscout: .ok(lastUpload: minutes(-3)),
    dexcomShare: .ok(lastUpload: minutes(-3)),
    notifications: .authorized,
    alarmVolume: .ok(level: 0.8),
    forceQuitGap: nil
)
