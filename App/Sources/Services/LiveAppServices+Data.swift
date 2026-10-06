// Data in the live services (HANDOFF §4.5, §11 step 6): retention and its daily purge, the Settings
// summary, "Export all data (CSV)" and "Export diagnostics". Always the production database.

import Foundation
import GlucoseCore
import GlucoseStore

extension LiveAppServices {
    func setRetention(_ policy: RetentionPolicy) async {
        preferences.retention = policy
        storage.retention = policy
        send(.storage)
        await purge()
    }

    /// Runs the retention purge when the last one is more than a day old (at launch and foreground).
    func purgeIfDue() async {
        if let last = preferences.lastPurgeAt, abs(now().timeIntervalSince(last)) < 86_400 { return }
        await purge()
    }

    private func purge() async {
        guard let store = productionStore else { return }
        do {
            let removed = try await store.purge(keeping: storage.retention)
            let purgedAt = now()
            preferences.lastPurgeAt = purgedAt
            storage.lastPurgeAt = purgedAt
            storage.lastPurgeRemoved = removed
            log(.store, "retention \(storage.retention.rawValue): removed \(removed) reading(s)")
            send(.storage)
            if removed > 0 { await refreshStorageSummary() }
        } catch {
            log(.store, "retention purge failed: \(error)")
        }
    }

    func refreshStorageSummary() async {
        guard let store = productionStore else { return }
        do {
            storage.summary = try await store.summary()
            send(.storage)
        } catch {
            log(.store, "summary failed: \(error)")
        }
    }

    func exportAllReadingsCSV() async throws -> URL {
        guard let store = productionStore else { throw StoreNotOpen() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppIdentity.displayName)-readings-\(Self.fileStamp()).csv")
        let count = try await store.exportCSV(to: url)
        log(.store, "exported \(count) reading(s) to CSV")
        return url
    }

    func exportDiagnostics() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppIdentity.displayName)-diagnostics-\(Self.fileStamp()).txt")
        try diagnostics.exportText().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
