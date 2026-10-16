// D61 (owner decision on review m1): the widget never shows a reading from an earlier sensor as a
// number once the app is pairing or following a new one, and keeps showing the new sensor's
// warm-up across an app relaunch, while the source reports transient states (searching,
// connecting, authenticating) before the sensor reports warm-up again.
//
// The app writes what it knows about the current sensor into the snapshot (`currentSensor`, plus
// the latest reading's own serial). Only stored or sensor-reported data (S3): the serial of the
// stored pairing, and the session's start and warm-up end as `CGMSource.currentSession` reports
// them (G7Kit persists the session across relaunches; CGMSource.swift "Lifetime rule"). A snapshot
// without `currentSensor` (written before this field existed, or before the app could read its
// pairing) is shown as before.

import Foundation
import GlucoseCore

/// The sensor whose readings the widget may show.
public struct WidgetCurrentSensor: Sendable, Equatable, Hashable, Codable {
    /// The current sensor's serial, or nil while no sensor is paired or followed yet: a new pairing
    /// before its first authentication, after "Forget sensor" or "Stop following this sensor".
    public let serial: String?
    /// The current session's start and warm-up end, as the sensor reported them; nil without a session.
    public let sessionStart: Date?
    public let warmUpEndsAt: Date?

    public init(serial: String?, sessionStart: Date?, warmUpEndsAt: Date?) {
        self.serial = serial
        self.sessionStart = sessionStart
        self.warmUpEndsAt = warmUpEndsAt
    }

    /// - Parameters:
    ///   - session: the source's `currentSession` (authenticated, persisted across relaunches).
    ///   - storedPairing: what the app read from the source's stored pairing.
    /// - Returns: nil when neither is known (the snapshot then carries no `currentSensor`).
    public static func make(session: SensorSession?, storedPairing: StoredPairing) -> WidgetCurrentSensor? {
        if let session {
            return WidgetCurrentSensor(serial: session.serial, sessionStart: session.start, warmUpEndsAt: session.warmUpEndsAt)
        }
        switch storedPairing {
        case .notYetRead: return nil
        case .read(let serial): return WidgetCurrentSensor(serial: serial, sessionStart: nil, warmUpEndsAt: nil)
        }
    }
}

/// The app's knowledge of the source's stored pairing (`SensorDevice.storedSensorSerial`).
public enum StoredPairing: Sendable, Equatable {
    /// Not read yet (or not applicable, e.g. a DEBUG replay run): no `currentSensor` from it.
    case notYetRead
    /// Read: the stored sensor's serial, nil when none is stored (a new pairing or a forgotten sensor).
    case read(serial: String?)
}

extension WidgetSnapshot {
    /// True when `latest` is from an earlier sensor than `currentSensor`: no sensor is paired or
    /// followed yet, its serial differs, or it is dated before the current session started (S2: no
    /// reading of a session is older than its start).
    public var latestIsFromAnEarlierSensor: Bool {
        guard let current = currentSensor, let latest else { return false }
        guard let serial = current.serial else { return true }
        if let latestSerial = latestSensorSerial, latestSerial != serial { return true }
        if let start = current.sessionStart, latest.date < start { return true }
        return false
    }

    /// The latest reading the widget may show: `latest`, unless it is from an earlier sensor.
    public var shownLatest: LatestReading? {
        latestIsFromAnEarlierSensor ? nil : latest
    }

    /// The sensor state for the display rules. While the current session's warm-up is known, a state
    /// in which readings would be judged by age alone (searching, connecting, authenticating,
    /// active, Bluetooth unavailable, a transient failure) counts as that warm-up, so a relaunch
    /// during warm-up keeps showing "Warming up". Past the warm-up end `classify` treats it as before.
    public var displaySensorState: SensorState {
        guard let endsAt = currentSensor?.warmUpEndsAt, WidgetSensorKey(sensorState) == .readingsByAge else { return sensorState }
        return .warmingUp(endsAt: endsAt)
    }
}
