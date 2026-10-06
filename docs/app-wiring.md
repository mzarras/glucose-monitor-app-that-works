# App wiring: screens on `AppServices`

How every screen gets its view state from the service facade (`App/Sources/Services/AppServices.swift`),
what updates it, and what runs off the main actor. Code: `App/Sources/Model/`. The facade itself —
the pipeline, stores, alert service, Trio bridge, uploaders — is Integrator A's
(`docs/architecture.md`); this document starts at the facade.

## Shape

```
SensorApp → AppModel.launch(services: AppEnvironment.shared.services)   one model, @MainActor @Observable
              │  rebuildAll()                    every view state from the facade's properties
              │  for await change in services.changes() { apply(change) }
              │  tick()  ← RootView's 15 s TimelineView and scene → active
              ▼
   NowViewState · TrendsViewState · AlertsViewState · SettingsViewState · CalibrationViewState · OnboardingState?
              ▲
   Screens render view states and call action closures (RootView) → AppModel+Actions → facade
```

- **Pure mappings** (unit-tested with plain values): `ViewStateMapping.swift` (`NowMapping`,
  `CalibrationMapping`, `SettingsMapping`, `OnboardingMapping`), `ServiceHealthMapping.swift`,
  `AlertsMapping.swift`, `TrendsMapping.swift`. `AppModel` only decides *when* to call them.
- **Actions never write view states the facade owns.** They call the facade; the facade sends a
  `ServiceChange`; `apply(_:)` rebuilds from the facade's properties. Exceptions, all local UI
  state: chart window, Trends period, light/dark appearance, the pairing "in progress" flag, error
  lines under the control that failed (`SettingsFeedback`, `OnboardingState.*Message`), the share
  sheet, the optimistic Alerts draft (below).
- **Clock.** `AppModel.clock` (injected in tests) is what the UI classifies against: Now's hero and
  banners, the tab dot, the latch, "today". It is the phone clock, so DEBUG replay runs in the UI
  use speed 1 (`-replayStartMinute` jumps ahead instead; see Open questions).
- **Fixtures.** DEBUG `AppModel.fixtures()` builds fixture view states with no services, for
  previews and the fixture-based unit tests only.
- **Sensor state known (review M1).** Before the source's first state reaches it, the facade
  reports `.notPaired` by default. The model treats the state as real once a `.sensor` change has
  arrived, or the state at launch is anything but `.notPaired`, or a sensor is stored
  (`hasStoredSensor`). Until then the hero reads "Starting up", the sensor rows "checking…",
  Settings › Sensor shows "Checking for your sensor…" instead of a pairing offer, and onboarding
  is not decided.
- **Protected data (review m2).** UI preferences (`AppUIPreferences`: onboarding completed,
  light/dark, the remembered calibration need) are read and written only once
  `UIApplication.isProtectedDataAvailable` (a Bluetooth-restoration launch can start before the
  first unlock). The model retries on the protected-data notification, every change and every
  clock tick (the SwiftUI app can be created before UIKit reports it).

## `ServiceChange` → what is rebuilt

| Change | Reads | Rebuilds |
|---|---|---|
| `.readings` | `latestLiveReading`, `previousLiveReading`, `clockMismatchLatchedFor`, `readings(from:to:)` | Now hero reading + latch, Calibration's reading + latch; reloads chart + "Today so far" (async); Trends if visible, else marks it stale |
| `.sensor` | `sensorState`, `sensorSession`, `acceptedCalibrationRange`, `canStopSession`, `hasStoredSensor`, `storedSensorSerial`, `bluetoothAuthorization` | marks the sensor state known; Now state/session/`sensorNeedsCalibration`, Calibration state, Settings › Sensor (incl. `failureSince`), Onboarding pairing + warm-up; decides onboarding if due |
| `.calibration` | `recentCalibrations` | Calibration `lastSubmission`, Now fingerstick markers |
| `.trio` | `trio` | Settings › Trio, Now health (banner, TRIO row) |
| `.uploads` | `nightscout`, `dexcomShare` | Settings › Sharing, import forms (saved site), Now health |
| `.historyImport` | `historyImport` | Onboarding / Settings import progress, Settings last import |
| `.alertSettings` | `alertSettings` | Alerts (unless an edit is still on its way — see Alerts) |
| `.alertDelivery` | `alertDelivery` | Settings › Alert delivery, Onboarding permissions, Now health |
| `.storage` | `storage` | Settings › Data (size, count, retention, availability), Now health |
| `.health` | `forceQuitGap`, `clockMismatchLatchedFor`, `bluetoothAuthorization` | Now latch + health, Settings Bluetooth, Onboarding permissions |
| `.appearance` | `accent` | Settings accent (and the app tint) |
| `.replay` | `replay` (DEBUG) | Now `replayScenario` (build banner), Settings › Developer; closes an untouched onboarding |

