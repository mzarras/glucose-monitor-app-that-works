// Contract (PROGRESS.md D16 — calibration is in v1, not in HANDOFF). Owned by the orchestrator.
//
// A calibration is a fingerstick value the user asks the *sensor* to calibrate against. It is never
// a `GlucoseReading` (S1): it is not stored, shown, sent to Trio, uploaded, or alerted on as glucose.
// The app does no calibration math; the sensor applies it and later readings reflect it.

import Foundation

/// One fingerstick value submitted for calibration.
public struct CalibrationRequest: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: UUID
    /// Fingerstick blood glucose in mg/dL.
    public let mgdl: Int
    /// When the fingerstick was taken (converted to sensor time by the source, S3).
    public let takenAt: Date

    public init(id: UUID = UUID(), mgdl: Int, takenAt: Date) {
        self.id = id
        self.mgdl = mgdl
        self.takenAt = takenAt
    }
}

/// Lifecycle of a submitted calibration, as reported by the source.
public enum CalibrationStatus: Sendable, Equatable, Hashable, Codable {
    /// Waiting for the next sensor connection (the G7 connects about every 5 minutes).
    case queued
    /// Written to the sensor; waiting for its response.
    case sent
    case accepted
    /// The sensor refused it. `code` is the sensor's rejection code (source-specific, documented
    /// by the source); `reason` is a human-readable description of that code.
    case rejected(code: Int, reason: String)
    /// The sensor answered with something the source does not recognise, or the outcome was lost.
    case unknown(description: String)
}

/// Why a source refused to accept a calibration request at all (nothing was queued).
public enum CalibrationRefusal: Error, Sendable, Equatable {
    case notPaired
    case notAuthenticated
    case warmingUp
    case sessionEnded
    /// The value is outside the range the sensor accepts (the range is source-specific).
    case valueOutOfRange(accepted: ClosedRange<Int>)
    case anotherCalibrationInProgress
}

/// A status change for one submitted calibration.
public struct CalibrationUpdate: Sendable, Equatable, Hashable, Codable {
    public let requestID: UUID
    public let status: CalibrationStatus

    public init(requestID: UUID, status: CalibrationStatus) {
        self.requestID = requestID
        self.status = status
    }
}

/// A `CGMSource` whose sensor accepts calibrations.
public protocol CalibratingCGMSource: CGMSource {
    /// The fingerstick range this sensor accepts, in mg/dL (cite the source in the implementation).
    var acceptedCalibrationRange: ClosedRange<Int> { get }
    /// Validates and queues the request; the outcome arrives on `calibrationUpdates`.
    func submitCalibration(_ request: CalibrationRequest) async throws(CalibrationRefusal)
    /// Status changes for submitted calibrations. Same stream rules as `readings`.
    var calibrationUpdates: AsyncStream<CalibrationUpdate> { get }
}
