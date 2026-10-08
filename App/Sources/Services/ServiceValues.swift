// Plain value types that cross the service facade (`AppServices`). The UI reads these and never
// holds a reference to G7Kit, GlucoseStore, TrioBridge, NightscoutKit or AlertEngine objects.
//
// Names are chosen not to collide with the app's own view-state types (the app already declares
// `AlertKind`, `AlertDeliveryStatus`, `QuietHours`, `UploadStatus`, `TrioStatus`, `ImportProgress`),
// and because `AlertEngine.X` / `TrioBridge.X` / `GlucoseStore.X` cannot be written in Swift (each of
// those modules exports a type with the module's own name, which shadows the module).

import AlertEngine
import Foundation
import GlucoseCore
import GlucoseStore
import NightscoutKit

// MARK: - Change notifications

/// What changed. After receiving one, the UI re-reads the matching `AppServices` properties.
/// Delivered on the main actor; several changes in a row may be coalesced by the consumer.
enum ServiceChange: Sendable, Equatable, Hashable, CaseIterable {
    /// Stored readings changed (new live reading, backfill, import, purge): re-read
    /// `latestLiveReading`, `previousLiveReading`, and any range you show.
    case readings
    /// `sensorState`, `sensorSession`, or the pairing changed.
    case sensor
    /// `recentCalibrations` changed.
    case calibration
    /// `trio` changed.
    case trio
    /// `nightscout` or `dexcomShare` changed.
    case uploads
    /// `historyImport` changed.
    case historyImport
    /// `alertSettings` changed.
    case alertSettings
    /// `alertDelivery` changed.
    case alertDelivery
    /// `storage` changed (availability, summary, retention).
    case storage
    /// `forceQuitGap`, `clockMismatchLatchedFor` or `bluetoothAuthorization` changed.
    case health
    /// `accent` changed.
    case appearance
    /// DEBUG only in practice: `replay` changed. Never sent in Release builds.
    case replay
    /// `forecast` changed (PROGRESS D57): the Predict tab and Settings › Predictions only.
    case forecast
}

// MARK: - Storage (HANDOFF §4.4, §4.5; PROGRESS D25)

/// Whether the reading database is open. Before the first unlock after a reboot the database file
/// is unreadable by design (`completeUntilFirstUserAuthentication`), so it cannot be opened; readings
/// that arrive meanwhile are held in memory and stored when it opens (S5: surfaced, never dropped).
enum StoreAvailability: Sendable, Equatable {
    /// Being opened at launch.
    case opening
    case open
    /// Waiting for the phone to be unlocked once since it restarted. `heldReadings` readings arrived
    /// and are held in memory; they are stored (and then published) when the database opens.
    case waitingForFirstUnlock(heldReadings: Int)
    /// Opening failed for another reason (S5). `message` is for Settings and diagnostics.
    case failed(message: String)
}

struct StorageStatus: Sendable, Equatable {
    var availability: StoreAvailability
    /// Row count, date range and file size (Settings: "database size"); nil until first read.
    var summary: StoreSummary?
    /// How long readings are kept (HANDOFF §4.5; default 2 years).
    var retention: RetentionPolicy
    /// When the last retention purge ran (this process), and how many readings it removed.
    var lastPurgeAt: Date?
    var lastPurgeRemoved: Int
}

// MARK: - Trio bridge (HANDOFF §8; PROGRESS D2, D21, D22)