`tick()`: `services.updateClockMismatchLatch(now:)`, then the latch mirror; reloads "Today so far"
when the local day changed.

## Screens

### Now (HANDOFF §7.3.1)

- **Hero** = `NowMapping.latestLiveReading(latestLiveReading, previous:)`: the facade's latest *live*
  reading and the delta to the previous live one. Defence in depth for S6: a reading whose source
  is not `.sensor` (DEBUG: or replay/mock) is refused here even if the facade handed it over
  (`test_S6_importedHistoryNeverBecomesTheCurrentValue`). Staleness is classified at render time
  against the clock (`GlucoseDisplayState`), so an old number is replaced by a message on time (S5).
- **Clock-mismatch latch (S1/S5).** Mirrored into Now and Calibration from the facade's persisted
  `clockMismatchLatchedFor`, OR-ed with the model's own memoryless `ClockMismatchLatch.update`: a
  reading seen dated ahead of the clock stays "not current" until a newer reading replaces it,
  whichever of the two noticed (`test_S1_nowNeverShowsAFutureDatedReadingAsCurrent`,
  `test_S1_facadeLatchKeepsAReadingFromBeingCurrent`).
- **Chart** (3/6/12/24 H): 24 h of stored readings, any source (imported history may be charted),
  from `readings(from:to:)` over `NowMapping.fetchInterval` = [min(now − 24 h, midnight − 24 h),
  now + gate tolerance); the window picker only changes the visible domain. Fingerstick markers
  from `recentCalibrations` (last 24 h), never chart points (S1).
- **Today so far**: `GlucoseStatistics.todaySoFar` over the same fetch (24 h before midnight is hypo
  context): TIR, mean, lows = `level1EventCountOverlappingPeriod` (a low that began before
  midnight counts). No readings today → "—" everywhere.
- **Grace-period countdown (D43)**: while `sensorState` is `.gracePeriod(endsAt)` and the end is
  ahead, a live h:mm:ss to `endsAt` (`GraceCountdownView`, 1 s `TimelineView`, Editorial figure
  type) under the state line, and the same countdown in the grace banner. VoiceOver reads it to the
  minute ("Grace period, 7 hours 40 minutes left"). The Now screen's clock
  (`NowRefreshSchedule`: every 15 s plus exactly at `endsAt`) switches to "Sensor expired" at zero.
  No widget countdown.
- **Status rows**: SENSOR from `sensorState` + `sensorSession` ("day 6 of 10 · 4d 7h left", keeping
  the day/time left through connection steps and transient failures); TRIO from
  `ServiceHealthMapping.trioStatus`.
- **Banners** (`AppBanners.make` over `ServiceHealth`): every problem a facade summary can report
  maps to a banner (`test_S5_everyServiceHealthProblemBecomesABanner`):

  | Source | Banner kind |
  |---|---|
  | no live reading ≥ 15 min, or a future-dated/latched one | `missedReadings` ("No reading for …" / "No current reading") |
  | `storage.availability` waiting for first unlock / failed (open or inserts, D42: "History isn't being saved" — live readings still reach alerts and Trio) | `storageUnavailable` |
  | `bluetoothAuthorization` denied/restricted; `SensorState.bluetoothUnavailable` | `bluetoothUnauthorized`, `bluetoothOff`, `bluetoothUnavailable` |
  | `SensorState` error / failed (D36/D37: replace, pair again, sensor problem, interrupted) / calibration / expired / expiring | `sensorError`, `sensorNeedsReplacement`, `sensorNeedsPairing`, `sensorProblem`, `sensorInterrupted`, `calibrationNeeded`, `sensorExpired`, `sensorExpiring` |
  | `trio.unavailableReason` (on, but no Trio App Group in this build), `trio.isFailing` or `trio.isStarving` (bridge on, outputs allowed) | `trioBridgeFailing` |
  | `trio.heartbeatError` | `trioHeartbeatFailing` |
  | `alertDelivery`: denied/provisional, not asked, banners/sounds/Time Sensitive off, volume low/muted, alarms denied/not asked, alarm scheduling failed, repeats short | `notificationsDisabled`, `notificationsNotSetUp`, `notificationSettingsIncomplete`, `alarmVolumeTooLow`, `urgentLowAlarmOff`, `urgentLowAlarmNotSetUp`, `urgentLowAlarmFailed`, `alertRepeatsShort` |
  | uploader failing / setup error / on but not configured | `nightscoutUploadFailing`, `shareUploadFailing` |
  | `forceQuitGap` | `forceQuitGap` (dismiss → `dismissForceQuitGap()`) |

  `ServiceHealthMapping.deliveryIssues` switches exhaustively over `DeliveryProblem`, so a new
  problem kind cannot be dropped silently. DEBUG builds with Trio/uploads off by D20 show them as
  off (the DEBUG banner covers it; Settings says why), not as failing.
