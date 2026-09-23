// Session shape and reading construction shared by the scripted scenarios and the Nightscout
// replay. DEBUG only (S6): compiled out of Release.
#if DEBUG
import Foundation
import GlucoseCore

/// A G7 10-day sensor session, for replay.
public enum G7ReplaySession {
    /// G7 warm-up: 30 minutes. xDrip4iOS 7.1.0, xdrip/Constants/ConstantsMaster.swift:17
    /// (`minimumSensorWarmUpRequiredInMinutesDexcomG7 = 30`).
    public static let warmUp: TimeInterval = 30 * 60
    /// Rated life: 10 days. xDrip4iOS 7.1.0, xdrip/Constants/ConstantsDexcomG7.swift:14-15
    /// ("10 days + a 12 hour grace period = 10.5 days").
    public static let ratedLife: TimeInterval = 10 * 86_400
    /// Grace period after the rated life: 12 hours (same source).
    public static let gracePeriod: TimeInterval = 12 * 3_600

    public static func session(serial: String, start: Date) -> SensorSession {
        SensorSession(
            serial: serial,
            start: start,
            warmUpEndsAt: start.addingTimeInterval(warmUp),
            expiresAt: start.addingTimeInterval(ratedLife),
            gracePeriodEndsAt: start.addingTimeInterval(ratedLife + gracePeriod)
        )
    }
}

/// Builds `.replay` readings for one timeline. The id is derived exactly as G7Kit derives a live
/// one (`GlucoseReading.sensorID`): serial plus seconds since the session start, so a backfilled
/// copy of a reading gets the same id and ids do not depend on the wall clock (S3).
struct ReplayReadingFactory {
    let origin: Date
    let session: SensorSession

    /// A reading dated `minute` minutes after the origin.
    func reading(minute: Int, _ value: GlucoseValue, trend: Double?, isBackfill: Bool = false) -> GlucoseReading {
        reading(at: origin.addingTimeInterval(TimeInterval(minute) * 60), value, trend: trend, isBackfill: isBackfill)
    }

    func reading(at date: Date, _ value: GlucoseValue, trend: Double?, isBackfill: Bool = false) -> GlucoseReading {
        let secondsIntoSession = date.timeIntervalSince(session.start).rounded()
        precondition(secondsIntoSession >= 0 && secondsIntoSession <= TimeInterval(UInt32.max), "reading outside its session")
        return GlucoseReading(
            id: GlucoseReading.sensorID(serial: session.serial, sensorTimestamp: UInt32(secondsIntoSession)),
            date: date,
            value: value,
            trendRate: trend,
            isBackfill: isBackfill,
            source: .replay,
            sensorSerial: session.serial
        )
    }

    /// For replayed history whose timestamps are not on whole seconds (a Nightscout export carries
    /// milliseconds): id = `<serial>:<milliseconds since session start>`, so two entries less than
    /// a second apart get distinct ids instead of colliding and being dropped as re-deliveries.
    /// Not the G7 id format (seconds); used only by NightscoutReplaySource.
    func readingWithMillisecondID(at date: Date, _ value: GlucoseValue, trend: Double?) -> GlucoseReading {
        let millisecondsIntoSession = (date.timeIntervalSince(session.start) * 1000).rounded()
        precondition(millisecondsIntoSession >= 0, "reading before its session")
        return GlucoseReading(
            id: "\(session.serial):\(Int64(millisecondsIntoSession))",
            date: date,
            value: value,
            trendRate: trend,
            isBackfill: false,
            source: .replay,
            sensorSerial: session.serial
        )
    }
}
#endif
