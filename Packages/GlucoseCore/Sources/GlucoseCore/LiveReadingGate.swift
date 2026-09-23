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
        /// S2: a numeric value outside `GlucoseValue.sensorReportableRange`. The sensor reports
        /// anything it cannot measure as LOW/HIGH, so a number outside 40...400 means a parse or
        /// transport fault (e.g. 0 or 4095 from a misread packet), never a real glucose value.
        case implausibleValue(Int)
        /// S2: a trend rate that is NaN or infinite — a parse fault; it would also corrupt JSON
        /// encoding and equality downstream.
        case nonFiniteTrendRate
        /// S2: the session itself is malformed (empty serial, or dates out of order), so no
        /// reading can be checked against it.
        case malformedSession
    }

    /// How far after `now` a reading's derived date may be. Reading dates are derived by anchoring
    /// the sensor's clock (1-second resolution) to the phone's clock at each connection (S3). The
    /// tolerance absorbs that resolution, message latency, and a small phone clock correction
    /// (e.g. an NTP step) between anchoring and validation. It cannot make a stale reading look
    /// fresh in any way that matters: every staleness threshold in the app is ≥ 10 minutes.
    /// Anything later than this is a clock fault and is refused.
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
        if case .mgdl(let value) = reading.value, !GlucoseValue.sensorReportableRange.contains(value) {
            throw .implausibleValue(value)
        }
        if let rate = reading.trendRate, !rate.isFinite { throw .nonFiniteTrendRate }
        guard let session else { throw .noSession }
        guard session.isWellFormed else { throw .malformedSession }
        guard reading.sensorSerial == session.serial else {
            throw .serialMismatch(readingSerial: reading.sensorSerial, sessionSerial: session.serial)
        }
        guard reading.date >= session.start else { throw .beforeSessionStart }
        guard reading.date >= session.warmUpEndsAt else { throw .duringWarmUp }
        guard reading.date <= session.gracePeriodEndsAt else { throw .afterSessionEnd }
        guard reading.date <= now.addingTimeInterval(futureTolerance) else { throw .inFuture }
    }
}
