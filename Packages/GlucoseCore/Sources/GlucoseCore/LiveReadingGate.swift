// Contract (S2, S6). Owned by the orchestrator; change only through PROGRESS.md.
//
// Every consumer that acts on live data — TrioBridge, every uploader, the alert engine — must call
// `LiveReadingGate.validate` immediately before acting, and must have its own test proving it
// refuses a rejected reading. The CGM source is the first line of defence (it never emits a
// warm-up or error reading); this gate is the second.

import Foundation

public enum LiveReadingGate {
    /// Why a reading was refused.
    public enum Rejection: Error, Sendable, Equatable {
        /// S6: only `.sensor` readings reach Trio, alerts, or uploads.
        case notLiveSensor(ReadingSource)
        /// S2: no authenticated session is known.
        case noSession
        /// S2: the reading's serial does not match the authenticated session.
        case serialMismatch(readingSerial: String, sessionSerial: String)
        /// S2/S3: timestamp earlier than the session start.
        case beforeSessionStart
        /// S2: timestamp inside the warm-up window.
        case duringWarmUp
        /// S2: timestamp after the grace period ended (sensor expired).
        case afterSessionEnd
        /// S2: timestamp later than `now + futureTolerance`.
        case inFuture
    }

    /// Allowed clock skew between a derived reading time and the phone's clock. Reading dates are
    /// derived from the sensor-reported session age at connection time (S3), so only rounding
    /// separates them from `now`; anything beyond this is a clock problem and is refused.
    public static let futureTolerance: TimeInterval = 60

    /// Refuses the reading unless it is a live sensor reading that is plausible for `session` at `now`.
    public static func validate(_ reading: GlucoseReading, session: SensorSession?, now: Date) throws(Rejection) {
        guard reading.source.isLiveSensor else { throw .notLiveSensor(reading.source) }
        try validateAgainstSession(reading, session: session, now: now)
    }

    #if DEBUG
    /// DEBUG builds only: like `validate`, but also accepts `.replay` readings. Exists so the alert
    /// engine can be exercised end to end on ReplayKit scenarios (HANDOFF §10 gate 4, §11 step 1).
    /// TrioBridge and uploaders must never call this. `.imported` and `.mock` are still refused.
    public static func validateAllowingReplay(_ reading: GlucoseReading, session: SensorSession?, now: Date) throws(Rejection) {
        switch reading.source {
        case .sensor, .replay: break
        case .imported, .mock: throw .notLiveSensor(reading.source)
        }
        try validateAgainstSession(reading, session: session, now: now)
    }
    #endif

    private static func validateAgainstSession(_ reading: GlucoseReading, session: SensorSession?, now: Date) throws(Rejection) {
        guard let session else { throw .noSession }
        guard reading.sensorSerial == session.serial else {
            throw .serialMismatch(readingSerial: reading.sensorSerial, sessionSerial: session.serial)
        }
        guard reading.date >= session.start else { throw .beforeSessionStart }
        guard reading.date >= session.warmUpEndsAt else { throw .duringWarmUp }
        guard reading.date <= session.gracePeriodEndsAt else { throw .afterSessionEnd }
        guard reading.date <= now.addingTimeInterval(futureTolerance) else { throw .inFuture }
    }
}