/// Everything Settings → Trio and the S5 banner need about the Trio handoff.
struct TrioBridgeSummary: Sendable, Equatable {
    /// The user's switch.
    var isEnabled: Bool
    /// DEBUG builds keep the bridge off unless the developer switch is on (PROGRESS D20). Always
    /// true in Release.
    var liveOutputsAllowed: Bool
    /// Info.plist `TrioAppGroupID` (for display and the setup check); nil if missing.
    var appGroupID: String?
    /// Last time Trio's App Group was brought up to date (written, or key removed).
    var lastSuccessfulWriteAt: Date?
    var readingsInLastWrite: Int
    /// Newest reading Trio has from this app.
    var newestReadingWrittenAt: Date?
    /// Failed writes since the last success. Non-zero = failing (S5).
    var consecutiveFailures: Int
    /// When the current run of failures (or starvation) began; nil while healthy.
    var problemSince: Date?
    var lastErrorDescription: String?
    var lastErrorAt: Date?
    /// Live readings keep arriving but Trio has had none of them for 15 min (the §5 "Trio bridge"
    /// alert condition; docs/trio-bridge.md "Failure reporting").
    var isStarving: Bool
    /// How far Trio is behind the newest live reading, if known.
    var trioLag: TimeInterval?
    /// The latest safety refusal (LiveReadingGate / ended session), for diagnostics.
    var lastGateRefusalDescription: String?
    /// The heartbeat address currently in Trio's App Group (ours, or a stale one from another app).
    var heartbeatAddressInAppGroup: String?
    /// Whether this app has published its sensor as Trio's heartbeat (docs/trio-bridge.md
    /// "Heartbeat wiring").
    var heartbeatPublished: Bool
    /// The last heartbeat key write/removal error, if the last attempt failed.
    var heartbeatError: String?
    /// Set while the bridge is turned on but cannot run at all in this build (no Trio App Group in
    /// Info.plist): nothing reaches Trio, so it counts as failing (S5, Phase 2 review minor 4).
    var unavailableReason: String?
    /// Readings held back at launch (not newer than Trio's newest, review m1) and since when; they go
    /// out with the next newer reading or the re-seed, and count as starving Trio after 15 min.
    var heldBackReadings: Int = 0
    var heldBackSince: Date?
    /// The bridge's own starvation signal (`isStarving` adds held-back readings to it).
    var bridgeIsStarving = false
    /// D45: the sensor is in listen mode, so the Trio handoff is off in the services (nothing is
    /// written to Trio's App Group, whatever `isEnabled` says; Trio keeps its own CGM path). Settings
    /// shows "off while listening"; no Trio alert.
    var offWhileListening = false

    var isFailing: Bool { !offWhileListening && (consecutiveFailures > 0 || unavailableReason != nil) }

    static let off = TrioBridgeSummary(
        isEnabled: false, liveOutputsAllowed: false, appGroupID: nil, lastSuccessfulWriteAt: nil, readingsInLastWrite: 0,
        newestReadingWrittenAt: nil, consecutiveFailures: 0, problemSince: nil, lastErrorDescription: nil, lastErrorAt: nil,
        isStarving: false, trioLag: nil, lastGateRefusalDescription: nil, heartbeatAddressInAppGroup: nil,
        heartbeatPublished: false, heartbeatError: nil, unavailableReason: nil
    )
}

// MARK: - Uploads (HANDOFF §8A; PROGRESS D6, D7, D29, D30)

/// Dexcom Share server region (PROGRESS D7: US for Michael).
enum DexcomShareRegion: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case us
    case outsideUS
}

/// One uploader (Nightscout or Dexcom Share).
struct UploaderSummary: Sendable, Equatable {
    /// The user's switch.
    var isEnabled: Bool
    /// Site / credentials are present, so an uploader can exist.
    var isConfigured: Bool
    /// DEBUG builds keep uploaders off unless the developer switch is on (PROGRESS D20).
    var liveOutputsAllowed: Bool
    /// NightscoutKit's own status (queue depth, last success, failures, refusals); nil while no
    /// uploader exists (off, not configured, or setup failed).
    var status: NightscoutKit.UploadStatus?
    /// Why the uploader could not be created (e.g. another uploader still owns the queue file —
    /// `QueueFileInUse`, S5), nil otherwise.
    var setupError: String?
    /// When the current run of failures began; nil while healthy.
    var problemSince: Date?
    /// D45: the sensor is in listen mode, so this uploader is off in the services (none exists,
    /// nothing is queued; the Dexcom app keeps its own uploads). Settings shows "off while listening".
    var offWhileListening = false

    /// S5: uploads are not getting through (NightscoutKit's `isFailing`, or setup failed while on).
    var isFailing: Bool {
        !offWhileListening && ((isEnabled && setupError != nil) || (status?.isFailing ?? false))
    }