- **DEBUG banner**: `BuildBanner.forThisBuild(replayScenario:)`, computed (no state can clear it),
  on every tab, onboarding and calibration; names the replay scenario.

### Trends (HANDOFF §6, §7.3.2; docs/statistics.md)

`TrendsMapping.make(period:readings:now:calendar:)`:
fetch [previous-period start − 24 h, now) → `GlucoseStatistics.compare` → view state. GMI is nil
below 14 calendar dates (and the screen also gates on the period); the < 70 % data-sufficiency
warning shows on every period and next to GMI (`TrendsText.gmiNote`); the TIR change is
`inRangeDeltaPoints` (nil without prior data), marked "(sparse data)" when the prior period is
under 70 %; count/streak deltas are not shown. AGP from `AGPDisplaySmoothing.smoothedForDisplay`,
empty buckets dropped, LOW/HIGH percentiles kept as flags (`AGPLineValue`) and drawn at the chart
floor/ceiling; with any HIGH percentile the top is 400 (`AGPChartScale`), so a HIGH line never sits
at a ceiling such as 250 that reads as a value (S4). 1 D / 3 D: the stored readings of each local day (`DayTrace`). Lows: level 1
events starting in the period, mean duration, `busiestWindow(hourCount: 3)` when ≥ 2 lows.
Imported-data footnote from `containsImportedReadings` (origins and span from the imported
readings in the period). After-runs row hidden (v1.1).

