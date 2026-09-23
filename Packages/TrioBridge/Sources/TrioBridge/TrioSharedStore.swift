// Where the bridge writes: the UserDefaults suite of Trio's App Group. A protocol so tests inject a
// store (including a failing one) instead of touching a real App Group.

import Foundation

/// Storage the bridge writes Trio's contract into. Implementations must be safe to call from any thread.
public protocol TrioSharedStore: Sendable {
    /// Throws `TrioBridgeError.appGroupUnavailable` when this app cannot use the App Group. Called
    /// before every write so a lost entitlement surfaces as a bridge failure (S5) instead of writes that
    /// land somewhere Trio never reads.
    func checkAccess() throws(TrioBridgeError)
    func data(forKey key: String) -> Data?
    func setData(_ data: Data, forKey key: String)
    func string(forKey key: String) -> String?
    func setString(_ value: String, forKey key: String)
    func removeValue(forKey key: String)
}

/// The production store: `UserDefaults(suiteName: <Trio App Group ID>)`, exactly what Trio reads
/// (`Trio/Sources/APS/CGM/AppGroupSource.swift:34-35`, suite name from Info.plist `AppGroupID`, `:122-125`).
///
/// It keeps only the group ID and opens the suite on each call, so it holds no non-`Sendable` state
/// (`UserDefaults` is explicitly not `Sendable`). Opening a suite is cheap and all instances for one
/// suite share the same backing store; the bridge writes about once every five minutes.
public struct AppGroupUserDefaultsStore: TrioSharedStore {
    /// Trio's App Group ID, e.g. `group.org.nightscout.ABCDE12345.trio.trio-app-group`. The app passes the
    /// value of its Info.plist key `TrioAppGroupID` (`App/Info.plist`, from `TRIO_APP_GROUP_ID`).
    public let appGroupID: String
    private let containerExists: @Sendable (String) -> Bool
    private let openSuite: @Sendable (String) -> UserDefaults?

    public init(appGroupID: String) {
        self.init(
            appGroupID: appGroupID,
            containerExists: Self.appGroupContainerExists,
            openSuite: { UserDefaults(suiteName: $0) }
        )
    }

    /// Test seam: `containerExists` replaces the entitlement check and `openSuite` maps the group ID to a
    /// throwaway suite, so tests never create a real App Group container on the host.
    init(
        appGroupID: String,
        containerExists: @escaping @Sendable (String) -> Bool,
        openSuite: @escaping @Sendable (String) -> UserDefaults?
    ) {
        self.appGroupID = appGroupID
        self.containerExists = containerExists
        self.openSuite = openSuite
    }

    public func checkAccess() throws(TrioBridgeError) {
        guard TrioAppGroupContract.isValidTrioAppGroupID(appGroupID) else {
            throw .appGroupUnavailable(groupID: appGroupID, reason: .invalidGroupID)
        }
        // On iOS this is nil unless the app's entitlements include the group. Without the entitlement,
        // `UserDefaults(suiteName:)` still succeeds but writes to a private suite Trio cannot see.
        guard containerExists(appGroupID) else {
            throw .appGroupUnavailable(groupID: appGroupID, reason: .notEntitled)
        }
        guard openSuite(appGroupID) != nil else {
            throw .appGroupUnavailable(groupID: appGroupID, reason: .suiteUnavailable)
        }
    }

    public func data(forKey key: String) -> Data? {
        openSuite(appGroupID)?.data(forKey: key)
    }

    public func setData(_ data: Data, forKey key: String) {
        openSuite(appGroupID)?.set(data, forKey: key)
    }

    public func string(forKey key: String) -> String? {
        openSuite(appGroupID)?.string(forKey: key)
    }

    public func setString(_ value: String, forKey key: String) {
        openSuite(appGroupID)?.set(value, forKey: key)
    }

    public func removeValue(forKey key: String) {
        openSuite(appGroupID)?.removeObject(forKey: key)
    }

    /// True when the OS grants this process the App Group's container, i.e. the entitlement is present.
    static func appGroupContainerExists(_ groupID: String) -> Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil
    }
}