    static let off = UploaderSummary(isEnabled: false, isConfigured: false, liveOutputsAllowed: false, status: nil, setupError: nil, problemSince: nil)
}

struct NightscoutSummary: Sendable, Equatable {
    /// The validated site URL, nil if none saved.
    var siteURL: String?
    /// Whether a token is in the Keychain (the token itself never leaves the Keychain).
    var hasToken: Bool
    var upload: UploaderSummary
}

struct DexcomShareSummary: Sendable, Equatable {
    /// The Dexcom account name (stored in the Keychain; shown in Settings).
    var accountName: String?
    var hasPassword: Bool
    /// The receiver/upload serial number assigned to the Dexcom account — not the G7 pairing code
    /// (docs/following.md). Required for uploads.
    var receiverSerialNumber: String?
    var region: DexcomShareRegion
    var upload: UploaderSummary
}

/// Why saving a sharing configuration failed.
enum ServiceConfigurationError: Error, Sendable, Equatable {
    /// The Nightscout URL is not a valid `https` URL (NightscoutSite rules).
    case invalidNightscoutURL(String)
    /// No Nightscout site is saved.
    case nightscoutNotConfigured
    /// Dexcom Share needs an account name, a password and a receiver serial number.
    case incompleteDexcomShareCredentials
    /// The Keychain refused the write.
    case keychain(String)
}

// MARK: - History import (HANDOFF §4.5)

struct HistoryImportState: Sendable, Equatable, Codable {
    enum Phase: Sendable, Equatable, Codable {
        case running
        case finished
        case cancelled
        case failed(message: String)
    }

    var origin: ImportOrigin
    var phase: Phase
    /// Newly stored readings.
    var readingsImported: Int
    /// Readings the store did not keep (already present, or within ±150 s of a stored reading).
    var readingsSkippedByStore: Int
    /// History covered so far.
    var coveredFrom: Date?
    var coveredTo: Date?
    /// Entries/rows skipped before storing, by reason (e.g. "futureDated", "errorCode",
    /// "rejectedAmbiguousLocalTime"). Always includes the future-dated count when non-zero
    /// (PROGRESS Phase 2 must-do: show `rejectedFutureDated` / `skipped[.futureDated]`).
    var skipped: [String: Int]
    /// Readings dated in the future that were rejected (a wrong time zone or clock fault).
    var rejectedFutureDated: Int
    var startedAt: Date
    var finishedAt: Date?

    var isRunning: Bool { phase == .running }
}

// MARK: - Alerts (HANDOFF §4.7, §5; docs/alerts.md)

/// Whether alerts can be seen and heard (Settings → Alert delivery; S5). A plain mirror of
/// AlertEngine's delivery status; `problems` are most serious first.
struct AlertDeliveryReport: Sendable, Equatable {
    var permissions: NotificationPermissionState
    /// Media volume 0…1 when last read, nil if unknown (the ringer-off path follows it).
    var outputVolume: Float?
    /// D26: urgent low as an AlarmKit system alarm (`.unavailable` below iOS 26).
    var urgentLowAlarm: SystemAlarmAuthorization
    var problems: [DeliveryProblem]

    static let unknown = AlertDeliveryReport(permissions: .unknown, outputVolume: nil, urgentLowAlarm: .unavailable, problems: [])
}

// MARK: - Sensor and calibration

/// Why `pair(code:)` failed before anything was sent to the sensor. Failures after that arrive as
/// `SensorState.failed(_:)` (D36).
enum PairingError: Error, Sendable, Equatable {
    /// Not exactly four ASCII digits.
    case invalidCode
    /// The pairing record could not be saved (Keychain unavailable, e.g. before the first unlock).
    case credentialStoreFailed(String)
    /// `pairAgain(code:)` with no stored sensor: use `pair(code:)` (the new-sensor flow).
    case noSensorToPairAgain
    /// DEBUG: a replay run is active; stop it before pairing.
    case replayActive
    /// D45: pairing does not exist in listen mode (the Dexcom app owns the sensor); switch to
    /// pairing mode first (`setConnectionMode(.pair)`).
    case notAvailableInListenMode
    /// Review n2: pairing while the connection setting was unresolved records pairing mode first;
    /// that failed (the message says why), so nothing was paired. Choose again in Settings › Sensor.
    case connectionSettingUnresolved(String)
}

