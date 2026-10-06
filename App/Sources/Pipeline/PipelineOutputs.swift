// Where the reading pipeline delivers (docs/architecture.md "Data flow"). The composition root
// decides what is attached: the Trio bridge and the uploaders only when the user turned them on
// and, in a DEBUG build, only with the developer switch on (PROGRESS D20). Each of these consumers
// runs LiveReadingGate itself again before acting (S2, S6); the pipeline's own gate comes first.

import AlertEngine
import Foundation
import GlucoseCore
import NightscoutKit
import TrioBridge

/// Writes the widget snapshot (HANDOFF §7.4). A protocol so pipeline tests run without an App
/// Group; the app's `WidgetSnapshotPublisher` conforms (see `LiveWidgetPublisher`).
@MainActor
protocol WidgetSnapshotPublishing: AnyObject {
    /// - Parameters:
    ///   - latestLive: the latest live reading, however old.
    ///   - previousLive: the live reading just before it (delta), if any.
    ///   - recent: readings of the last 3 hours, any source (chart only).
    func publish(latestLive: GlucoseReading?, previousLive: GlucoseReading?, recent: [GlucoseReading], sensorState: SensorState, now: Date)
}

@MainActor
struct PipelineOutputs {
    /// Gets every reading that passed the gate (`.reading`), every sensor state (`.sensorState`),
    /// and a `.tick` after every drain attempt (a wake-up).
    var alerts: AlertService?
    /// The Trio path (the app's one `TrioCoordinator`); it writes nothing while the bridge is off or
    /// not allowed in this build.
    var trio: TrioCoordinator?
    /// The uploaders to submit stored readings to, read at the moment of use (Phase 2 review M2):
    /// an uploader replaced in Settings (one per queue file) is picked up without re-attaching, and
    /// the pipeline never keeps a released uploader alive. Nil or empty while uploads are off or
    /// not allowed in this build.
    var uploaders: (@MainActor () -> [ReadingUploader])?
    /// Called after readings were submitted to the uploaders: `flushIfDue` each (the upload
    /// coordinator handles `.alreadyFlushing` and background time). Nil: no flush.
    var flushUploads: (@MainActor () -> Void)?
    var widget: (any WidgetSnapshotPublishing)?
    /// Called after each sensor state was handed to the consumers (Trio heartbeat re-evaluation).
    var sensorStateProcessed: (@MainActor (SensorState) -> Void)?
    /// Called after readings were newly and durably stored (audit m1: G7Kit's backfill floor).
    var readingsStored: (@MainActor ([GlucoseReading]) -> Void)?

    init() {}
}
