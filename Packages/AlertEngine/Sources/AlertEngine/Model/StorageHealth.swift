// The plain status input for the storage-failure alert (PROGRESS.md D42, S5). The app maps the
// GlucoseStore's open/insert outcome into this; AlertEngine does not depend on GlucoseStore.

import Foundation

public enum StorageHealth: Sendable, Equatable, Hashable, Codable {
    /// The last open/insert succeeded.
    case ok
    /// Opening the store or inserting readings has failed every time since `since` (e.g. the disk
    /// is full). Readings still reach alerts and Trio (D42); history is not being saved. Alerts
    /// once this has lasted `AlertLimits.storageFailingMinutes`.
    case failing(since: Date)
}
