// Data protection for the database files (HANDOFF §4.5 "File protection").
//
// BLE wakes the app in the background while the phone is locked and it must write readings then.
// With `.complete` protection those writes fail once the phone locks, and nothing tells the user.
// `.completeUntilFirstUserAuthentication` keeps the files readable and writable after the first
// unlock following a reboot, which is what background BLE needs.
//
// This is a seam: host tests inject a recorder to prove which protection value is requested for
// which files. The real effect (writes succeed while locked) can only be verified on a device
// (HANDOFF §11 step 3a).

import Foundation

/// Applies a data-protection class to a file.
public protocol FileProtectionApplying: Sendable {
    func apply(_ protection: FileProtectionType, toItemAt url: URL) throws
}

/// The protection class every database file gets.
public enum StoreFileProtection {
    public static let required: FileProtectionType = .completeUntilFirstUserAuthentication
}

/// Sets the protection class through FileManager on iOS. On macOS (host tests) it does nothing:
/// data-protection classes are an iOS feature and the host test uses a recorder instead.
public struct SystemFileProtection: FileProtectionApplying {
    public init() {}

    public func apply(_ protection: FileProtectionType, toItemAt url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
        #endif
    }
}
