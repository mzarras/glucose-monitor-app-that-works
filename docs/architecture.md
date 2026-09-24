# App architecture (Phase 2 wiring)

How the app target puts the packages together: what exists once per process, how a reading travels
from the sensor to Trio, alerts, uploads and the widget, which actor runs what, what happens at
launch, first unlock, background wakes and foreground, how DEBUG replay replaces the sensor, and
where each safety rule (HANDOFF §2) is enforced in the app layer. Package internals are in their own
docs (`g7-protocol.md`, `storage.md`, `alerts.md`, `trio-bridge.md`, `following.md`, `import.md`,
`replay.md`, `widgets.md`).

| Folder | What it holds |
|---|---|
| `App/Sources/Composition/` | `AppEnvironment` (composition root), `SensorAppDelegate` (launch hooks, notification delegate), `AlertPorts` (how an `AlertService` is built), `ReplayRun` (DEBUG) |
| `App/Sources/Pipeline/` | `ReadingPipeline`, its outputs, clocks, the clock-mismatch monitor, force-quit gap detection, Trio status mappings |
| `App/Sources/Services/` | The UI facade `AppServices` (+ value types, DEBUG `PreviewAppServices`), `LiveAppServices` and its coordinators (Trio, uploads, imports), preferences, the diagnostic log, the widget output |
| `App/Sources/Intents/` | `StopUrgentLowAlarmIntent` (the AlarmKit Stop button, D26) |

The screens (`Screens/`, `ViewState/`, `Model/`, …) talk only to `AppServices`; they never hold a
package object.

## Composition (`AppEnvironment`)

Exactly one of each, for the whole process:

| Object | Built with | Notes |
|---|---|---|
| `RingBufferDiagnosticLog` | 5 000 events, saved to `Application Support/Diagnostics/diagnostics.json` | every module logs here; "Export diagnostics" writes it as text |
| `G7CGMSource` | restore id `com.mzarras.sensor.g7kit.central`, `G7KeychainCredentialStore` | created first, during `willFinishLaunching` (CoreBluetooth state restoration) |
| `GlucoseStore` (production) | `Application Support/GlucoseStore/readings.sqlite` (D25) | opened at bootstrap, after protected data is available |
| `AlertService` | `UserNotificationCenterAdapter`, `PlaybackAlertAudioPlayer`, `SystemAlarmAdapter(makeStopIntent: StopUrgentLowAlarmIntent)`, persisted `AlertSettings` + `AlertEngineSnapshot` | one at a time: the production one, or a DEBUG replay one |
| `TrioBridge` (in `TrioCoordinator`) | `AppGroupUserDefaultsStore(Info.plist TrioAppGroupID)`, `OutOfRangePolicy(low: .writeSentinel, high: .writeSentinel)` (D21) | nil when the build has no `TrioAppGroupID` |
| `ReadingUploader` ×2 (in `UploadCoordinator`) | Nightscout and Dexcom Share factories, queues in `Application Support/Uploads/`, `KeychainCredentialStore`, device name = `APP_DISPLAY_NAME` | created only while enabled, configured and allowed (D20) |
| `WidgetSnapshotPublisher` (in `LiveWidgetPublisher`) | App Group `group.com.mzarras.sensor` | nil when the App Group is unavailable (logged) |
| History importers | on demand, `UserDefaultsNightscoutImportCheckpointStore` | write to the production store only (S6) |
| `LiveAppServices` | all of the above | the `AppServices` the UI gets |

A unit-test host (DEBUG, `XCTestConfigurationFilePath` set) gets an inert `PreviewAppServices`:
tests build their own pipelines. `-replayScenario <name>` starts a DEBUG replay run at launch.

## Data flow

```
 G7 sensor ──BLE──> G7CGMSource ─┬─ readings ──┐
 (every ~5 min: live + backfill)  └─ state ─────┤  one ordered queue per source (ReadingPipeline)
                                                │  held while inactive or while the store is closed
                                                v
                                   GlucoseStore.insert (dedupe by id, ±150 s import rule,
                                   refuses implausible / future / non-finite / wrong role)
                                                │ newly stored readings only
                                                v
                              LiveReadingGate.validate(reading, session: source.currentSession, now:)
                                                │ passed                       └─ refused: diagnostic + counter
                     ┌──────────────────────────┼───────────────────────────┬──────────────────┐
                     v                          v                           v                  v
           TrioBridge.publish         AlertService .reading       uploaders submit     widget snapshot,
           (App Group, first:          (gate again inside)        + flushIfDue          UI change
            Trio reads at the                                     (gate again inside)   notification
            sensor's disconnect)
 states:   TrioBridge.publish([], session:)   AlertService .sensorState   heartbeat keys re-evaluated
 every batch (a wake):  AlertService .tick · widget · clock-mismatch check · pipeline heartbeat

 Importers (Nightscout, Clarity CSV) ──> GlucoseStore.insert ──> store.changes() ──> charts/stats only
```

