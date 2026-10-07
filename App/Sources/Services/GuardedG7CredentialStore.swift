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

import Foundation
import G7Kit

final class GuardedG7CredentialStore: G7CredentialStore, @unchecked Sendable {
    // @unchecked Sendable: `allowedDeletions` and `refusal` are only touched while holding `lock`;
    // `inner` is Sendable.
    private let inner: any G7CredentialStore
    private let lock = NSLock()
    private var allowedDeletions = 0
    private var refusal: String?

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

    /// The latest refused deletion (nil: none since `clearRefusal()`).
    var refusedDeletion: String? { lock.withLock { refusal } }

    func clearRefusal() { lock.withLock { refusal = nil } }
}
