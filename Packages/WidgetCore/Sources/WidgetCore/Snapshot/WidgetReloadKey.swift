// The part of a widget snapshot that the widget's timeline actually depends on (D61). The app
// writes the snapshot on every pipeline drain (every sensor state event: several per 5-minute
// wake), but asks WidgetKit to reload only when this key changes: iOS gives a widget roughly
// 40–70 background reloads a day, and a reload spent on a snapshot that displays the same thing
// leaves none for the next real reading (docs/widgets.md "Reload policy").
//
// Derived from what `GlucoseDisplayState.classify`, `transitionDates`, `ClockMismatchLatch` and
// the widget views read from a snapshot. `writtenAt` is left out on purpose: it changes on every
// write and the widget only uses it for the clock check, which `readingAheadOfSnapshot` covers.

import Foundation
import GlucoseCore

public struct WidgetReloadKey: Sendable, Equatable {
    /// The number, trend and delta (date, value, trend, delta).
    public let latest: LatestReading?
    /// The chart points that can be on screen (see `chartPoints(of:)`).
    public let chart: [ChartPoint]
    public let sensor: WidgetSensorKey
    public let accent: AccentChoice
    public let isReplay: Bool
    /// The latest reading is dated after its own snapshot's write time (beyond the 60 s
    /// tolerance): the widget's clock-mismatch check (`ClockMismatchLatch`, review N1).
    public let readingAheadOfSnapshot: Bool

    public init(_ snapshot: WidgetSnapshot) {
        latest = snapshot.latest
        chart = Self.chartPoints(of: snapshot)
        sensor = WidgetSensorKey(snapshot.sensorState)
        accent = snapshot.accent
        isReplay = snapshot.isReplay
        readingAheadOfSnapshot = snapshot.latest.map { $0.date > snapshot.writtenAt.addingTimeInterval(LiveReadingGate.futureTolerance) } ?? false
    }

    /// The snapshot's points from 3 hours before the earlier of its latest reading and its write
    /// time. Every chart a timeline built from this snapshot draws starts there or later (3 hours
    /// before an entry date ≥ `writtenAt`, or before the last reading, D61), so points that drop
    /// out of the snapshot's window below this floor change nothing on screen and need no reload.
    static func chartPoints(of snapshot: WidgetSnapshot) -> [ChartPoint] {
        let end = min(snapshot.latest?.date ?? snapshot.writtenAt, snapshot.writtenAt)
        let floor = end.addingTimeInterval(-WidgetSnapshot.historyWindow)
        return snapshot.recent.filter { $0.date >= floor }
    }

    /// Why the widget must reload for `current`, or `nil` when it would display the same as for
    /// `previous` (the key of the last snapshot a reload was requested for; nil: none yet this run).
    public static func reloadReason(previous: WidgetReloadKey?, current: WidgetReloadKey) -> WidgetReloadReason? {
        guard let previous else { return .noEarlierReload }
        if previous.latest != current.latest { return .latestReading(current.latest?.date) }
        if previous.sensor != current.sensor { return .sensorState(current.sensor) }
        if previous.readingAheadOfSnapshot != current.readingAheadOfSnapshot { return .clockCheck }
        if previous.chart != current.chart { return .chart }
        if previous.accent != current.accent { return .accent(current.accent) }
        if previous.isReplay != current.isReplay { return .replay }
        return nil
    }
}

/// The sensor state as the widget can tell it apart. States in which readings are judged by age
/// alone (`classify` falls through to the age rules, no transition date) are one value; every
/// state with its own message or a scheduled change keeps what the widget reads from it.
public enum WidgetSensorKey: Sendable, Equatable {
    /// searching, connecting, authenticating, active, Bluetooth unavailable, a transient failure.
    case readingsByAge
    case notPaired
    /// The end is a timeline transition, so a different end is a different key.
    case warmingUp(endsAt: Date)
    case gracePeriod(endsAt: Date)
    case expired
    /// A failure that raises the sensor alert: its title and message are shown.
    case failed(SensorFailure)
    /// The message shows the code and description.
    case error(code: Int, description: String)
    /// The message does not show the code.
    case calibrationNeeded
    case calibrationRejected

    /// Exhaustive on purpose: a new `SensorState` case must be placed here (compile error).
    public init(_ state: SensorState) {
        switch state {
        case .searching, .connecting, .authenticating, .active, .bluetoothUnavailable:
            self = .readingsByAge
        case .notPaired:
            self = .notPaired
        case .warmingUp(let endsAt):
            self = .warmingUp(endsAt: endsAt)
        case .gracePeriod(let endsAt):
            self = .gracePeriod(endsAt: endsAt)
        case .expired:
            self = .expired
        case .failed(let failure):
            // Same rule as `GlucoseDisplayState.classify`: only these replace the reading.
            self = failure.raisesSensorAlert ? .failed(failure) : .readingsByAge
        case .error(let code, let description):
            self = .error(code: code, description: description)
        case .calibrationNeeded:
            self = .calibrationNeeded
        case .calibrationError:
            self = .calibrationRejected
        }
    }
}

/// Why a reload was requested; one diagnostic line each (`logText`).
public enum WidgetReloadReason: Sendable, Equatable {
    /// No reload requested yet in this process, or since the app came to the foreground.
    case noEarlierReload
    /// A new latest reading (its date), or none any more (nil).
    case latestReading(Date?)
    case sensorState(WidgetSensorKey)
    case clockCheck
    case chart
    case accent(AccentChoice)
    case replay

    public var logText: String {
        switch self {
        case .noEarlierReload: return "first publish since launch or foreground"
        case .latestReading(let date?): return "new reading \(date.ISO8601Format())"
        case .latestReading(nil): return "no latest reading"
        case .sensorState(let key): return "sensor state \(key.logName)"
        case .clockCheck: return "reading dated after the snapshot (clock check)"
        case .chart: return "chart history changed"
        case .accent(let accent): return "accent \(accent.rawValue)"
        case .replay: return "replay marker changed"
        }
    }
}

extension WidgetSensorKey {
    var logName: String {
        switch self {
        case .readingsByAge: return "receiving"
        case .notPaired: return "not paired"
        case .warmingUp(let endsAt): return "warming up until \(endsAt.ISO8601Format())"
        case .gracePeriod(let endsAt): return "grace period until \(endsAt.ISO8601Format())"
        case .expired: return "expired"
        case .failed(let failure): return "failed (\(failure.kind.rawValue))"
        case .error(let code, _): return "error \(code)"
        case .calibrationNeeded: return "calibration needed"
        case .calibrationRejected: return "calibration rejected"
        }
    }
}
