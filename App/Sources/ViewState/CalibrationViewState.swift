// Sensor calibration (PROGRESS D16). A calibration is a fingerstick value the sensor applies; it
// is never a reading, never plotted as glucose, and the app does no calibration math (S1).
// Phase 2 fills this from the CalibratingCGMSource; submissions go through CalibrationActions.

import Foundation
import GlucoseCore
import WidgetCore

struct CalibrationViewState: Equatable, Sendable {
    var sensorState: SensorState
    /// The newest live reading, for the difference check and the steady-trend advice.
    var latestLiveReading: LatestReading?
    /// `CalibratingCGMSource.acceptedCalibrationRange`; nil if the source cannot calibrate.
    var acceptedRange: ClosedRange<Int>?
    /// The most recent submission and what happened to it.
    var lastSubmission: CalibrationSubmission?
    /// Review N1: same latch as `NowViewState.clockMismatchLatchedFor`; while set for the latest
    /// reading there is no current reading to compare with.
    var clockMismatchLatchedFor: Date? = nil
    /// D45: listening alongside the Dexcom app; this app sends nothing to the sensor, so
    /// calibration happens in the Dexcom app.
    var listening: Bool = false

    static let unavailable = CalibrationViewState(sensorState: .notPaired, latestLiveReading: nil, acceptedRange: nil, lastSubmission: nil)
}

struct CalibrationSubmission: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// The source refused it; nothing was queued.
        case refused(CalibrationRefusal)
        /// Queued/sent/accepted/rejected/unknown, as reported by the source.
        case status(CalibrationStatus)
    }

    var request: CalibrationRequest
    var outcome: Outcome
    /// When `outcome` last changed.
    var updatedAt: Date
}

extension CalibrationStatus {
    /// Still waiting for the sensor.
    var isPending: Bool {
        switch self {
        case .queued, .sent: return true
        case .accepted, .rejected, .unknown: return false
        }
    }
}
