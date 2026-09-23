// What the hero area (Now screen) and the widget may show at a given moment. One classifier for
// both, so the app and the widget never disagree about whether a number is current (S5).

import Foundation
import GlucoseCore

/// Age thresholds for the latest reading (HANDOFF §7.4, S5).
public enum Freshness {
    /// From this age the reading is stale: the widget dims it, the Now screen replaces the hero
    /// with a message. G7 readings arrive every 5 min, so this is one missed reading.
    public static let staleAfter: TimeInterval = 10 * 60
    /// From this age there is no usable data: the number is no longer shown at all.
    public static let noDataAfter: TimeInterval = 20 * 60
}

public enum GlucoseDisplayState: Sendable, Equatable, Hashable {
    /// The latest reading is under 10 min old and the sensor state allows showing it.
    case current(LatestReading)
    /// 10 ≤ age < 20 min. Widget: dimmed number marked "stale". Now screen: a message that
    /// quotes the last value with its time, never the bare number (S5).
    case stale(LatestReading)
    /// Age ≥ 20 min, or no reading at all.
    case noData(last: LatestReading?)
    /// Sensor warm-up in progress; no readings yet.
    case warmingUp(endsAt: Date)
    /// Sensor expired, or its grace period ended.
    case sensorExpired(last: LatestReading?)
    /// Sensor reported an error or the session failed.
    case sensorError(message: String, last: LatestReading?)
    /// No sensor paired.
    case notPaired

    /// - Parameters:
    ///   - latest: the newest stored reading, if any.
    ///   - sensorState: the CGM source's state as last reported.
    ///   - now: the moment to classify for (a widget timeline entry date, or the Now screen's clock).
    public static func classify(latest: LatestReading?, sensorState: SensorState, now: Date) -> GlucoseDisplayState {
        switch sensorState {
        case .notPaired:
            return .notPaired
        case .warmingUp(let endsAt) where now < endsAt:
            return .warmingUp(endsAt: endsAt)
        case .expired:
            return .sensorExpired(last: latest)
        case .gracePeriod(let endsAt) where now >= endsAt:
            // The grace period's end is a date the sensor reported; past it no reading is valid.
            return .sensorExpired(last: latest)
        case .failed(let reason):
            return .sensorError(message: reason, last: latest)
        case .error(let code, let description):
            return .sensorError(message: "\(description) (code \(code))", last: latest)
        case .searching, .connecting, .authenticating, .warmingUp, .active, .gracePeriod, .bluetoothUnavailable:
            // Readings may still be current (e.g. Bluetooth just turned off); age decides.
            // Bluetooth problems are reported separately as an S5 banner.
            break
        }
        guard let latest else { return .noData(last: nil) }
        let age = now.timeIntervalSince(latest.date)
        if age < Freshness.staleAfter { return .current(latest) }
        if age < Freshness.noDataAfter { return .stale(latest) }
        return .noData(last: latest)
    }

    /// The reading shown as a number in this state: only `.current` (and, dimmed, in the widget's
    /// `.stale`). Every other state shows a message instead.
    public var displayedReading: LatestReading? {
        switch self {
        case .current(let reading), .stale(let reading): return reading
        case .noData, .warmingUp, .sensorExpired, .sensorError, .notPaired: return nil
        }
    }

    /// The instant after which `classify` would return something different for the same inputs,
    /// if any. Used to schedule widget timeline entries.
    public static func transitionDates(latest: LatestReading?, sensorState: SensorState) -> [Date] {
        var dates: [Date] = []
        if let latest {
            dates.append(latest.date.addingTimeInterval(Freshness.staleAfter))
            dates.append(latest.date.addingTimeInterval(Freshness.noDataAfter))
        }
        switch sensorState {
        case .warmingUp(let endsAt): dates.append(endsAt)
        case .gracePeriod(let endsAt): dates.append(endsAt)
        default: break
        }
        return dates.sorted()
    }
}
