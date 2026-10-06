// Original to Sensor (no ported code).
// Upload health for Settings and the S5 banner (HANDOFF §8A step 1: "Settings shows last upload
// and failure count; failures raise the S5 banner").

import Foundation

public struct UploadStatus: Sendable, Equatable {
    public let destination: String
    /// Last time a batch was accepted. Persisted with the queue, so it survives relaunch.
    public var lastSuccessAt: Date?
    public var lastAttemptAt: Date?
    /// Failed attempts since the last success. Non-zero means "failing" (S5 banner). Persisted with
    /// the queue, so a relaunch keeps the banner and the backoff.
    public var consecutiveFailures = 0
    /// Failed attempts since launch.
    public var totalFailures = 0
    /// The most recent error, kept after recovery for Settings; `isFailing` says whether it is
    /// current. Persisted with the queue.
    public var lastError: UploadError?
    public var lastErrorAt: Date?
    /// Readings waiting to be uploaded.
    public var queueDepth = 0
    /// When the next automatic attempt is allowed (`flushIfDue`), `nil` if not backing off.
    /// Persisted with the queue, so relaunching the app does not bypass the backoff (a rejected
    /// Share password must not be retried on every launch: account lockout).
    public var nextAttemptAt: Date?
    /// Readings refused by `LiveReadingGate` (S2/S6) since launch. Non-zero means a caller tried to
    /// upload a non-live or invalid reading — a bug upstream, logged to diagnostics.
    public var refusedByGate = 0
    /// Valid readings this destination cannot represent faithfully (S4).
    public var notRepresentable = 0
    /// The most recent refusal (gate or representation) and when it happened.
    public var lastRefusal: UploadRefusal?
    public var lastRefusedAt: Date?
    /// Refusals since the last successful upload. Non-zero means readings are being refused and
    /// nothing has gone through since (S5 banner); the next upload success clears it.
    public var refusalsSinceLastSuccess = 0
    /// Queued readings dropped without upload: older than the destination accepts, over capacity,
    /// not `.sensor`, or dated in the future / before 1970 (a corrupted queue or a clock moved
    /// back). Each drop is logged to diagnostics.
    public var discarded = 0
    /// The queue file was unreadable at launch and was moved aside; readings in it were not sent.
    /// Stays set until relaunch.
    public var queueLoadProblem: String?
    /// The last queue save failed; queued readings are only in memory until a save succeeds.
    public var queueSaveProblem: String?

    public init(destination: String) {
        self.destination = destination
    }

    /// True when uploads are not getting through (S5: surface in the UI): the last attempt failed,
    /// readings were refused with no success since, or the queue file has a problem.
    public var isFailing: Bool {
        consecutiveFailures > 0 || refusalsSinceLastSuccess > 0 || queueLoadProblem != nil || queueSaveProblem != nil
    }
}