Order inside a batch of readings: Trio first (its heartbeat fires when the sensor disconnects, seconds
after delivering; docs/trio-bridge.md "Heartbeat wiring"), then alerts, then uploads (queued at once,
flushed in the background so the network never holds up the queue), then the widget.

Trio status → `TrioBridgeSummary` (`TrioStatusMapping.swift`) → AlertEngine's `.trioBridge` input
(`TrioAlertInput.swift`): write failures and starvation (`isStarving`, 15 min) both alert (S5).

## Threading and actors

| Where | Isolation |
|---|---|
| `ReadingPipeline`, `LiveAppServices`, coordinators, `AlertService`, `AppEnvironment` | `@MainActor`; the pipeline processes one batch at a time (a single worker task drains its queue) |
| `G7CGMSource` | its own serial queue (CoreBluetooth callbacks); streams consumed by two main-actor tasks for the whole process (never dropped: an `AsyncStream` iterator dropped ends the stream) |
| `GlucoseStore` | GRDB writer queue / reader pool; `production(at:)` is `@concurrent`, no SQL on the main actor |
| `TrioBridge`, `ReadingUploader`, importers | actors |
| `RingBufferDiagnosticLog` | any thread, lock-protected; saves on a utility queue |

Name clashes worth knowing (S8): the app declares its own `AlertKind`, `AlertDeliveryStatus`,
`QuietHours`, `UploadStatus`; AlertEngine and TrioBridge both declare `TrioBridgeStatus`; and
`AlertEngine`, `TrioBridge`, `GlucoseStore` cannot be used as module qualifiers (each exports a type
with its module's name). Files therefore import only the module whose type they name, and the facade
uses its own value types (`AlertDeliveryReport`, `TrioBridgeSummary`, `UploaderSummary`, …).

## Lifecycle

**Launch** (`SensorAppDelegate.willFinishLaunching`): the notification center delegate is set, and
`AppEnvironment.shared` is created — the G7 source first, so CoreBluetooth can restore its central;
the sensor pipeline starts consuming both streams (holding everything) and `start(pairingCode: nil)`
is called. `didFinishLaunching` records whether iOS relaunched the app for Bluetooth
(`launchOptions[.bluetoothCentrals]`) and starts the bootstrap.

**Bootstrap** (once, as soon as `isProtectedDataAvailable`): preferences, alert settings and the
engine snapshot are read; the force-quit gap is checked against the persisted pipeline heartbeat;
the production `AlertService` is created and `start()`ed (reconciles what an earlier process left
pending), the intent bridge is connected, queued notification responses are delivered; Trio, uploads
and the widget are attached; the pipeline is activated (held states flow, in order); the store is
opened and attached (held readings flow, in order); the G7 source is started again if it could not
read its pairing before; Trio is re-seeded with the last 5 h of stored sensor readings; the retention
purge runs if due.

**Before the first unlock after a reboot**: preferences, the Keychain and the database are unreadable
by design. Nothing is read or written; the G7 source reports `.failed(credentialsUnavailable)`; any
reading is held in memory and `storage.availability` is `.waitingForFirstUnlock(heldReadings:)` (S5).
`protectedDataDidBecomeAvailable` runs the bootstrap, restarts the G7 source and opens the store.

**Background wake** (BLE event, state restoration relaunch): the pipeline processes the batch; then
the alert service gets `.tick`, the widget is republished, the clock-mismatch latch is re-checked and
the pipeline heartbeat is saved. Uploads flush under a background-time assertion.

**Foreground**: permissions and media volume are re-read, `.tick`, Trio retry (`publish([], session:)`),
upload `flushIfDue`, retention if a day has passed, clock check; a 60-second ticker repeats tick,
Trio retry and clock check while in the foreground. **Background**: the ticker stops, the heartbeat and
the diagnostic log are saved.

**Force-quit gap** (HANDOFF §4.6): at bootstrap, if the last heartbeat is ≥ 15 min old, the sensor
was active then, the boot is the same, and this is not a Bluetooth relaunch, `forceQuitGap` is set
(and kept until dismissed).

**Clock mismatch** (review N1): after every batch, at bootstrap, on foreground and on the UI's tick,
`ClockMismatchMonitor` applies WidgetCore's latch rule and a memoryless check (wall-clock delta vs the
monotonic clock since the last check, same boot, > 60 s apart → latch). The latch is persisted.

