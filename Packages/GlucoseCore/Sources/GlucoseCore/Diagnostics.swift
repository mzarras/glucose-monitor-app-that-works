// Contract (HANDOFF §11 step 6). Owned by the orchestrator; change only through PROGRESS.md.
//
// Modules record BLE state transitions, bridge writes, uploads and alert decisions here; the app
// collects them for Settings → "Export diagnostics". Events may contain glucose readings, the
// sensor serial number and the Nightscout host name; never passwords, tokens or pairing codes.

import Foundation

public struct DiagnosticEvent: Sendable, Equatable, Codable {
    public enum Category: String, Sendable, Equatable, Codable, CaseIterable {
        case ble, sensor, store, bridge, upload, alert, importer, app
    }

    public let date: Date
    public let category: Category
    public let message: String

    public init(date: Date, category: Category, message: String) {
        self.date = date
        self.category = category
        self.message = message
    }
}

/// Where modules send diagnostic events. Implementations must be thread-safe and must not block.
public protocol DiagnosticLog: Sendable {
    func record(_ event: DiagnosticEvent)
}

/// Discards everything. For tests and previews.
public struct NullDiagnosticLog: DiagnosticLog {
    public init() {}
    public func record(_ event: DiagnosticEvent) {}
}
