// Review m2/m3: G7Kit never deletes the sensor pairing unless the person asked for it.
//
// G7Kit deletes a stored pairing record that belongs to the other connection mode when it loads it
// (`G7Controller.loadRecordForMode`) — already while the source is created, before anything is
// started. That is right when the mode really changed, and destructive when the app only *thinks* it
// did: an unreadable `SensorConnection.json` (the source is then created in the default pairing
// mode, which would drop a listen record), or a file left naming the wrong mode after a failed switch
// whose rollback could not be saved (which would drop the primary key at the next launch).
//
// This wrapper around G7Kit's Keychain store refuses `delete()` except inside
// `allowingDeletion(_:)`, which the services use only for the person's own actions: switching modes,
// "Forget sensor" / "Stop following this sensor", and choosing a mode again after a problem. A
// refused deletion leaves the record as it was; G7Kit then reports the store as unavailable and the
// services surface `connectionSettingProblem` and keep the source stopped until the person chooses.
// A mode switch (`switchingMode`) keeps a stored record that already belongs to the new mode (review
// n1): choosing the mode the pairing really is in must not cost the pairing.

import Foundation
import G7Kit

final class GuardedG7CredentialStore: G7CredentialStore, @unchecked Sendable {
    // @unchecked Sendable: `allowedDeletions` and `refusal` are only touched while holding `lock`;
    // `inner` is Sendable.
    private let inner: any G7CredentialStore
    private let lock = NSLock()
    private var allowedDeletions = 0
    private var refusal: String?
    /// While switching modes (`switchingMode`): a stored record of this kind (true: listen) is kept.
    private var keepRecordOfKind: Bool?
    private var kept: String?

    /// Thrown by `delete()` outside `allowingDeletion(_:)`.
    struct DeletionNotRequested: Error, CustomStringConvertible {
        let record: String
        var description: String { "G7Kit tried to delete the \(record) pairing record without the person asking; it was kept" }
    }

    init(wrapping inner: any G7CredentialStore) {
        self.inner = inner
    }

    func load() throws -> G7PairingRecord? { try inner.load() }

    func save(_ record: G7PairingRecord) throws { try inner.save(record) }

    func delete() throws {
        if let keep = lock.withLock({ keepRecordOfKind }), let stored = try inner.load(), stored.isListenRecord == keep {
            // Review n1: the stored pairing already belongs to the mode being switched to (the source
            // was created in the other mode because the setting was wrong): G7Kit's setMode would
            // drop it, but it is exactly what the new mode loads next.
            lock.withLock { kept = "kept the \(keep ? "listen-mode" : "pairing-mode") record of \(stored.serial ?? "no sensor yet") through the mode switch" }
            return
        }
        guard lock.withLock({ allowedDeletions > 0 }) else {
            let stored = try? inner.load()
            let kind = stored.map { $0.isListenRecord ? "listen-mode" : "pairing-mode" } ?? "stored"
            let error = DeletionNotRequested(record: kind)
            lock.withLock { refusal = error.description }
            throw error
        }
        try inner.delete()
    }

    /// Runs `body` with deletions allowed (the person's own action). Main actor: the services' actions.
    @MainActor
    func allowingDeletion<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
        lock.withLock { allowedDeletions += 1 }
        defer { lock.withLock { allowedDeletions -= 1 } }
        return try await body()
    }

    /// Runs a mode switch (`G7CGMSource.setMode`, which always deletes the stored record): deletions
    /// are allowed, except of a stored record that already belongs to the mode switched to, which is
    /// kept so the new mode resumes it (review n1). In a consistent state the stored record always
    /// belongs to the old mode and is deleted as G7Kit intends.
    @MainActor
    func switchingMode<T>(toListen listening: Bool, _ body: @MainActor () async throws -> T) async rethrows -> T {
        lock.withLock {
            keepRecordOfKind = listening
            kept = nil
        }
        defer { lock.withLock { keepRecordOfKind = nil } }
        return try await allowingDeletion(body)
    }

    /// What the last `switchingMode` kept (nil: nothing).
    var keptOnSwitch: String? { lock.withLock { kept } }

    /// The latest refused deletion (nil: none since `clearRefusal()`).
    var refusedDeletion: String? { lock.withLock { refusal } }

    func clearRefusal() { lock.withLock { refusal = nil } }
}
