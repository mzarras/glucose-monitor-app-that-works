// Factories. The role is part of the factory name so it is visible at every call site
// (GlucoseReadingRepository "Two roles", PROGRESS.md D20):
//
//   GlucoseStore.production(at:)       the app's database (app container, D25), .sensor/.imported
//   GlucoseStore.productionInMemory()  same rules, in memory: tests and SwiftUI previews
//   GlucoseStore.replay()              DEBUG only, in memory, .replay/.mock
//   GlucoseStore.replay(at:)           DEBUG only, a separate file, .replay/.mock

import Foundation
import GlucoseCore
import GRDB

extension GlucoseStore {
    /// Opens (creating if needed) the production database at `databaseURL`: migrates it, deletes
    /// any replay/mock rows, and applies `completeUntilFirstUserAuthentication` protection to the
    /// database and its -wal/-shm files (HANDOFF §4.5). The file is not excluded from backup.
    ///
    /// The app passes a file in its own container (Application Support), not the App Group
    /// container (PROGRESS.md D25); only the widget snapshot lives in the App Group.
    ///
    /// `@concurrent` so the migration and file work never run on the caller's actor.
    ///
    /// - Parameters:
    ///   - observesSuspensionNotifications: passed to GRDB. Not needed in the app's own container
    ///     (default false). Only a database in a shared (App Group) container needs it, together
    ///     with `Database.suspendNotification` / `resumeNotification` posted around suspension, to
    ///     avoid the 0xDEAD10CC termination (docs/storage.md).
    ///   - now: clock for diagnostics and retention; injected in tests.
    @concurrent
    public static func production(
        at databaseURL: URL,
        diagnostics: any DiagnosticLog = NullDiagnosticLog(),
        fileProtection: any FileProtectionApplying = SystemFileProtection(),
        observesSuspensionNotifications: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> GlucoseStore {
        try openFile(
            role: .production, at: databaseURL, diagnostics: diagnostics, fileProtection: fileProtection,
            observesSuspensionNotifications: observesSuspensionNotifications, now: now
        )
    }

    /// An empty in-memory production store (same schema and rules as on disk), for tests and
    /// SwiftUI previews.
    public static func productionInMemory(
        diagnostics: any DiagnosticLog = NullDiagnosticLog(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> GlucoseStore {
        try GlucoseStore(role: .production, writer: DatabaseQueue(), databaseURL: nil, diagnostics: diagnostics, now: now)
    }

    #if DEBUG
    /// DEBUG only: an empty in-memory replay store for a ReplayKit run. Stores only `.replay` and
    /// `.mock` readings; never the app's production database.
    public static func replay(
        diagnostics: any DiagnosticLog = NullDiagnosticLog(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> GlucoseStore {
        try GlucoseStore(role: .replay, writer: DatabaseQueue(), databaseURL: nil, diagnostics: diagnostics, now: now)
    }

    /// DEBUG only: a replay store in its own file (e.g. to keep a replay run across launches).
    /// Must not be the production file: opening a file that holds `.sensor`/`.imported` rows throws
    /// `GlucoseStoreError.replayStoreFileContainsLiveData` and changes nothing.
    @concurrent
    public static func replay(
        at databaseURL: URL,
        diagnostics: any DiagnosticLog = NullDiagnosticLog(),
        fileProtection: any FileProtectionApplying = SystemFileProtection(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> GlucoseStore {
        try openFile(
            role: .replay, at: databaseURL, diagnostics: diagnostics, fileProtection: fileProtection,
            observesSuspensionNotifications: false, now: now
        )
    }
    #endif

    private static func openFile(
        role: StoreRole,
        at databaseURL: URL,
        diagnostics: any DiagnosticLog,
        fileProtection: any FileProtectionApplying,
        observesSuspensionNotifications: Bool,
        now: @escaping @Sendable () -> Date
    ) throws -> GlucoseStore {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var configuration = Configuration()
        configuration.label = "GlucoseStore"
        configuration.observesSuspensionNotifications = observesSuspensionNotifications
        // DatabasePool = WAL mode: the UI can read while a background write is in progress.
        let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        let store = try GlucoseStore(role: role, writer: pool, databaseURL: databaseURL, diagnostics: diagnostics, now: now)

        // After migration all three files exist (WAL mode creates -wal and -shm on the first write).
        for file in databaseFiles(for: databaseURL) {
            if FileManager.default.fileExists(atPath: file.path) {
                try fileProtection.apply(StoreFileProtection.required, toItemAt: file)
            } else {
                diagnostics.record(DiagnosticEvent(
                    date: now(), category: .store,
                    message: "File protection: \(file.lastPathComponent) did not exist at open; SQLite will create it with the app's default protection class"
                ))
            }
        }
        return store
    }

    /// The database file and its WAL companions (SQLite appends "-wal" and "-shm" to the path).
    static func databaseFiles(for databaseURL: URL) -> [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
    }
}
