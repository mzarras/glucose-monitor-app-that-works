// Small persisted settings and state, in `UserDefaults` (the app container; default file protection
// `completeUntilFirstUserAuthentication`). Secrets never go here: the Nightscout token and the Dexcom
// account and password are in the Keychain (NightscoutKit `KeychainCredentialStore`).
//
// Read only after protected data is available (`LiveAppServices` bootstraps then): before the first
// unlock after a reboot the preferences file is unreadable and every value would read as its default.

import AlertEngine
import Foundation
import GlucoseStore
import WidgetCore

@MainActor
final class AppPreferences {
    private let defaults: UserDefaults

    /// Every key, in one place. Renaming one loses the stored value.
    enum Key: String, CaseIterable {
        case trioBridgeEnabled = "sensor.trio.enabled"
        case nightscoutSiteURL = "sensor.nightscout.siteURL"
        case nightscoutUploadEnabled = "sensor.nightscout.uploadEnabled"
        case dexcomShareUploadEnabled = "sensor.dexcomShare.uploadEnabled"
        case dexcomShareRegion = "sensor.dexcomShare.region"
        case dexcomShareReceiverSerial = "sensor.dexcomShare.receiverSerialNumber"
        case retention = "sensor.data.retention"
        case lastPurgeAt = "sensor.data.lastPurgeAt"
        case accent = "sensor.appearance.accent"
        case alertSettings = "sensor.alerts.settings"
        case alertEngineSnapshot = "sensor.alerts.engineSnapshot"
        case clockMismatch = "sensor.health.clockMismatch"
        case pipelineHeartbeat = "sensor.health.pipelineHeartbeat"
        case forceQuitGap = "sensor.health.forceQuitGap"
        case recentCalibrations = "sensor.calibration.recent"
        case lastHistoryImport = "sensor.import.last"
        case developerLiveOutputs = "sensor.debug.developerLiveOutputs"
        case forecastFeedHost = "sensor.forecast.feedHost"
        case forecastEnabled = "sensor.forecast.enabled"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Switches and plain values

    var trioBridgeEnabled: Bool {
        get { defaults.bool(forKey: Key.trioBridgeEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.trioBridgeEnabled.rawValue) }
    }

    var nightscoutSiteURL: String? {
        get { defaults.string(forKey: Key.nightscoutSiteURL.rawValue) }
        set { defaults.set(newValue, forKey: Key.nightscoutSiteURL.rawValue) }
    }

    var nightscoutUploadEnabled: Bool {
        get { defaults.bool(forKey: Key.nightscoutUploadEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.nightscoutUploadEnabled.rawValue) }
    }

    var dexcomShareUploadEnabled: Bool {
        get { defaults.bool(forKey: Key.dexcomShareUploadEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.dexcomShareUploadEnabled.rawValue) }
    }

    /// PROGRESS D7: US unless changed.
    var dexcomShareRegion: DexcomShareRegion {
        get { defaults.string(forKey: Key.dexcomShareRegion.rawValue).flatMap(DexcomShareRegion.init(rawValue:)) ?? .us }
        set { defaults.set(newValue.rawValue, forKey: Key.dexcomShareRegion.rawValue) }
    }

    var dexcomShareReceiverSerial: String? {
        get { defaults.string(forKey: Key.dexcomShareReceiverSerial.rawValue) }
        set { defaults.set(newValue, forKey: Key.dexcomShareReceiverSerial.rawValue) }
    }

    /// HANDOFF §4.5: 2 years unless changed.
    var retention: RetentionPolicy {
        get { defaults.string(forKey: Key.retention.rawValue).flatMap(RetentionPolicy.init(rawValue:)) ?? .default }
        set { defaults.set(newValue.rawValue, forKey: Key.retention.rawValue) }
    }

    var lastPurgeAt: Date? {
        get { defaults.object(forKey: Key.lastPurgeAt.rawValue) as? Date }
        set { defaults.set(newValue, forKey: Key.lastPurgeAt.rawValue) }
    }

    var accent: AccentChoice {
        get { defaults.string(forKey: Key.accent.rawValue).flatMap(AccentChoice.init(rawValue:)) ?? .default }
        set { defaults.set(newValue.rawValue, forKey: Key.accent.rawValue) }
    }

    /// DEBUG builds only use it (PROGRESS D20); Release ignores it.
    var developerLiveOutputs: Bool {
        get { defaults.bool(forKey: Key.developerLiveOutputs.rawValue) }
        set { defaults.set(newValue, forKey: Key.developerLiveOutputs.rawValue) }
    }

    // MARK: Predictions (PROGRESS D57)

    /// The Zen Predict feed host saved in Settings › Predictions (validated before it is saved); nil =
    /// use the build's `ZEN_PREDICT_FEED_HOST`. Only the host and the switch are kept: never a
    /// forecast value (D57). The feed is public, so the host is not a secret (no Keychain).
    var forecastFeedHost: String? {
        get { defaults.string(forKey: Key.forecastFeedHost.rawValue) }
        set { defaults.set(newValue, forKey: Key.forecastFeedHost.rawValue) }
    }

    /// "Show predictions"; nil = never set, which means on once a host is configured.
    var forecastEnabled: Bool? {
        get { defaults.object(forKey: Key.forecastEnabled.rawValue) as? Bool }
        set { defaults.set(newValue, forKey: Key.forecastEnabled.rawValue) }
    }

    // MARK: Alert engine (docs/alerts.md §9)

    /// Stored settings, decoded lossily and clamped by AlertEngine (S7); defaults if none.
    var alertSettings: AlertSettings {
        get { AlertSettings.decodeOrDefault(defaults.data(forKey: Key.alertSettings.rawValue)) }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.alertSettings.rawValue) }
    }

    var alertEngineSnapshot: AlertEngineSnapshot? {
        get { AlertEngineSnapshot.decode(defaults.data(forKey: Key.alertEngineSnapshot.rawValue)) }
        set { defaults.set(newValue?.encoded(), forKey: Key.alertEngineSnapshot.rawValue) }
    }

    // MARK: Codable values

    var clockMismatch: ClockMismatchState {
        get { decode(ClockMismatchState.self, .clockMismatch) ?? .initial }
        set { encode(newValue, .clockMismatch) }
    }

    var pipelineHeartbeat: PipelineHeartbeat? {
        get { decode(PipelineHeartbeat.self, .pipelineHeartbeat) }
        set { encode(newValue, .pipelineHeartbeat) }
    }

    var forceQuitGap: ForceQuitGapReport? {
        get { decode(ForceQuitGapReport.self, .forceQuitGap) }
        set { encode(newValue, .forceQuitGap) }
    }

    var recentCalibrations: [CalibrationRecord] {
        get { decode([CalibrationRecord].self, .recentCalibrations) ?? [] }
        set { encode(newValue, .recentCalibrations) }
    }

    /// The last finished (or failed) history import, for Settings.
    var lastHistoryImport: HistoryImportState? {
        get { decode(HistoryImportState.self, .lastHistoryImport) }
        set { encode(newValue, .lastHistoryImport) }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        guard let data = defaults.data(forKey: key.rawValue) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode<T: Encodable>(_ value: T?, _ key: Key) {
        guard let value else {
            defaults.removeObject(forKey: key.rawValue)
            return
        }
        defaults.set(try? JSONEncoder().encode(value), forKey: key.rawValue)
    }
}
