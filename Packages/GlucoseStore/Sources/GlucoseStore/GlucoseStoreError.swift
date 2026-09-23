// Errors thrown by GlucoseStore. Every failure is thrown to the caller (S5: fail loud).

public enum GlucoseStoreError: Error, Sendable, Equatable {
    /// The database was written by a newer version of the app (it contains migrations this version
    /// does not know). The store refuses to open it rather than write into an unknown schema.
    case databaseFromNewerAppVersion(unknownMigrations: [String])
    /// `GlucoseStore.replay(at:)` was pointed at a file that holds sensor or imported readings
    /// (most likely the production database). Refused so the two roles never share a file.
    case replayStoreFileContainsLiveData(rowCount: Int)
    /// A stored row could not be decoded. Never happens for rows this code wrote (CHECK constraints).
    case unreadableRow(id: String, column: String)
}
