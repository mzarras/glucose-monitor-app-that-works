// Original to Sensor (no ported code).

import Foundation
import os

/// Keeps the pairing record in memory only. For tests and previews; never for a real sensor.
public final class G7InMemoryCredentialStore: G7CredentialStore {
    private let record: OSAllocatedUnfairLock<G7PairingRecord?>

    public init(_ initial: G7PairingRecord? = nil) {
        record = OSAllocatedUnfairLock(initialState: initial)
    }

    public func load() throws -> G7PairingRecord? {
        record.withLock { $0 }
    }

    public func save(_ newRecord: G7PairingRecord) throws {
        record.withLock { $0 = newRecord }
    }

    public func delete() throws {
        record.withLock { $0 = nil }
    }
}
