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
  banners, the Now tab's dot, the latch, "today". It is the phone clock; in a DEBUG replay run it is the
  replay clock (`AppServices.replayClockNow`, compiled out of Release), so an accelerated replay's
  readings are current on screen. The UI tests still use speed 1 with `-replayStartMinute`.
- **Time zone and clock changes (Phase 3).** `NSSystemTimeZoneDidChange` →
  `calendarDidChange(.current)`: "Today so far" and the Now chart's data are reloaded, Trends is
  recomputed in the new zone (now if visible, else when opened), and the latch is re-checked.
  `significantTimeChangeNotification` (midnight, DST, a manual clock change) → `tick()`. Clock-time
  labels use `DisplayContext.current` (autoupdating) and follow on the next render (≤ 15 s on Now).
  The Now chart draws and scrubs only points up to `now` (`NowMapping.visibleChartPoints`), so after
  the clock is set back a future-dated reading is never selectable; the hero shows the clock
  mismatch.
- **Relaunch (Phase 3).** The Trends period is stored with the appearance (`AppUIPreferences`, read
  once protected data is available) and restored after the app is killed. A cold launch always opens
  Now (P3 review m6: a notification or widget tap lands on the current reading); a `-tab` launch
  argument picks another tab (UI tests). The tab is never stored, so nothing needed migrating when
  the Alerts tab went away (D56).