Recomputed on period selection (the screen shows "Computing…" instead of the old period's numbers),
on `.readings` while the tab is visible, and when the tab is opened after readings changed.
Tests: `TrendsMappingTests`, `AppModelWiringTests.test_trendsFromTheStore`.

### Alerts (HANDOFF §5; docs/alerts.md)

Rows are AlertEngine's own `AlertKind`s (the app has no alert enum; D42 added "History isn't being
saved", `storageFailing`, sound-on-silent off by default), built from `alertSettings` by
`AlertsMapping.make`; every range comes from `AlertLimits` (the Phase 1 screen's own Low 60–100 /
High 120–400 / rate 2–5 clamps are gone). An edit is `AlertsMapping.apply(edit, to:)` — the
settings types' clamping setters — then `updateAlertSettings`. Edits made before the facade
confirms build on the previous one (`alertSettingsDraft`), so quick stepper taps are not lost; the
draft is dropped once the facade's settings match. S7: urgent low has no switch and a fixed
sound-on-silent; `setEnabled`/`setSoundsOnSilent` refuse it; its snooze options stop at 30
(`test_S7_alertEditsCannotDisableUrgentLowOrExceed30MinSnooze`, `AlertsViewTests`). Sound preview
→ `previewSound` (a refusal while an alert is sounding is shown), stopped when the detail page
closes. Quiet hours are the engine's `QuietHours` (D27 wording: "Silences all alerts except Urgent
low.").

### Settings

| Page | From | Actions |
|---|---|---|
| Sensor | `sensorState`, `sensorSession`, `storedSensorSerial`, `canStopSession`, `hasStoredSensor`, `bluetoothAuthorization` | `PairingGuidance.settingsOffer` → `pair(code:)` / `pairAgain(code:)` (`PairingError.noSensorToPairAgain` is shown, never retried as a new pairing); forget sensor; stop session only if `canStopSession` (G7: hidden); calibrate |
| Trio | `trio` | `setTrioBridgeEnabled`; shows `TrioAppGroupID` to compare with Trio's Group ID, `unavailableReason`, last write, heartbeat, D20 pause note |
| Sharing | `nightscout`, `dexcomShare` | `saveNightscout(url:token:)`, `setNightscoutUploadEnabled`, `saveDexcomShare(accountName:password:receiverSerialNumber:)`, `setDexcomShareRegion` (US default, D7), `setDexcomShareEnabled`, `retryUploads`; errors under the Save button; D29/D30 notes |
| Alert delivery | `alertDelivery` | `requestNotificationAuthorization`, `requestUrgentLowAlarmAuthorization`, open iOS Settings; `refreshAlertDelivery` on appear |
| Data | `storage`, `historyImport` | import (sheet), `exportAllReadingsCSV` / `exportDiagnostics` → share sheet (`ActivityView`), `setRetention`; size + reading count; `refreshStorageSummary` on appear |
| Appearance | `accent`; light/dark is the app's own (`AppUIPreferences`) | `setAccent` |
| About | `Credits` (mirrors NOTICE.md, `AboutCreditsTests`) + font licences from the bundle | — |
| Developer (DEBUG) | `replay` | `startReplay(scenario:speed:)`, `stopReplay`, `setDeveloperLiveOutputsEnabled` (D20) |

### Onboarding (HANDOFF §4.5, §4.6, §7.3.5; D7, D26, D35)

Shown at launch — decided once the sensor state is known and protected data is available — when
onboarding was never completed and no sensor is set up (`OnboardingMapping.sensorIsSetUp`: a stored
sensor or a paired-only state — not Bluetooth or connection states), never during a replay run
(DEBUG `-replayScenario`, or an active scenario); `-onboarding` forces it, DEBUG
`-resetOnboardingFlag` clears the flag (UI tests). Completion is remembered (`AppUIPreferences`)
when the person finishes or a sensor is evidently set up.

**Never a trap (review M1).** Every step but warm-up (which has Done) offers "Set up later"
(`dismissOnboarding()`: not marked completed, so it is offered again next launch while no sensor is
set up). Pairing from inside the app — the hero's "Pair a sensor" / "Replace the sensor", the
replacement and pair-again banners — opens Settings › Sensor (`PairingGuidance.settingsOffer`
covers not paired, expired, grace over, replacement and lost pairing), a normal page with the tab
bar and the banners one tap away; the full-screen onboarding is first-run only.

- Import: saved Nightscout site → import directly; otherwise URL + token are saved first
  (`saveNightscout`), then `startNightscoutImport(scope:)`. Clarity CSV via `.fileImporter`, read
  off the main actor (security-scoped), time zone picker (current zone first),
  `startClarityImport(fileData:timeZone:)`. Progress, skipped entries and rejected future-dated
  readings from `historyImport`; stop → `cancelHistoryImport`.
- Remove the Dexcom app: the D35 "other G7 apps" warning, the Dexcom Follow note, Share upload on
  by default with US preselected; Continue saves the credentials, sets the region, turns upload on,
  and only then moves on (a save error stays on the step).
- Permissions: Bluetooth from `bluetoothAuthorization` (iOS asks when the source first uses it;
  denied → iOS Settings), notifications + Critical Alerts from `alertDelivery`, the AlarmKit step on
  iOS 26+.
- Pairing: `pair(code:)`; the step follows `sensorState` (in progress → the source's failure →
  paired) only after a connection step has been seen since the code was submitted, so the previous
  sensor's state is never shown as this pairing's result (review m3); a `PairingError` shows before
  anything reached the sensor. Retries go through
  `PairingGuidance.recovery(for:context:)` with `PairingContext(hasStoredSensor:isNewPairing: true,
  authenticatedInThisPairing:)`, where "authenticated in this pairing" = a sensor is stored now that
  wasn't when the pairing started.
- Warm-up: countdown from `sensorState.warmingUp(endsAt:)`.

### Calibration (PROGRESS D16)

`acceptedCalibrationRange`, `sensorState`, the latest live reading and the latch drive
`CalibrationRules`; submit → `submitCalibration`; the outcome is `recentCalibrations.first`
(`CalibrationMapping.lastSubmission`: refusal → `.refused`, else the source's status; neither →
"unknown", never a claimed "queued"). A thrown `CalibrationRefusal` is shown at once.
`CalibrationRules.outcomeText(_:state:now:)` explains `invalidTime` during a clock mismatch as the
clock.

## Off the main actor

| Work | How |
|---|---|
| "Today so far" stats and chart points | `Task.detached(priority: .userInitiated) { NowMapping.recent(…) }` |
| Trends statistics (up to 2 × 90 days) | `Task.detached(priority: .userInitiated) { TrendsMapping.make(…) }` |
| Clarity file read | `Task.detached { Data(contentsOf:) }` |
| Store reads | the facade's `async readings(from:to:)` |

Each reload carries a generation number; only the newest request's result is applied. The model
tracks its async work so tests can `await model.settle()`.

## Tests

`AppTests/AppModelWiringTests.swift` (the model on `PreviewAppServices`), `TrendsMappingTests`,
`AlertsViewTests`, `AboutCreditsTests`; the Gate 4 UI suite `AppUITests/ReplayLaunchUITests.swift`
launches the DEBUG app on every ReplayKit scenario (`-replayScenario <name> -replaySpeed 1
-replayStartMinute <m>`) and with no sensor.

## Open questions

- **Pipeline clock for accelerated replay.** At `-replaySpeed` > 1 (or the Developer page's faster
  speeds) replay readings are dated ahead of the phone clock, so the UI shows "Phone clock doesn't
  match" — correct for the phone clock, unhelpful for a demo. Exposing the pipeline's `now` (the
  replay clock during a run) on the facade would let `AppModel.clock` follow it. The UI tests use
  speed 1 with `-replayStartMinute`, so they are unaffected.
- **Stop session.** The facade has `canStopSession` but no `stopSession()`; the row is hidden while
  no source can stop a session (G7).
