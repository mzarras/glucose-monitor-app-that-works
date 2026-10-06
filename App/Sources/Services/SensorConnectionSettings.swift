// The sensor connection settings G7Kit needs when the source is created at launch (D45 mode, D47 raw
// packet recording). They are kept in their own small file, not in UserDefaults: the app is often
// launched by CoreBluetooth state restoration before the first unlock after a reboot, when the
// preferences file is unreadable (`completeUntilFirstUserAuthentication`) and would read as the
// defaults. A wrong mode at creation is destructive: G7Kit deletes a stored pairing that belongs to
// the other mode (`G7Controller.loadRecordForMode`), so a listen-mode phone would come back from a
// reboot in primary mode with nothing paired, and a primary-mode phone read as listen would lose its
// pairing key. Hence `FileProtectionType.none`: the file holds no personal data (a mode and a flag).

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
        mode = try SensorConnectionMode(rawValue: container.decode(String.self, forKey: .mode)) ?? .pair
        recordsRawGlucosePackets = try container.decodeIfPresent(Bool.self, forKey: .recordsRawGlucosePackets) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode.rawValue, forKey: .mode)
        try container.encode(recordsRawGlucosePackets, forKey: .recordsRawGlucosePackets)
    }
}

/// Reads and writes `SensorConnectionSettings`. Production: `Application Support/SensorConnection.json`;
/// tests use a temporary file.
final class SensorConnectionSettingsStore: Sendable {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The saved settings, or the defaults when there is no file (first launch). A file that exists
    /// but cannot be read or decoded also gives the defaults, and says so in `problem`.
    func load() -> (settings: SensorConnectionSettings, problem: String?) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return (.defaults, nil) }
        do {
            let data = try Data(contentsOf: fileURL)
            return (try JSONDecoder().decode(SensorConnectionSettings.self, from: data), nil)
        } catch {
            return (.defaults, "the sensor connection settings could not be read (\(error)); using primary mode")
        }
    }

    /// Writes atomically, readable before the first unlock (see the file comment).
    func save(_ settings: SensorConnectionSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(settings)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic, .noFileProtection])
    }
}
