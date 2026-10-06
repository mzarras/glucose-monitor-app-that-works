// Sample widget entries for SwiftUI previews and the screenshot test. DEBUG only: no Release
// build contains a sample value (S1). Values are made up.

#if DEBUG
import Foundation
import GlucoseCore

public enum WidgetSamples {
    public enum State: String, CaseIterable, Identifiable, Sendable {
        case normal, low, high, lowFlag, highFlag, stale, noData, warmingUp, expired, sensorError, pairingRejected, calibrationNeeded, notPaired, clockMismatch
        public var id: String { rawValue }
    }

    /// Three hours of 5-minute points ending `age` minutes before `now`.
    public static func recent(now: Date, age: Double, shape: (Double) -> GlucoseValue) -> [ChartPoint] {
        stride(from: 36, through: 0, by: -1).map { step in
            let minutesBeforeLast = Double(step * 5)
            return ChartPoint(date: now.addingTimeInterval(-(age + minutesBeforeLast) * 60), value: shape(minutesBeforeLast))
        }
    }

    /// The mockup curve: 82 → ~120 → 105 over three hours.
    static func mockup(_ m: Double) -> GlucoseValue {
        let x = 1 - m / 180
        return .mgdl(Int((82 + 23 * x + 26 * sin(Double.pi * x)).rounded()))
    }

    public static func content(_ state: State, now: Date, accent: AccentChoice = .default) -> WidgetEntryContent {
        var age = 3.0
        var shape: (Double) -> GlucoseValue = mockup
        var trend = TrendArrow.flat
        var sensor = SensorState.active(sessionStart: now.addingTimeInterval(-5 * 86_400), expiresAt: now.addingTimeInterval(4 * 86_400))
        var hasReading = true
        switch state {
        case .normal: break
        case .low:
            age = 2; trend = .fortyFiveDown
            shape = { m in m <= 40 ? .mgdl(Int(62 + m * 0.9)) : mockup(m) }
        case .high:
            age = 1; trend = .singleUp
            shape = { m in m <= 60 ? .mgdl(Int(232 - m * 1.6)) : mockup(m) }
        case .lowFlag:
            age = 1; trend = .fortyFiveDown
            shape = { m in m <= 10 ? .belowRange : m <= 45 ? .mgdl(Int(41 + (m - 10) * 0.8)) : mockup(m) }
        case .highFlag:
            age = 2; trend = .doubleUp
            shape = { m in m <= 5 ? .aboveRange : m <= 60 ? .mgdl(Int(398 - (m - 5) * 2.5)) : mockup(m) }
        case .stale:
            age = 12
        case .noData:
            age = 34
        case .warmingUp:
            sensor = .warmingUp(endsAt: now.addingTimeInterval(72 * 60)); hasReading = false
        case .expired:
            sensor = .expired; age = 25
        case .sensorError:
            sensor = .error(code: 7, description: "Sensor signal error")
        case .pairingRejected:
            sensor = .failed(SensorFailure(kind: .pairingRejected, message: "The sensor didn't accept this phone. Pair it again with the code on the applicator."))
        case .calibrationNeeded:
            sensor = .calibrationNeeded(code: 4); age = 7
        case .notPaired:
            sensor = .notPaired; hasReading = false
        case .clockMismatch:
            age = -60
        }
        let recent = hasReading ? Self.recent(now: now, age: age, shape: shape) : []
        let latest: LatestReading? = recent.last.map { last in
            let previous = recent[recent.count - 2]
            return LatestReading(
                date: last.date, value: last.value, trend: trend,
                delta: GlucoseDelta.between(latestDate: last.date, latestValue: last.value, previousDate: previous.date, previousValue: previous.value)
            )
        }
        let snapshot = WidgetSnapshot(writtenAt: latest?.date ?? now, latest: latest, sensorState: sensor, recent: recent, accent: accent)
        return WidgetTimeline.entries(snapshot: snapshot, now: now)[0]
    }
}
#endif