- **Tabs (D56).** "Now · Predict · Trends · Settings" (`AppTab`; HANDOFF §7.3 had "Now · Trends ·
  Alerts · Settings"). Alerts is Settings › Alerts (`SettingsRoute.alerts`), the first Settings
  group. Everything that opened the Alerts tab opens it: Now's header sound button
  (`AppModel.openAlerts()` → `openSettings(.alerts)`), and DEBUG `-tab alerts`
  (`AppModel.openTab(launchArguments:)`, so old UI-test and screenshot invocations still land on
  the list); `-tab predict` opens Predict. Notification taps and the widget deep link open Now, as
  before. Predict is a placeholder (`Screens/Predict/PredictScreen.swift`) until the D57 screen.
- **Tab dots.** `AppModel.tabsNeedingAttention()` → `TabAttention.tabs(nowBanners:settings:)`, read
  by RootView on every render and 15 s tick: Now while any S5 banner shows; Settings while the alarm
  volume is too low (D55). Pure functions of the current view states: no flag, nothing to reset.
  VoiceOver: "Settings, needs attention".
- **Fixtures.** DEBUG `AppModel.fixtures()` builds fixture view states with no services, for
  previews and the fixture-based unit tests only.
- **Stored-sensor baseline (Phase 3).** `hasStoredSensor` is only a default until
  `storedSensorKnown` turns true (bootstrap read the source's record). Onboarding takes the
  "sensor stored when this pairing started" baseline only from a known value (nil otherwise, so
  nothing counts as authenticated in that pairing), and a stored sensor appearing during a pairing
  counts as the sensor answering only when the previous read was known "not stored" — whichever
  change delivered it.
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
| `.alertDelivery` | `alertDelivery` | Settings › Alert delivery (and with it the D55 volume notice and Settings tab dot), Onboarding permissions, Now health |
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
  ahead, the screen's one live countdown: h:mm:ss to `endsAt` under the state line
  (`GraceCountdownView`, 1 s `TimelineView`, Editorial figure type; VoiceOver to the minute, "Grace
  period, 7 hours 40 minutes left"). The grace banner says only when readings stop ("Readings stop
  at 8:15 PM. Replace the sensor soon."); the SENSOR row keeps "grace period · 7h 40m left" (review
  m7). The Now screen's clock (`NowRefreshSchedule`: every 15 s plus exactly at `endsAt`) switches to
  "Sensor expired" at zero; a tick that fires a few ms early renders at its scheduled date, so the
  end still shows at zero (review m9), but a scheduled date 1 s or more ahead of the clock (entries
  left from before the clock was set back) renders at the clock (review n1). No widget countdown.
- **Status rows**: SENSOR from `sensorState` + `sensorSession` ("day 6 of 10 · 4d 7h left", keeping
  the day/time left through connection steps and transient failures); TRIO from
  `ServiceHealthMapping.trioStatus`.
- **Banners** (`AppBanners.make` over `ServiceHealth`): every problem a facade summary can report
  maps to a banner (`test_S5_everyServiceHealthProblemBecomesABanner`), except a low or muted alarm
  volume, which is Settings' (D55, below):

  | Source | Banner kind |
  |---|---|
  | no live reading ≥ 15 min, or a future-dated/latched one | `missedReadings` ("No reading for …" / "No current reading") |
  | `storage.availability` waiting for first unlock / failed (open or inserts, D42: "History isn't being saved" — live readings still reach alerts and Trio) | `storageUnavailable` |
  | `bluetoothAuthorization` denied/restricted; `SensorState.bluetoothUnavailable` | `bluetoothUnauthorized`, `bluetoothOff`, `bluetoothUnavailable` |
  | `SensorState` error / failed (D36/D37: replace, pair again, sensor problem, interrupted) / calibration / expired / expiring | `sensorError`, `sensorNeedsReplacement`, `sensorNeedsPairing`, `sensorProblem`, `sensorInterrupted`, `calibrationNeeded`, `sensorExpired`, `sensorExpiring` |
  | `trio.unavailableReason` (on, but no Trio App Group in this build), `trio.isFailing` or `trio.isStarving` (bridge on, outputs allowed) | `trioBridgeFailing` |
  | `trio.heartbeatError` | `trioHeartbeatFailing` |
  | `alertDelivery`: denied/provisional, not asked, banners/sounds/Time Sensitive off, alarms denied/not asked, alarm scheduling failed, repeats short | `notificationsDisabled`, `notificationsNotSetUp`, `notificationSettingsIncomplete`, `urgentLowAlarmOff`, `urgentLowAlarmNotSetUp`, `urgentLowAlarmFailed`, `alertRepeatsShort` |
  | `alertDelivery` volume low/muted (D55) | none on Now: the Settings notice and the Settings tab's dot |
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
at a ceiling such as 250 that reads as a value (S4). 1 D / 3 D: the stored readings of each local day (`DayTrace`, with its time zone), plotted at
their wall-clock hour (`TimeOfDayAxis.hourOfDay`: elapsed time since midnight plus the UTC offset
change, audit m17), so on a DST day every reading sits at its clock time and the 3 D days line up;
lines split at the clock change (`splitAtClockChanges`), the repeated hour's two passes share x, the
scrub maps a finger back to the first pass (a skipped hour to the jump). Lows: level 1
events starting in the period, mean duration, `busiestWindow(hourCount: 3)` when ≥ 2 lows.
Imported-data footnote from `containsImportedReadings` (origins and span from the imported
readings in the period). After-runs row hidden (v1.1).

Recomputed on period selection (the screen shows "Computing…" instead of the old period's numbers),
on `.readings` while the tab is visible, and when the tab is opened after readings changed.
Tests: `TrendsMappingTests`, `AppModelWiringTests.test_trendsFromTheStore`.

### Alerts (HANDOFF §5; docs/alerts.md) — Settings › Alerts since D56

A page in the Settings `NavigationStack` (`AlertsPage`; no stack of its own). The stack declares
both destinations: `SettingsRoute.alerts` → the list, `AlertKind` → `AlertDetailView` (sound picker
and preview, style, snooze); its path is a `NavigationPath` because it holds both types. The
Settings row's value is `AlertsText.settingsSummary` ("16 of 19 on · quiet hours off"; urgent low
always counts as on). Rows are AlertEngine's own `AlertKind`s (the app has no alert enum; D42 added "History isn't being
saved", `storageFailing`, sound-on-silent off by default). D43: the five sensor expiry reminders
(`AlertKind.sensorExpiryReminders`: 24 h, 12 h, 2 h, grace start, expired) are their own section,
"Sensor expiry reminders", in the order they come due. Each row has one switch (on/off; review m8:
two unlabelled switches on a row invited turning a reminder off instead of muting it).

**Alert style (D53).** Each alert's page has an "Alert style" choice from AlertEngine's
`allowedStyles(for:)`: Sound / Vibrate only for condition alerts, plus Silent for the one-off
announcements (it replaces D43's Sound switch; the 24 h reminder is Silent by default); "Sensor
expired" is a condition alert, so never Silent. Urgent low (`[.sound]`, S7) shows no choice, only
"Urgent low always sounds (it can't be set to vibrate)." The sound picker and "Sound on silent" show
only for Sound; Vibrate only says "Vibrates without sound. Whether it vibrates depends on Settings ›
Sounds & Haptics › Haptics. Easy to miss while asleep." (D54), and never mentions "Sound on silent",
which the engine ignores for it (D54). Edits are `AlertEdit.style` → `setStyle(_:for:)` (the engine
refuses what isn't allowed), all through `AlertStyleAdapter`. The list subtitle reads "vibrate only",
"no sound", or the sound's name and "sounds on silent". "Set all to vibrate except urgent low and
Low" (top of the screen; `AlertEdit.vibrateAllExceptUrgentLowAndLow`) turns every alert on Sound
except urgent low (S7) and Low (Michael, D54) to Vibrate only, whether on or off
(`AlertsMapping.vibrateAllKinds`, also `AlertsViewState.vibrateAllKinds`); its confirmation names
every alert it changes and says that alerts off now will vibrate if turned on later. Silent
announcements stay silent, each alert can be set back on its page, defaults are unchanged.
DEBUG `-silenceAlertAudio` also passes `NoAlertHaptics` (no vibration). Screenshots:
`alerts-expiry-reminders-*.png`, `alerts-expiry-24h-*.png` (`test_alertsShowTheSensorExpiryReminders`,
launched with the old `-tab alerts`), `alerts-low-vibrate-only-*.png`, `alerts-list-vibrate-only-*.png`
(`test_lowCanVibrateOnly`, through the Settings row), with `SENSOR_WRITE_SCREENSHOTS=1`. Rows are built from `alertSettings` by
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

Groups top to bottom: ALERTS (D56), ALERT DELIVERY, SENSOR, TRIO, SHARING, DATA, DIAGNOSTICS,
APPEARANCE, ABOUT (DEVELOPER in DEBUG).

**Alarm volume (D55).** A low alarm volume is not a Now banner. While
`settings.delivery.alarmVolume` is `.tooLow` (below `AlertLimits.lowAlarmVolume`, 25 %), Settings
shows one compact line at the top, "Alarm volume 15%. Alarms may be hard to hear; turn the volume
up." with a link to Alert delivery (`AlarmVolumeNotice`, `SettingsText.alarmVolumeNotice`), the
"Alarm volume" row's value is red, and the Settings tab shows the red dot. All three are computed
from `settings.delivery`, which every `.alertDelivery` change rebuilds; AlertEngine observes the
volume while the app is in the foreground and the services publish each change as `.alertDelivery`
(p5-alerts), so they appear and clear live, with no dismiss button and no relaunch
(`AppModelWiringTests.test_alarmVolumeNoticeAndSettingsDotFollowEveryDeliveryChange`). Critical
delivery problems (notifications off, urgent-low alarm off, …) stay Now banners. Screenshots:
`settings-volume-notice-{light,dark}.png`, `tabbar-{light,dark}.png`, `predict-placeholder-{light,dark}.png`
(`ScreenshotTests`; the simulator can't set a low volume), and from the running app
`settings-root-app-*.png`, `predict-placeholder-app-*.png` (`test_settingsAlertsAndThePredictTab`).

| Page | From | Actions |
|---|---|---|
| Alerts (D56) | `alertSettings` (`AlertsViewState`) | see Alerts above |
| Sensor | `sensorState`, `sensorSession`, `storedSensorSerial`, `canStopSession`, `hasStoredSensor`, `bluetoothAuthorization` | `PairingGuidance.settingsOffer` → `pair(code:)` / `pairAgain(code:)` (`PairingError.noSensorToPairAgain` is shown, never retried as a new pairing); forget sensor; stop session only if `canStopSession` (G7: hidden); calibrate |
| Trio | `trio` | `setTrioBridgeEnabled`; shows `TrioAppGroupID` to compare with Trio's App Group (`SettingsText.trioAppGroupHelp`: Trio shows it only as "Group ID: …" in glucose notifications with Add Glucose Source to Alarm on; its CGM screen's "CGM address :" line confirms the heartbeat), `unavailableReason`, last write, "N readings held back since …" (`heldBackReadings`/`heldBackSince`, the launch re-seed), heartbeat, D20 pause note |
| Sharing | `nightscout`, `dexcomShare` (a failing uploader's line from `ServiceHealthMapping.uploadProblem`: setup, queue file, connection error, refusal, readings held because they are dated ahead of the phone's clock, readings dropped and why) | `saveNightscout(url:token:)`, `setNightscoutUploadEnabled`, `saveDexcomShare(accountName:password:receiverSerialNumber:)`, `setDexcomShareRegion` (US default, D7), `setDexcomShareEnabled`, `retryUploads`; errors under the Save button; D29/D30 notes |
| Alert delivery | `alertDelivery` | `requestNotificationAuthorization`, `requestUrgentLowAlarmAuthorization`, open iOS Settings; `refreshAlertDelivery` on appear |
| Data | `storage`, `historyImport` | import (sheet), `exportAllReadingsCSV` / `exportDiagnostics` → share sheet (`ActivityView`), `setRetention`; size + reading count; `refreshStorageSummary` on appear. The diagnostics row says what the log holds (`SettingsText.diagnosticsContents`: sensor name and serial, glucose values, the Nightscout host name; no passwords, tokens or pairing codes) |
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
  readings from `historyImport` (`rejectedFutureDated` or `skipped["futureDated"]`, not counted again
  as skipped entries; `OnboardingText.futureDatedNote`); a stopped import's message in full (`OnboardingText.importFailure`:
NightscoutKit's `unusableHistory` names the date range and what to do); stop → `cancelHistoryImport`.
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

## Performance (Phase 3)

`NinetyDayPerformanceTests` (hosted, Debug, simulator) seeds a production-role GlucoseStore on disk
with 181 days at 5-minute cadence (52k readings — the Trends 90 D fetch window after six months) and
measures the model's own work, median of 7 runs after a warm-up:

| Work | Budget | Measured (M4 host, simulator, Debug) |
|---|---|---|
| Trends 90 D: fetch + compare + AGP + mapping | 500 ms | ~200 ms (fetch ~115 ms, statistics ~55 ms) |
| Now: fetch 48 h + chart 24 H + "today so far" | 100 ms | ~3 ms |
| One scrub hit test on 24 H (a drag update) | 2 ms | ~0.23 ms |

A failure message names the median, best and budget; re-run the suite alone before treating one
as a regression (other builds may share the machine).

## D45 listen mode and D47 packet recording

`refreshSensor` (every `.sensor` change; a mode switch also sends `.calibration`, `.trio`, `.uploads`)
maps the facade's `connectionMode` into `now.connection`, `settings.connection` and
`calibration.listening`, and `recordsRawGlucosePackets` into `settings.packetRecording`. The outputs'
`offWhileListening` make `ServiceHealthMapping` report Trio and uploads as off (no S5 banner); the
screens word it "off while listening".

| Where | While listening | Action → facade |
|---|---|---|
| Onboarding | A "How to connect" step after Welcome, before any pairing step: the two choices ("Listen alongside the Dexcom app (this sensor)", "Pair this app (Dexcom app removed)"), one line each; **nothing preselected, ever**, and no Continue until one is chosen. The pairing step says before the code field: "Pairing takes over the sensor's connection: the Dexcom app on this phone will stop receiving readings. Delete the Dexcom app first." Listening skips Remove the Dexcom app and Pairing and adds a Listening step (status line, the source's problem in listen words, Continue always offered); Dexcom Share upload is not on by default (D7's default is for pairing mode). | Continue → `setConnectionMode(_:)` when the choice differs (confirmation first if a sensor is stored); a refusal stays on the step (`ConnectionModeText.errorText`, nothing changed) |
| Settings › Sensor | Until a choice is made (`AppUIPreferences.connectionModeChosen`; a new install's stored `.pair` is only a storage default): the CONNECTION choice first, nothing selected, no code field. Pairing: the takeover warning above every code field. Listening: "Listening — the Dexcom app owns the connection"; calibrate and pairing offers replaced by one-line explanations; Forget becomes "Stop following this sensor" (confirmed; G7Kit §14: how listen mode follows the next sensor) | choice → confirmation (switching to Pair says the takeover warning) → `setConnectionMode(_:)` (the mode the facade is already in only records the choice); the choices wait while it runs; a refusal (`.replayActive`, `.couldNotSave`, `.credentialStoreFailed`) is shown under them. Stop following → `forgetSensor()` |
| Settings main | Connection row; Trio, Nightscout, Dexcom Share rows "off while listening" | — |
| Trio, Sharing pages | switches off and disabled, "Off while listening alongside the Dexcom app"; Retry uploads hidden; site and credentials can still be saved | — |
| Now | Before a choice, no sensor reads "No sensor set up" with "Set up the sensor" (Settings › Sensor's choice), never "Pair a sensor". Listening: TRIO row "off while listening", the listening line under the status rows, no Pair/Calibrate button in the hero (`ListenModeRules.hero`; an ended sensor says to start the new one in the Dexcom app and stop following this one), no followed sensor reads "Not following a sensor" | — |
| Calibration (Now menu, flow, Settings) | "Calibrate in the Dexcom app: while listening, this app doesn't calibrate the sensor." (`CalibrationRules.availability`) | — |
| Banners, SENSOR rows | G7Kit's three transient listen failures (`listenSessionLengthUnknown`, `listenNoAuthenticatedConnection`, `listenConnectionRejected`, by kind while listening) stay up as warnings with their own words (`ListenModeRules.failure`): "Waiting for session details", "Connection not confirmed", "Sensor rejected the connection". Missed readings and alerts are unchanged. | — |
| Settings › DIAGNOSTICS | "Record raw glucose packets" (D47, off by default) with its line | `setRecordsRawGlucosePackets(_:)` |

`PairingError.notAvailableInListenMode` reads `ConnectionModeText.pairingWhileListening`. UI tests
start each launch in pairing mode (DEBUG `-resetConnectionMode`, AppEnvironment) and switch on the
simulator's live source (Bluetooth unsupported there) or are refused in a replay run.
A choice is recorded when onboarding's Continue or Settings' confirmation succeeds; listening, or a
sensor stored in pairing mode (an install from before D45), counts as chosen.

"Stop following this sensor" (shown while a sensor is followed, `ListenModeRules.offersStopFollowing`)
→ `forgetSensor()`, after which the facade looks for the Dexcom app's connection to the next sensor at
once (`LiveAppServices.forgetSensor`).

Every failure kind whose source text would tell a listening person to pair (or names this app's own
connection) has listen wording (`ListenModeRules.failure`): credentials unavailable ("Waiting for the
phone to unlock"), the three listen failures, another app refused, and the pairing kinds (primary-only
today). An ended sensor adds "Start the new sensor in the Dexcom app, then stop following this one".
Calibration banners say to calibrate in the Dexcom app and have no button. Onboarding always confirms
a switch away from listening (`OnboardingState.continueNeedsConfirmation`).

**Connection setting unresolved** (`AppServices.connectionSettingProblem`, services review m2/m3).
The critical banner names the cause (`ConnectionSettingProblem`: the file couldn't be read, the
stored connection of the other mode was kept, or a failed switch couldn't save the previous choice)
and hides the source's "credentials unavailable" banner, which would contradict it. Settings › Sensor
asks for the choice again and says why; onboarding's Continue always asks first and always calls
`setConnectionMode` (which rewrites the setting even for the mode shown); the packet-recording switch
says a change lasts only until a restart.

**Not connected (P3 review m1).** Once a mode is chosen, no paired sensor (pairing: `.notPaired`) or
no followed sensor (listening: no followed serial and no session once the stored record is read)
raises the calm "Not connected to a sensor" banner (warning), so it never looks like monitoring is
running.

Screenshots: `docs/screenshots/listen-*.png` and `first-run-*.png` (UI tests).

## Widget (DEBUG replay marker, audit m9)

`WidgetSnapshot.isReplay` is set when the latest reading's source is `.replay` or `.mock` — only in
DEBUG (`#if DEBUG` in `WidgetSnapshot.make`); the widget then shows "REPLAY" beside the reading
(`WidgetEntryContent.showsReplayMarker`, `ReplayMarker`, the inline text), and draws nothing for
it in Release. The field is additive: older snapshots decode as false.

## Tests

`AppTests/AppModelWiringTests.swift` (the model on `PreviewAppServices`), `TrendsMappingTests`,
`AlertsViewTests`, `AboutCreditsTests`; Phase 3: `TimeAndClockFailureModeTests` (time zone, DST,
clock changes, the m17 overlay), `RelaunchAndCarryOverTests` (relaunch, carry-overs, m18 future-dated
import display, copy fixes), `NinetyDayPerformanceTests`, `ListenModeWiringTests` (D45/D47),
`UploadAndImportTextTests`; Phase 5: `NavigationTests` (D56 tabs, `-tab alerts`, Now's alerts
shortcut, the Settings ALERTS summary, D55 tab attention and notice text); UI: the listen-mode tests
and `test_settingsAlertsAndThePredictTab` in `ReplayLaunchUITests`;
the Gate 4 UI suite `AppUITests/ReplayLaunchUITests.swift`
launches the DEBUG app on every ReplayKit scenario (`-replayScenario <name> -replaySpeed 1
-replayStartMinute <m>`) and with no sensor.

## Open questions

- **Stop session.** The facade has `canStopSession` but no `stopSession()`; the row is hidden while
  no source can stop a session (G7).
