// Writes the widget snapshot to the App Group and asks WidgetKit to reload (HANDOFF §7.4).
// Phase 2 calls `publish` after every committed store change and every sensor state change.

import Foundation
import GlucoseCore
import WidgetCore
import WidgetKit

@MainActor
struct WidgetSnapshotPublisher {
    let store: WidgetSnapshotStore

    /// Nil when the App Group is not available to this build (missing entitlement or
    /// Info.plist `AppGroupID`); Phase 2 reports that through the diagnostic log.
    static func appGroup() -> WidgetSnapshotPublisher? {
        guard let id = WidgetSnapshotStore.appGroupID(), let store = WidgetSnapshotStore(appGroupID: id) else { return nil }
        return WidgetSnapshotPublisher(store: store)
    }

    /// - Parameter readings: stored readings covering at least the last 3 hours (any source; the
    ///   snapshot picks the current value from live readings only).
    func publish(readings: [GlucoseReading], sensorState: SensorState, accent: AccentChoice, now: Date) throws {
        let snapshot = WidgetSnapshot.make(readings: readings, sensorState: sensorState, accent: accent, now: now)
        try store.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