## DEBUG replay (D11, D19, D20)

`startReplay` (or `-replayScenario <name>` [`-replaySpeed <x>`] [`-replayStartMinute <m>`]) builds a
`ReplayRun`: a ReplayKit source on a `ScaledReplayClock`, a separate in-memory replay store
(`GlucoseStore.replay()`, never the production database), a pipeline whose gate is
`validateAllowingReplay`, and a fresh `AlertService` with `acceptsReplayReadings` that persists
nothing. The replay clock is the pipeline's, the store's and the alert service's clock. For the run:
the G7 source is stopped and its pipeline holds any event; the production alert service is released
(one `AlertService` at a time) and rebuilt from its snapshot when the run ends (its `.launched`
reconcile removes what the replay left pending). The Trio bridge and uploaders are attached only with
the developer switch on — and still refuse every replay reading (their own sensor-only gate); the
bridge is given no session, so Trio's App Group is never changed by a replay run. None of this code
exists in Release.

## Where each safety rule is enforced in the app layer

| Rule | Where | Proven by |
|---|---|---|
| S1 never fabricate | The pipeline only moves readings the source delivered; the facade returns stored readings only; the clock-mismatch latch keeps a future-dated latest reading from looking current; missed readings counts from a clock rollback | `ReadingPipelineTests.test_S1_futureDatedNewestReadingIsNotCurrent`, `test_S1_clockChangeBetweenWakesLatchesTheLatestReading` |
| S2 only valid readings | `ReadingPipeline` gates every newly stored reading with the source's current session before any consumer (the source gates first; each consumer gates again); a store refusal in a batch keeps the valid readings | `test_S2_pipelineGatesEveryNewReadingBeforeConsumers`, `test_S2_storeRefusalInABatchKeepsTheValidReadings` |
| S3 dedupe / timestamps | Only readings `insert` returns go further, so a re-delivery or backfill copy is published once; backfill keeps its flag and date | `test_S3_redeliveredReadingIsPublishedOnce`, `ReplayScenarioTests.test_signalGapWithBackfill_…` |
| S4 LOW/HIGH | Flags pass through untouched; Trio gets 39/401 only through the D21 policy line in `TrioCoordinator` | `ReplayScenarioTests` (LOW/HIGH scenarios), TrioBridge's own `test_S4_*` |
| S5 fail loud | Held readings and store failures in `storage.availability`; Trio failures/starvation → Trio bridge alert; uploader `QueueFileInUse` → setup error; force-quit gap; missed readings in replay | `test_S5_storeClosedBeforeFirstUnlockSurfacesAndRecovers`, `test_S5_replacingAnUploaderReleasesTheQueueFileFirst`, `test_S5_forceQuitGapIsReportedOnlyForASilenceWithAnActiveSensor`, `ReplayScenarioTests` |
| S6 live data only | Importers write to the store only; the pipeline gate refuses non-sensor readings (replay only in a DEBUG replay run, for alerts); Trio/uploads off in DEBUG without the developer switch, and refusing replay with it | `test_S6_importedReadingsNeverReachConsumers`, `test_S6_replayNeverReachesTrioOrUploads`, `test_S6_trioBridgeIsNotAttachedWithoutLiveOutputsAllowed`, `test_S6_uploadersAreNotCreatedWithoutLiveOutputsAllowed` |
| S7 urgent low | Settings go through `AlertSettings` (no off switch, snooze ≤ 30); the AlarmKit Stop intent acknowledges through the engine | `ReplayScenarioTests.test_slowFallToUrgentLow_…` (repeats until acknowledged, silent only for its snooze), AlertEngine's `test_S7_*` |
| S8 auditable | Small files per concern; the order of every step written in the file headers | — |

## Known limits (for the on-device checks, HANDOFF §11)

- The simulator Keychain needs a signed host; `KeychainCredentialStoreTests` skip (loudly) under an
  unsigned build (`CODE_SIGNING_ALLOWED=NO`) and pass with simulator signing.
- File protection, state restoration, background wakes, AlarmKit and real Trio consumption can only be
  verified on a device.
- The force-quit heuristic can report a gap after an iOS memory termination if the user opens the app
  before the sensor's next event (rare); it never reports one after a Bluetooth relaunch or a reboot.