/// Why `setConnectionMode(_:)` did not switch (D45). Nothing changed in every case.
enum ConnectionModeError: Error, Sendable, Equatable {
    /// DEBUG: a replay run is active; stop it first.
    case replayActive
    /// The mode could not be saved for the next launch (`SensorConnectionSettingsStore`).
    case couldNotSave(String)
    /// G7Kit could not delete the stored pairing of the old mode (Keychain unavailable, e.g. before
    /// the first unlock).
    case credentialStoreFailed(String)
}

/// One submitted calibration and what the sensor did with it (PROGRESS D16). Never a reading (S1).
struct CalibrationRecord: Sendable, Equatable, Codable, Identifiable {
    var request: CalibrationRequest
    /// The latest status from the source; nil if it was refused before queueing.
    var status: CalibrationStatus?
    /// Set when the source refused it (nothing was queued).
    var refusal: CalibrationRefusalReason?
    var updatedAt: Date

    var id: UUID { request.id }
}

/// `CalibrationRefusal` in a `Codable` form (the contract type is not Codable).
enum CalibrationRefusalReason: Sendable, Equatable, Codable {
    case notPaired
    case notAuthenticated
    case warmingUp
    case sessionEnded
    case valueOutOfRange(lower: Int, upper: Int)
    case anotherCalibrationInProgress
    case invalidTime

    init(_ refusal: CalibrationRefusal) {
        switch refusal {
        case .notPaired: self = .notPaired
        case .notAuthenticated: self = .notAuthenticated
        case .warmingUp: self = .warmingUp
        case .sessionEnded: self = .sessionEnded
        case .valueOutOfRange(let accepted): self = .valueOutOfRange(lower: accepted.lowerBound, upper: accepted.upperBound)
        case .anotherCalibrationInProgress: self = .anotherCalibrationInProgress
        case .invalidTime: self = .invalidTime
        }
    }

    var refusal: CalibrationRefusal {
        switch self {
        case .notPaired: return .notPaired
        case .notAuthenticated: return .notAuthenticated
        case .warmingUp: return .warmingUp
        case .sessionEnded: return .sessionEnded
        case .valueOutOfRange(let lower, let upper): return .valueOutOfRange(accepted: lower...upper)
        case .anotherCalibrationInProgress: return .anotherCalibrationInProgress
        case .invalidTime: return .invalidTime
        }
    }
}

// MARK: - Health

/// iOS Bluetooth permission for this app (`CBManager.authorization`). The prompt appears when the
/// G7 source creates its central at launch; the Bluetooth power state arrives as
/// `SensorState.bluetoothUnavailable(_:)`.
enum BluetoothAuthorization: Sendable, Equatable {
    case notDetermined
    case allowed
    case denied
    case restricted
}

/// HANDOFF §4.6: iOS does not relaunch a force-quit app. Detected at launch from the persisted
/// pipeline heartbeat: the sensor was active, and no reading arrived between `from` and `to`.
struct ForceQuitGapReport: Sendable, Equatable, Codable {
    /// Last pipeline activity before the app stopped running.
    var from: Date
    /// This launch.
    var to: Date
}

// MARK: - DEBUG replay (PROGRESS D11, D19, D20)

/// What the DEBUG replay controls show. In Release builds replay does not exist: every field is
/// empty and `.replay` changes are never sent.
struct ReplayStatus: Sendable, Equatable {
    /// `ReplayScenario` raw values, e.g. "slowFallToUrgentLow".
    var availableScenarios: [String]
    /// The running scenario, nil when the live sensor source is in use.
    var activeScenario: String?
    /// Scenario seconds per real second (1 = real time).
    var speed: Double?
    /// D20: DEBUG builds keep the Trio bridge and uploaders off unless this is on. Even on, they
    /// refuse every non-sensor reading (S6).
    var developerLiveOutputsEnabled: Bool

    static let none = ReplayStatus(availableScenarios: [], activeScenario: nil, speed: nil, developerLiveOutputsEnabled: false)
}
