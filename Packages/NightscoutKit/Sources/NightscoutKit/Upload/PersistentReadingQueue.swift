// Original to Sensor (no ported code).
// File-backed FIFO of readings waiting for upload (HANDOFF §8A: "Queue and retry offline").
//
// One JSON file per destination in a directory the app passes in. Every change rewrites the file
// atomically. On iOS the file is `completeUntilFirstUserAuthentication`: readings arrive and are
// queued while the phone is locked (HANDOFF §4.5 "File protection"); `complete` would make every
// locked-phone write fail.

import Foundation
import GlucoseCore

struct PersistentReadingQueue {
    struct Item: Codable, Equatable, Sendable {
        let reading: GlucoseReading
        let enqueuedAt: Date
    }

    /// Upload health that must survive a relaunch: the S5 banner (`isFailing`) and the backoff,
    /// so relaunching never retries a rejected password early (account lockout).
    struct RetryState: Codable, Equatable, Sendable {
        var consecutiveFailures = 0
        var nextAttemptAt: Date?
        var lastError: UploadError?
        var lastErrorAt: Date?
    }

    /// On-disk format. `lastSuccessAt` and `retry` live here so Settings, the S5 banner and the
    /// backoff are right after a relaunch. Both are optional so older files still load.
    private struct FileContents: Codable {
        var version: Int
        var items: [Item]
        var lastSuccessAt: Date?
        var retry: RetryState?
    }

    private static let fileVersion = 1
    /// About 34 days of 5-minute readings; beyond that the oldest are dropped (and counted).
    static let capacity = 10_000

    let fileURL: URL
    private(set) var items: [Item] = []
    private(set) var lastSuccessAt: Date?
    var retry = RetryState()

    /// Loads the queue. An unreadable file is moved aside (kept for diagnostics, never deleted)
    /// and the queue starts empty; the returned problem must be surfaced (S5).
    static func load(fileURL: URL, now: Date) -> (queue: PersistentReadingQueue, problem: String?) {
        var queue = PersistentReadingQueue(fileURL: fileURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return (queue, nil) }
        do {
            let data = try Data(contentsOf: fileURL)
            let contents = try JSONDecoder().decode(FileContents.self, from: data)
            guard contents.version == fileVersion else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "unknown queue version \(contents.version)"])
            }
            queue.items = contents.items
            queue.lastSuccessAt = contents.lastSuccessAt
            queue.retry = contents.retry ?? RetryState()
            return (queue, nil)
        } catch {
            let aside = fileURL.appendingPathExtension("unreadable-\(Int(now.timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            return (queue, "Upload queue file was unreadable and was moved to \(aside.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var count: Int { items.count }

    // Mutations change memory only; the owner calls `save()` after each one and surfaces a failed
    // save (the queued readings are still uploaded from memory in that case).

    /// Appends unless a reading with the same id is already queued. Returns the oldest items dropped
    /// to stay within `capacity`.
    mutating func append(_ reading: GlucoseReading, at date: Date) -> (appended: Bool, dropped: [Item]) {
        guard !items.contains(where: { $0.reading.id == reading.id }) else { return (false, []) }
        items.append(Item(reading: reading, enqueuedAt: date))
        guard items.count > Self.capacity else { return (true, []) }
        let dropped = Array(items.prefix(items.count - Self.capacity))
        items.removeFirst(dropped.count)
        return (true, dropped)
    }

    /// Removes the items for which `shouldRemove` is true and returns them.
    mutating func removeAll(where shouldRemove: (Item) -> Bool) -> [Item] {
        let removed = items.filter(shouldRemove)
        items.removeAll(where: shouldRemove)
        return removed
    }

    mutating func recordSuccess(at date: Date) {
        lastSuccessAt = date
    }

    func save() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(FileContents(version: Self.fileVersion, items: items, lastSuccessAt: lastSuccessAt, retry: retry))
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: [.atomic])
        #endif
    }
}
