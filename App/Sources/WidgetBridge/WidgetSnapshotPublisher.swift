// Writes the widget snapshot to the App Group and asks WidgetKit to reload (HANDOFF §7.4).
// Phase 2 calls `publish` after every committed store change and every sensor state change.
// D61: the file is written every time (cheap; keeps `writtenAt` fresh for the widget's own reload
// and its clock check), but WidgetKit is asked to reload only when `WidgetReloadKey` changes;
// `LiveWidgetPublisher` keeps that bookkeeping.

import Foundation
import GlucoseCore
import WidgetCore
import WidgetKit

@MainActor
struct WidgetSnapshotPublisher {
    let store: WidgetSnapshotStore
    /// Asks WidgetKit to rebuild every timeline of this app's widgets. Replaced in tests.
    let reloadTimelines: @MainActor () -> Void

    init(store: WidgetSnapshotStore, reloadTimelines: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadAllTimelines() }) {
        self.store = store
        self.reloadTimelines = reloadTimelines
    }

    /// Nil when the App Group is not available to this build (missing entitlement or
    /// Info.plist `AppGroupID`); Phase 2 reports that through the diagnostic log.
    static func appGroup() -> WidgetSnapshotPublisher? {
        guard let id = WidgetSnapshotStore.appGroupID(), let store = WidgetSnapshotStore(appGroupID: id) else { return nil }
        return WidgetSnapshotPublisher(store: store)
    }

    /// Builds and writes the snapshot; returns what was written.
    /// - Parameters:
    ///   - latestLive: `GlucoseReadingRepository.latestLiveReading()`, however old.
    ///   - previousLive: the live reading just before it (for the delta), if any.
    ///   - recent: stored readings from `WidgetSnapshot.chartWindowStart` to now, any source (chart only).
    func write(latestLive: GlucoseReading?, previousLive: GlucoseReading?, recent: [GlucoseReading],
               sensorState: SensorState, accent: AccentChoice, now: Date) throws -> WidgetSnapshot {
        let snapshot = WidgetSnapshot.make(latestLive: latestLive, previousLive: previousLive, recent: recent,
                                           sensorState: sensorState, accent: accent, now: now)
        try store.write(snapshot)
        return snapshot
    }
}
