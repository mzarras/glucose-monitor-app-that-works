// The service facade: everything the UI needs from the running app — readings, the sensor, Trio,
// uploads, history import, alerts, data — as plain values and async calls. Screens and view
// models talk only to this protocol; the live implementation (`LiveAppServices`, built by
// `AppEnvironment`) wires G7Kit → GlucoseStore → pipeline → AlertEngine / TrioBridge /
// NightscoutKit / widget. `PreviewAppServices` (DEBUG) is an in-memory stand-in for previews and
// view tests.
//
// Rules for callers:
// - Everything is `@MainActor`. Properties are cheap snapshots; after a `ServiceChange` arrives on
//   `changes()`, re-read the properties it names.
// - Nothing here creates a reading (S1). `latestLiveReading` is the store's newest `.sensor`
//   reading (in a DEBUG replay run: the newest replay reading), never imported history (S6), and
//   is returned however old it is — classify staleness in the UI with a live clock (S5).
// - Secrets (Nightscout token, Dexcom password) go in through `save…` calls and never come back
//   out; summaries only say whether one is stored.
// - Alert settings are AlertEngine's `AlertSettings` value: its ranges live in `AlertLimits` and
//   every setter clamps (S7: urgent low has no on/off and snoozes ≤ 30 min). Mutate a copy of
//   `alertSettings` and pass it to `updateAlertSettings(_:)`.
//
// Composition: `SensorApp` creates the one live instance at launch and hands it to
// `AppModel.launch(services:)` (the app model owns the view states).

import AlertEngine
import Foundation
import GlucoseCore
import GlucoseStore
import NightscoutKit
import WidgetCore

@MainActor
protocol AppServices: AnyObject {
    // MARK: Change notifications

    /// A new stream per call: every change after the call, until the stream is dropped.
    func changes() -> AsyncStream<ServiceChange>

    // MARK: Readings (S1, S5, S6)

    /// The store's newest live reading (`GlucoseReadingRepository.latestLiveReading()`), however
    /// old; nil if none. A reading dated ahead of the phone clock is returned too — it is not a
    /// current reading (see `clockMismatchLatchedFor`).
    var latestLiveReading: GlucoseReading? { get }
    /// The live reading immediately before `latestLiveReading` (for the delta), if any.
    var previousLiveReading: GlucoseReading? { get }
    /// Stored readings with `start <= date < end`, ascending, any source (charts and stats may use
    /// imported history). Throws while the store is not open (`storage.availability`).
    func readings(from start: Date, to end: Date) async throws -> [GlucoseReading]

    /// Review N1 / Phase 2 must-do: the latest live reading's date while a clock mismatch is latched
    /// for it (the reading was seen dated ahead of the phone clock, or the wall clock jumped against
    /// the monotonic clock between two ingests). Persisted across relaunches; cleared by a newer
    /// reading. Mirror it into `NowViewState` / `CalibrationViewState`.
    var clockMismatchLatchedFor: Date? { get }
    /// Re-evaluates the latch against `now` (call from the UI's clock tick). The pipeline also
    /// calls it on every reading, background wake, launch and foreground.
    func updateClockMismatchLatch(now: Date)

    // MARK: Sensor

    /// The CGM source's latest state (drives S5 banners and sensor rows).
    var sensorState: SensorState { get }
    /// The authenticated session (`CGMSource.currentSession`), nil when none is valid (D28).
    var sensorSession: SensorSession? { get }
    /// Whether the source can stop a session (G7: no, `G7CGMSource.supportsStopSession`).
    var canStopSession: Bool { get }
    /// Pairs a new sensor with its 4-digit code. Failures after the code is accepted arrive as
    /// `sensorState` `.failed(_:)` (D36).
    func pair(code: String) async throws(PairingError)
    /// Pairs the sensor being worn again with its 4-digit code (e.g. after "pair again" failures:
    /// `pairingRejected`, `pairingCodeNeeded`, `bondRemoved`), keeping its session. `pair(code:)`
    /// is the new-sensor flow.
    func pairAgain(code: String) async throws(PairingError)
    /// Deletes the pairing (key and code), reports `.notPaired`, and removes Trio's heartbeat keys.
    func forgetSensor() async
    /// Whether the G7 source has a stored sensor (one this phone has connected to). Route a pairing
    /// retry to `pairAgain(code:)` only when true; otherwise `pair(code:)` (a new sensor). Refreshed
    /// after every sensor state, pairing and forgetting; a change sends `.sensor`.
    var hasStoredSensor: Bool { get }
    /// The stored sensor's serial ("DXCMxx-1A2B3C4D"), nil when none is stored.
    var storedSensorSerial: String? { get }
    /// False until `hasStoredSensor` / `storedSensorSerial` have been read from the source after
    /// bootstrap (before that they are only defaults). A change sends `.sensor`. Use it to take an
    /// exact "stored sensor before pairing" baseline.
    var storedSensorKnown: Bool { get }

    // MARK: Calibration (PROGRESS D16; never a reading, S1)

    /// Fingerstick range the sensor accepts (mg/dL); nil if the source cannot calibrate.
    var acceptedCalibrationRange: ClosedRange<Int>? { get }
    /// Recent submissions, newest first, with their latest status (for the flow and chart markers).
    var recentCalibrations: [CalibrationRecord] { get }
    /// Validates and queues the request at the source; the outcome arrives in `recentCalibrations`.
    func submitCalibration(_ request: CalibrationRequest) async throws(CalibrationRefusal)

