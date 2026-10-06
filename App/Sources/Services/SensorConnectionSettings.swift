// The sensor connection settings G7Kit needs when the source is created at launch (D45 mode, D47 raw
// packet recording). They are kept in their own small file, not in UserDefaults: the app is often
// launched by CoreBluetooth state restoration before the first unlock after a reboot, when the
// preferences file is unreadable (`completeUntilFirstUserAuthentication`) and would read as the
// defaults. A wrong mode at creation is destructive: G7Kit deletes a stored pairing that belongs to
// the other mode (`G7Controller.loadRecordForMode`), so a listen-mode phone would come back from a
// reboot in primary mode with nothing paired, and a primary-mode phone read as listen would lose its
// pairing key. Hence `FileProtectionType.none`: the file holds no personal data (a mode and a flag).
//
// Review m2/m5: the file is read once at launch (`AppEnvironment`), and the result goes to both the G7
// source and the services. A file that exists but cannot be read (or names an unknown mode) never
// switches modes: the services keep the source stopped and ask the person to choose again
// (`LiveAppServices.connectionSettingProblem`), and `GuardedG7CredentialStore` keeps G7Kit from
// deleting the pairing meanwhile. A missing file is a first launch (or an install from before D45).

import Foundation
import G7Kit

struct SensorConnectionSettings: Codable, Equatable, Sendable {
    var mode: SensorConnectionMode
    var recordsRawGlucosePackets: Bool

    /// A first launch: primary mode (this app pairs), recording off (D47).
    static let defaults = SensorConnectionSettings(mode: .pair, recordsRawGlucosePackets: false)

    /// G7Kit's form of the mode. Primary always uses the recommended slot (slot 2,
    /// docs/g7-protocol.md "Slot choice").
    var g7Mode: G7ConnectionMode {
        switch mode {
        case .pair: return .primary(slot: .recommendedDefault)
        case .listen: return .listen
        }
    }

    var g7Configuration: G7Configuration {
        G7Configuration(mode: g7Mode, recordsRawGlucosePackets: recordsRawGlucosePackets)
    }

    private enum CodingKeys: String, CodingKey { case mode, recordsRawGlucosePackets }

    init(mode: SensorConnectionMode, recordsRawGlucosePackets: Bool) {
        self.mode = mode
        self.recordsRawGlucosePackets = recordsRawGlucosePackets
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .mode)
        // Review nit: an unknown mode is unreadable, never silently pairing mode.
        guard let mode = SensorConnectionMode(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .mode, in: container, debugDescription: "unknown connection mode \"\(raw)\"")
        }
        self.mode = mode
        recordsRawGlucosePackets = try container.decodeIfPresent(Bool.self, forKey: .recordsRawGlucosePackets) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode.rawValue, forKey: .mode)
        try container.encode(recordsRawGlucosePackets, forKey: .recordsRawGlucosePackets)
    }
}

/// What the settings file held at launch.
enum SensorConnectionSettingsLoad: Sendable, Equatable {
    /// No file: a first launch, or an install from before D45 (pairing mode, the defaults).
    case missing
    case loaded(SensorConnectionSettings)
    /// The file exists but could not be read or decoded (including an unknown mode). Not a choice:
    /// the person chooses again; nothing switches modes meanwhile.
    case unreadable(String)

    /// What the G7 source is created with. For `.unreadable` the defaults, but the source is not
    /// started until the person has chosen again, and G7Kit cannot delete the pairing meanwhile.
    var settings: SensorConnectionSettings {
        if case .loaded(let settings) = self { return settings }
        return .defaults
    }

    /// Why the file could not be used; nil when it was read or is missing.
    var problem: String? {
        if case .unreadable(let reason) = self { return reason }
        return nil
    }
}

/// Reads and writes `SensorConnectionSettings`. Production: `Application Support/SensorConnection.json`;
/// tests use a temporary file.
final class SensorConnectionSettingsStore: Sendable {
    let fileURL: URL
    /// Writes the encoded settings; tests make it fail (a full disk).
    private let write: @Sendable (Data, URL) throws -> Void

    init(fileURL: URL, write: @escaping @Sendable (Data, URL) throws -> Void = SensorConnectionSettingsStore.writeAtomically) {
        self.fileURL = fileURL
        self.write = write
    }

    /// Atomic, readable before the first unlock (see the file comment).
    static func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .noFileProtection])
    }

    /// Reads the file. Call once per launch (review m5) and hand the result to the source and the
    /// services.
    func load() -> SensorConnectionSettingsLoad {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
        do {
            let data = try Data(contentsOf: fileURL)
            return .loaded(try JSONDecoder().decode(SensorConnectionSettings.self, from: data))
        } catch {
            return .unreadable("\(fileURL.lastPathComponent) could not be read: \(error)")
        }
    }

    /// Writes atomically, readable before the first unlock (see the file comment).
    func save(_ settings: SensorConnectionSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(settings)
        try write(data, fileURL)
    }
}
