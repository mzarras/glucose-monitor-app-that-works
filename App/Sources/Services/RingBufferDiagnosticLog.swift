// The app's `DiagnosticLog` (HANDOFF §11 step 6, "Export diagnostics"): every module records BLE
// state transitions, reading decisions, bridge writes, uploads, imports and alert decisions here.
// A bounded in-memory ring, saved to a file in Application Support when the app goes to the
// background and every 100 events, and read back at launch, so the events before an iOS relaunch
// survive. No secrets are ever recorded (modules log no tokens, passwords or pairing codes); the
// only personal data is readings.

import Foundation
import GlucoseCore

final class RingBufferDiagnosticLog: DiagnosticLog, @unchecked Sendable {
    // @unchecked Sendable: `events` and `unsavedCount` are only read and written while holding `lock`.
    private let lock = NSLock()
    /// Saves run here, never on the recording thread (G7Kit records on its Bluetooth queue).
    private let saveQueue = DispatchQueue(label: "com.mzarras.sensor.diagnostics.save", qos: .utility)
    private var events: [DiagnosticEvent] = []
    private var unsavedCount = 0
    /// `save()` never runs before `loadSaved()`, so the previous process's file is read before it is replaced.
    private var hasLoadedSaved = false
    let capacity: Int
    /// Where `save()` writes; nil keeps the log in memory only (tests).
    let fileURL: URL?

    init(capacity: Int = 5_000, fileURL: URL?) {
        self.capacity = capacity
        self.fileURL = fileURL
    }

    func record(_ event: DiagnosticEvent) {
        let shouldSave = lock.withLock { () -> Bool in
            events.append(event)
            // Trim in chunks so appending stays amortised O(1).
            if events.count > capacity + capacity / 10 {
                events.removeFirst(events.count - capacity)
            }
            unsavedCount += 1
            return unsavedCount >= 100
        }
        if shouldSave {
            saveQueue.async { try? self.save() }
        }
    }

    var snapshot: [DiagnosticEvent] {
        lock.withLock { Array(events.suffix(capacity)) }
    }

    /// One line per event: `2026-09-23T12:00:00.000Z [ble] G7: connected`.
    func exportText() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return snapshot.map { "\(formatter.string(from: $0.date)) [\($0.category.rawValue)] \($0.message)" }.joined(separator: "\n") + "\n"
    }

    /// Writes the ring to `fileURL` (JSON, atomic, `completeUntilFirstUserAuthentication`). Fails
    /// before the first unlock after a reboot (the file is protected); the events stay in memory.
    func save() throws {
        guard let fileURL, lock.withLock({ hasLoadedSaved }) else { return }
        let (current, count) = lock.withLock { (Array(events.suffix(capacity)), unsavedCount) }
        let data = try JSONEncoder().encode(current)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        lock.withLock { unsavedCount = max(0, unsavedCount - count) }
    }

    /// Prepends what an earlier process saved (call once, at launch, after protected data is available).
    func loadSaved() {
        let saved: [DiagnosticEvent] = fileURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([DiagnosticEvent].self, from: $0) } ?? []
        lock.withLock {
            if !hasLoadedSaved { events = Array((saved + events).suffix(capacity)) }
            hasLoadedSaved = true
        }
    }
}