    // MARK: Trio bridge (HANDOFF §8)

    var trio: TrioBridgeSummary { get }
    /// Turning it off removes this app's readings and heartbeat keys from Trio's App Group.
    func setTrioBridgeEnabled(_ enabled: Bool) async

    // MARK: Uploads (HANDOFF §8A)

    var nightscout: NightscoutSummary { get }
    /// Validates and saves the site; stores `token` in the Keychain when given (nil keeps the
    /// stored one, "" deletes it). Retries queued uploads at once with the new credentials.
    func saveNightscout(url: String, token: String?) async throws(ServiceConfigurationError)
    func setNightscoutUploadEnabled(_ enabled: Bool) async

    var dexcomShare: DexcomShareSummary { get }
    /// Stores the account name, password (nil keeps the stored one) and receiver serial number,
    /// then retries at once (a wrong password otherwise backs off 30 min to avoid lockout).
    func saveDexcomShare(accountName: String, password: String?, receiverSerialNumber: String) async throws(ServiceConfigurationError)
    func setDexcomShareRegion(_ region: DexcomShareRegion) async
    func setDexcomShareEnabled(_ enabled: Bool) async
    /// Settings "Retry now": flushes both uploaders ignoring backoff.
    func retryUploads() async

    // MARK: History import (HANDOFF §4.5; imported readings feed charts and stats only, S6)

    /// The running import, or the last finished/failed one (kept across launches), nil if none.
    var historyImport: HistoryImportState? { get }
    /// Imports from the saved Nightscout site (resumable, idempotent).
    func startNightscoutImport(scope: NightscoutImportScope)
    /// Imports a Dexcom Clarity CSV export recorded in `timeZone`.
    func startClarityImport(fileData: Data, timeZone: TimeZone)
    func cancelHistoryImport()

    // MARK: Alerts (HANDOFF §5, §4.7)

    var alertSettings: AlertSettings { get }
    /// Persists and applies the settings (the engine clamps everything; S7).
    func updateAlertSettings(_ settings: AlertSettings) async
    var alertDelivery: AlertDeliveryReport { get }
    /// Re-reads permissions and the media volume (Settings screen, foreground).
    func refreshAlertDelivery() async
    /// Onboarding: notifications incl. Critical Alerts (D4).
    func requestNotificationAuthorization() async
    /// Onboarding, iOS 26+: allow alarms so urgent low rings while suspended (D26).
    func requestUrgentLowAlarmAuthorization() async
    /// Sound picker preview. Returns false (and plays nothing) while an alert's sound is playing.
    func previewSound(_ sound: AlertSoundID) -> Bool
    func stopSoundPreview()
    /// In-app Acknowledge / Snooze (urgent low snooze is clamped to ≤ 30 min by the engine, S7).
    func handleAlertAction(_ action: AlertUserAction) async

    // MARK: Permissions

    var bluetoothAuthorization: BluetoothAuthorization { get }

    // MARK: Data (HANDOFF §4.5, §11 step 6)

    var storage: StorageStatus { get }
    func setRetention(_ policy: RetentionPolicy) async
    /// Re-reads row count, range and file size.
    func refreshStorageSummary() async
    /// Writes every stored reading as CSV (docs/storage.md format) to a temporary file.
    func exportAllReadingsCSV() async throws -> URL
    /// Writes the diagnostic log (BLE transitions, bridge writes, uploads, alert decisions; no
    /// personal data beyond readings) to a temporary text file.
    func exportDiagnostics() async throws -> URL

    // MARK: Appearance shared with the widget

    /// The accent the widget snapshot carries (the app uses the same one).
    var accent: AccentChoice { get }
    func setAccent(_ accent: AccentChoice)

    // MARK: Health

    /// Set at launch when the app was force-quit while the sensor was active (HANDOFF §4.6).
    var forceQuitGap: ForceQuitGapReport? { get }
    func dismissForceQuitGap()

    // MARK: DEBUG replay (PROGRESS D11, D19, D20)

    /// Empty in Release builds.
    var replay: ReplayStatus { get }
    #if DEBUG
    /// Replaces the live source with a ReplayKit scenario, a separate in-memory replay store,
    /// alerts accepting replay, and Trio/uploads off unless the developer switch is on.
    /// `speed` is scenario seconds per real second (1 = real time).
    func startReplay(scenario: String, speed: Double) async
    /// Back to the live sensor source and the production store.
    func stopReplay() async
    /// D20 developer switch: let the Trio bridge and uploaders run in this DEBUG build. They still
    /// refuse every non-sensor reading (S6).
    func setDeveloperLiveOutputsEnabled(_ enabled: Bool) async
    /// The running replay's clock (scenario time; ahead of the phone clock above 1×), nil when no
    /// replay runs. The UI classifies against it so an accelerated replay's readings are current
    /// rather than "dated ahead of the phone clock" (Phase 2 carry-over).
    var replayClockNow: Date? { get }
    #endif
}

extension AppServices {
    /// Default for stand-ins that always know (additive requirement).
    var storedSensorKnown: Bool { true }
}
