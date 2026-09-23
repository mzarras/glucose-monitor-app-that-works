import Foundation
import GlucoseCore
@testable import WidgetCore

/// Hand-built fixtures. Dates are whole seconds so JSON round trips (milliseconds) are exact.
enum Fixture {
    /// 2026-09-23 12:35:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_758_630_900)

    static func minutesAgo(_ minutes: Double) -> Date {
        now.addingTimeInterval(-minutes * 60)
    }

    static func reading(
        _ value: GlucoseValue,
        minutesAgo minutes: Double,
        rate: Double? = 0,
        source: ReadingSource = .sensor,
        serial: String = "TESTSERIAL"
    ) -> GlucoseReading {
        let date = minutesAgo(minutes)
        let id: String
        if case .imported(let origin) = source {
            id = GlucoseReading.importedID(origin: origin, date: date)
        } else {
            id = GlucoseReading.sensorID(serial: serial, sensorTimestamp: UInt32(date.timeIntervalSince1970) % 1_000_000)
        }
        return GlucoseReading(id: id, date: date, value: value, trendRate: rate, isBackfill: false, source: source, sensorSerial: serial)
    }

    static func latest(_ value: GlucoseValue, minutesAgo minutes: Double, trend: TrendArrow = .flat, delta: GlucoseDelta? = nil) -> LatestReading {
        LatestReading(date: minutesAgo(minutes), value: value, trend: trend, delta: delta)
    }

    static func point(_ value: GlucoseValue, minutesAgo minutes: Double) -> ChartPoint {
        ChartPoint(date: minutesAgo(minutes), value: value)
    }

    static let activeSensor = SensorState.active(
        sessionStart: now.addingTimeInterval(-5 * 86_400),
        expiresAt: now.addingTimeInterval(5 * 86_400)
    )
}
