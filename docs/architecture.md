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
 G7 sensor ──BLE──> G7CGMSource ─┬─ readings ── LiveReadingGate.validate(reading, session: source.currentSession, now:)
 (every ~5 min: live + backfill)  │              on arrival; refused: diagnostic + counter, never stored (D38)
                                  │              │ passed (with the session it was checked against)
                                  └─ state ──────┤  one ordered queue per source (ReadingPipeline),
                                                 │  waiting before activation (bootstrap)
                                                 v
                                   GlucoseStore.insert (dedupe by id, ±150 s import rule,
                                   refuses implausible / future / non-finite / wrong role;
                                   one reading at a time after a failed batch)
                                                │ newly stored readings only
                     ┌──────────────────────────┼───────────────────────────┬──────────────────┐
                     v                          v                           v                  v
           TrioBridge.publish         AlertService .reading       uploaders submit     widget snapshot,
           (App Group, first:          (gate again inside)        + flushIfDue          UI change
            Trio reads at the                                     (gate again inside)   notification
            sensor's disconnect)

 store closed or failing (D42):  gate-passed readings ──> TrioBridge.publish + AlertService .reading at once,
                                 held in memory ("unstored", shown in latestLiveReading and the widget),
                                 stored first at every later wake ──> then uploads
 states:   TrioBridge.publish([], session:)   AlertService .sensorState   heartbeat keys re-evaluated
 every drain attempt (a wake, also when nothing could be stored):
           AlertService .storage(ok | failing(since:)) · .tick · widget · clock-mismatch check · pipeline heartbeat

 Importers (Nightscout, Clarity CSV) ──> GlucoseStore.insert ──> store.changes() ──> charts/stats only
```

Order inside a batch of readings: Trio first (its heartbeat fires when the sensor disconnects, seconds
after delivering; docs/trio-bridge.md "Heartbeat wiring"), then alerts, then uploads (queued at once,
flushed in the background so the network never holds up the queue), then the widget.

**Storage failure (D42).** A full disk (or a database that cannot be opened after bootstrap) must not
silence anything: readings that passed the gate go to the Trio bridge and the alert engine at once
(both deduplicate), and wait in memory for the store; states are never held behind them. Every wake
retries the store first; once stored, the readings go to the uploads. The alert engine gets
`.storage(.failing(since:))` (first failure of the current run; the storage-failure alert fires after
`AlertLimits.storageFailingMinutes`) and `.storage(.ok)` once everything waiting is stored.

**Uploaders** are read by the pipeline at the moment of use (`PipelineOutputs.uploaders` is an
accessor over `UploadCoordinator.activeUploaders`), so an uploader replaced in Settings — possibly
after a `QueueFileInUse` retry — is used without re-attaching, and a released uploader is never kept
alive by the pipeline (Phase 2 review M2).

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
and the widget are attached; the pipeline is activated first (held events flow, in order) and the
store is opened alongside, so a slow open (a long migration) cannot delay alerts or Trio: readings that
arrive before it is open go to Trio and the alert engine at once and are stored when it opens (the D42
path; the storage-failure alert only fires if that takes longer than `AlertLimits.storageFailingMinutes`);
the G7 source is started again if it could not read its pairing before. **Until the store is open the
latest reading is unknown** (review B1): no widget snapshot is written and the clock-mismatch latch is
neither judged nor persisted, so neither can be cleared by a relaunch; if the open fails, the persisted
latch and the last widget snapshot are kept (the widget's own timeline turns it stale and "No data" on
time). Once the store is open: the latest reading is read, the widget is published, the latch is
checked, Trio is re-seeded with the last 5 h of stored sensor readings, retention runs if due.

**Trio at launch** (review m1): the bridge's window is empty in a new process, and G7Kit may deliver
backfill the App Group already holds. So until the re-seed, readings not newer than the newest reading
the App Group held when this process started are kept back (`TrioCoordinator`), and written with the
first newer reading or by the re-seed — the first write never moves Trio's newest reading backwards.
Nothing is written that did not pass the gate in this process.

**Before the first unlock after a reboot**: preferences, the Keychain and the database are unreadable
by design. Nothing is read or written; the G7 source reports `.failed(credentialsUnavailable)`; any
reading is held in memory and `storage.availability` is `.waitingForFirstUnlock(heldReadings:)` (S5).
`protectedDataDidBecomeAvailable` runs the bootstrap, restarts the G7 source and opens the store.

**Background wake** (BLE event, state restoration relaunch): the pipeline stores any waiting readings,
processes the batch; then the alert service gets the storage health and `.tick`, the widget is republished, the clock-mismatch latch is re-checked and
the pipeline heartbeat is saved. Uploads flush under a background-time assertion.

**Foreground**: a pipeline drain attempt (waiting readings, storage health, `.tick`), permissions and
media volume re-read (which also rebuilds pending reminders if notifications were just allowed in iOS
Settings), `.foreground` to the alert service (D43: expiry reminders refused or dropped are added
again; during a DEBUG replay run the replay service gets it, and production gets one when the run
ends), Trio retry (`publish([], session:)`) and heartbeat-key check (not during a DEBUG replay run),
upload `flushIfDue`, retention if a day has passed, clock check; a 60-second ticker repeats the drain
attempt, Trio retry, heartbeat-key check and clock check while in the foreground. **Background**: the
ticker stops, the heartbeat and the diagnostic log are saved.

**Force-quit gap** (HANDOFF §4.6): at bootstrap, if the last heartbeat is ≥ 15 min old, the sensor
was active then, the boot is the same, and this is not a Bluetooth relaunch, `forceQuitGap` is set
(and kept until dismissed).

**Clock mismatch** (review N1): after every batch, at bootstrap, on foreground and on the UI's tick,
`ClockMismatchMonitor` applies WidgetCore's latch rule and a memoryless check (wall-clock delta vs the
monotonic clock since the last check, same boot, > 60 s apart → latch). The latch is persisted. It is
checked only while the production store is open, and an unknown latest reading leaves it (and the
last clock record) untouched — nil means "not known yet", not "no reading" (review B1).

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
| S1 never fabricate | The pipeline only moves readings the source delivered; the facade returns stored readings only; the clock-mismatch latch keeps a future-dated latest reading from looking current, and survives relaunches (never judged against an unknown latest reading); missed readings counts from a clock rollback | `ReadingPipelineTests.test_S1_futureDatedNewestReadingIsNotCurrent`, `test_S1_clockChangeBetweenWakesLatchesTheLatestReading`, `BootstrapRegressionTests.test_S1_clockMismatchLatchSurvivesBootstrap`, `LaunchOrderTests.test_S1_clockLatchAndWidgetSurviveTheLaunch` |
| S2 only valid readings | `ReadingPipeline` gates every delivered reading with the source's current session **before it is stored** (D38) and so before any consumer (the source gates first; each consumer gates again); a refused reading is never stored; one refusal in a batch (gate or store) keeps the valid readings | `test_S2_pipelineGatesEveryNewReadingBeforeConsumers`, `test_S2_gateRefusedReadingIsNeverStored`, `test_S2_refusalInABatchKeepsTheValidReadings`, `test_S2_storeRefusalInABatchKeepsTheValidReadings` |
| S3 dedupe / timestamps | Only readings `insert` returns go further, so a re-delivery or backfill copy is published once; backfill keeps its flag and date | `test_S3_redeliveredReadingIsPublishedOnce`, `ReplayScenarioTests.test_signalGapWithBackfill_…` |
| S4 LOW/HIGH | Flags pass through untouched; Trio gets 39/401 only through the D21 policy line in `TrioCoordinator` | `ReplayScenarioTests` (LOW/HIGH scenarios), TrioBridge's own `test_S4_*` |
| S5 fail loud | Held readings and store failures in `storage.availability`; a failing store keeps alerts and Trio fed and raises the storage-failure alert (D42); every drain attempt ticks the alert engine; Trio failures/starvation, or the bridge on in a build without a Trio App Group → Trio bridge alert; uploader `QueueFileInUse` → setup error, retried, and the pipeline follows the replacement; force-quit gap; missed readings in replay | `test_S5_failingStoreStillAlarmsUrgentLowAndFeedsTrio`, `test_S5_storeClosedStillTicksAlerts`, `test_S5_storeClosedBeforeFirstUnlockSurfacesAndRecovers`, `test_S5_pipelineUploadsThroughAReplacedUploader`, `test_S5_trioBridgeOnWithoutAnAppGroupIsFailing`, `test_S5_forceQuitGapIsReportedOnlyForASilenceWithAnActiveSensor`, `ReplayScenarioTests` |
| S6 live data only | Importers write to the store only; the pipeline gate refuses non-sensor readings (replay only in a DEBUG replay run, for alerts); Trio/uploads off in DEBUG without the developer switch, and refusing replay with it | `test_S6_importedReadingsNeverReachConsumers`, `test_S6_replayNeverReachesTrioOrUploads`, `test_S6_trioBridgeIsNotAttachedWithoutLiveOutputsAllowed`, `test_S6_uploadersAreNotCreatedWithoutLiveOutputsAllowed` |
| S7 urgent low | Settings go through `AlertSettings` (no off switch, snooze ≤ 30); the AlarmKit Stop intent acknowledges through the engine (`AlarmIntentRouting`) | `AlarmStopIntentTests.test_S7_alarmStopIntentAcknowledgesUrgentLowForAtMost30Minutes`, `ReplayScenarioTests.test_slowFallToUrgentLow_…` (repeats until acknowledged, silent only for its snooze), AlertEngine's `test_S7_*` |
| S8 auditable | Small files per concern; the order of every step written in the file headers | — |

## Known limits (for the on-device checks, HANDOFF §11)

- **No glucose alerts before the first unlock after a reboot.** Until then the Keychain (the sensor's
  pairing), the preferences and the database are unreadable by design, so the G7 source reports
  `.failed(credentialsUnavailable)` and receives no readings; the app does not bootstrap and creates
  no alert service. Notifications scheduled before the reboot (urgent-low repeats, missed readings)
  are still delivered by iOS. Unlocking once restores everything (bootstrap, store, G7 restart).
- **Readings waiting for a failing store live in memory only (D42).** If iOS terminates the app before
  the store recovers, they are lost from history (alerts and Trio already had them). G7Kit decides
  what the sensor backfills from its own persisted newest-published mark; it exposes no hook to base
  backfill on the latest *stored* reading (Phase 2 must-do), so such readings are not re-requested.
  Up to 10 000 distinct readings wait (a re-delivered reading is held once); beyond that the oldest
  are dropped, loudly.
- The simulator Keychain needs a signed host: `scripts/check.sh` signs simulator test runs ad hoc
  (D40); `KeychainCredentialStoreTests` fail, not skip, on an unsigned host.
- File protection, state restoration, background wakes, AlarmKit and real Trio consumption can only be
  verified on a device.
- **Force-quit heuristic** (`ForceQuitGapDetector`): reported only for a silence of ≥ 15 min with the
  sensor active at the last heartbeat, in the same boot, on a launch that is not a Bluetooth
  relaunch. Limits: an iOS memory termination followed by the user opening the app before the
  sensor's next event looks the same (false positive, rare); a force-quit followed by a reboot is not
  reported (the boot changed); Bluetooth turned off for a while is not a launch and is not reported
  here (the missed-readings alert and the Bluetooth banner cover it); the heartbeat is written at most
  once per wake, so the gap's start is accurate to the last wake.
