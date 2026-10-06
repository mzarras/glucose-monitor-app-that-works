// Reads and writes the widget snapshot file in the App Group container (HANDOFF §4.5, §7.4).
//
// File protection: `completeUntilFirstUserAuthentication`, not `complete`. The app writes while
// the phone is locked (BLE wakes it in the background) and the widget reads while locked; with
// `complete` both would fail silently after the phone locks (HANDOFF §4.5). Writes are atomic
// (temp file + rename) so the widget never reads a half-written file.

import Foundation

public struct WidgetSnapshotStore: Sendable {
    public static let fileName = "widget-snapshot.json"

    /// Options for every write. Asserted in `WidgetSnapshotStoreTests`.
    public static var writingOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        // Host tests (macOS) have no data-protection classes; atomicity still applies.
        return [.atomic]
        #endif
    }

    public enum StoreError: Error, Equatable {
        /// The file was written by a newer (or older, incompatible) app version.
        case unsupportedSchemaVersion(Int)
    }

    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// The store in the App Group container, or `nil` if the group is not configured for this
    /// process (missing entitlement or Info.plist `AppGroupID`).
    public init?(appGroupID: String) {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return nil
        }
        self.init(directory: container)
    }

    /// Reads Info.plist key `AppGroupID` (set from `$(APP_GROUP_ID)` in both targets).
    public static func appGroupID(in bundle: Bundle = .main) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: "AppGroupID") as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    public func write(_ snapshot: WidgetSnapshot) throws {
        let data = try Self.encoder().encode(snapshot)
        try data.write(to: fileURL, options: Self.writingOptions)
    }

    /// `nil` when no snapshot has been written yet.
    public func read() throws -> WidgetSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try Self.decode(data)
    }

    /// For the widget: the snapshot, or nil for any problem — no file yet, unreadable, empty,
    /// truncated or corrupt JSON, another schema version. The timeline shows nil as "No data",
    /// never as a number.
    public func readOrNil() -> WidgetSnapshot? {
        try? read()
    }

    /// The widget's read path: App Group from Info.plist `AppGroupID`, then `readOrNil()`.
    public static func snapshotForWidget(bundle: Bundle = .main) -> WidgetSnapshot? {
        guard let groupID = appGroupID(in: bundle), let store = WidgetSnapshotStore(appGroupID: groupID) else { return nil }
        return store.readOrNil()
    }

    public static func decode(_ data: Data) throws -> WidgetSnapshot {
        let snapshot = try decoder().decode(WidgetSnapshot.self, from: data)
        guard snapshot.schemaVersion == WidgetSnapshot.currentSchemaVersion else {
            throw StoreError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }
        return snapshot
    }

    /// Dates as integer milliseconds since 1970 (the same unit as Nightscout `date` and the
    /// imported-reading ids). Sub-millisecond precision is dropped, which nothing displays.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
