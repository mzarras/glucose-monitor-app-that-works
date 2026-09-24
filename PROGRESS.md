# PROGRESS

Orchestrator log for the build described in `HANDOFF.md`. Only the orchestrator edits this file.

## Status

| Phase | State |
|---|---|
| 0 — Bootstrap | done (2026-09-23) |
| 1 — Parallel build | done (2026-09-23): all 7 workstreams merged into `integration`; gates 1–3 PASS |
| 2 — Integration | in progress: contract D36/D37 adoption on `p2-adopt` (review FAIL → fixing); Integrator A (`p2-services`, services + pipeline) and B (`p2-app`, app model + flows, from A's facade 484196c) running |
| 3 — Hardening | not started |
| 4 — Device build | not started |

### Workstreams (Phase 1)

| WS | Agent | Branch / worktree | State | Review | Merged to `integration` |
|---|---|---|---|---|---|
| WS1 G7Kit | ble-engineer | `ws1-g7kit` / `../wt-ws1-g7kit` | done (43d55b7): 142 tests, 99.04% cov Messages/ | **PASS** (after 3 review rounds) | **yes** — 1ad1b27 |
| WS2 Store + Replay | data-engineer | `ws2-store-replay` / `../wt-ws2-store-replay` | done (a1f0c6c): 92 + 39 tests, 98.2% / 97.3% cov | **PASS** (after 2 fix rounds) | **yes** — 3b51811 (+ a4a782e store compile-out gate); gates PASS on merged result |
| WS3 Stats | stats-engineer | `ws3-stats` / `../wt-ws3-stats` | done (de6da6b): 150 tests, 99.88% cov, 90 d in 5.8 ms release | **PASS** (after 2 fix rounds) | **yes** — 3002c9d; gates build+tests+safety PASS on merged result |
| WS4 Alerts | alerts-engineer | `ws4-alerts` / `../wt-ws4-alerts` | done (959fb80): 219 tests, 99.06% cov | **PASS** (after 4 review rounds) | **yes** — f9ffac4 |
| WS5 UI + Widgets | ui-engineer | `ws5-ui` / `../wt-ws5-ui` | done (ea2e587): 68 + 64 tests | **PASS** (after 3 review rounds) | **yes** — 5421924 |
| WS6 TrioBridge | trio-integrator | `ws6-trio` / `../wt-ws6-trio` | done (cbf5619): 62 tests, 97.8% cov | **PASS** (after 2 fix rounds) | **yes** — 9305a72; gates build+tests+safety (S2–S6) PASS on merged result |
| WS7 Import + Follow | sync-engineer | `ws7-sync` / `../wt-ws7-sync` | done (a70f3ae): 111 tests, 91.9% cov | **PASS** (after 3 fix rounds) | **yes** — 6113de7; gates PASS on merged result (480 tests, S1–S6) |

### Merge flow

`ws*` branch → safety-reviewer PASS → merge into `integration` → `scripts/check.sh` gates 1–3 on the
merged result (with the rules that workstream owns) → next. `integration` merges into `main` only when
**all** §10 gates pass, including gate 4 (replay run), which first becomes possible in Phase 2.

## Decisions

| # | Decision | Why |
|---|---|---|
| D1 | App name **Sensor** (working name, may change), bundle ID `com.mzarras.sensor`, widget `com.mzarras.sensor.widgets`. Repo is local only; no GitHub remote yet. | Michael, §13 Q1. Display name is one setting (`APP_DISPLAY_NAME`); rename before first device pairing to avoid losing data. |
| D2 | Team ID lives only in gitignored `Config/Signing.xcconfig` (derived from Trio's bundle ID). Trio App Group = `group.org.nightscout.$(DEVELOPMENT_TEAM).trio.trio-app-group`. This app's own group = `group.com.mzarras.sensor`. The app entitlements include both groups; the widget only its own. | §13 Q2. Trio `Config.xcconfig:18` defines `TRIO_APP_GROUP_ID`; Trio's `AppGroupSource.swift:34` reads Info.plist `AppGroupID` = `$(APP_GROUP_ID)` = `$(TRIO_APP_GROUP_ID)` (`Trio.xcodeproj/project.pbxproj:5059`). WS6 confirms. |
| D3 | Integrate against `mzarras/Trio` `main` @ `29350e31a` (v0.8.4 merge). Any Trio patch goes on a new **local** branch in the fork, never pushed without asking. | §13 Q3. |
| D4 | Critical Alerts built in fully from the start. The entitlement itself is a switch (`SENSOR_APP_ENTITLEMENTS` in `Config/Signing.xcconfig`) because signing fails until Apple grants it to the team. Code always requests `.criticalAlert` authorization (harmless without the entitlement) and falls back to Time Sensitive + audio playback. | §13 Q4. Apple grants the entitlement per team; Michael must apply. |
| D5 | Deployment target iOS 17.0 (matches Trio). | §13 Q5. |
| D6 | Nightscout: `https://diabetes.mzarras.com`; token supplied later, entered at runtime only (Keychain). This app uploads CGM entries; Trio's CGM upload off (WS6 confirms feasibility). No writes to the live site during development — mock server only. | §13 Q6. |
| D7 | Dexcom Share upload **in v1 and turned on** for Michael (region US). Credentials entered in-app only (Keychain). The uploader still ships as a setting; onboarding offers it with US preselected. | §13 Q7 (changes handoff's "off by default" for this build). |
| D8 | Persistence: GRDB 7.11.1, pinned exactly. | §4.4 recommendation; deterministic background writes, fast range queries. |
| D9 | Contract additions beyond §4.3 (all in `GlucoseCore`): `SensorState.bluetoothUnavailable(BluetoothIssue)`, `SensorSession`, `CGMSource.currentSession`, `LiveReadingGate` (S2/S6 check every consumer calls), `TrendArrow` (single §7.5 threshold constant + Nightscout names), `GlucoseBand`/`GlucoseThresholds`, `GlucoseReadingRepository`, `DiagnosticLog`, `GlucoseUnit`; `Codable`/`Hashable` on the core types. | S5 needs BLE state; S2 needs session bounds downstream; shared vocabulary keeps UI, stats, uploads and Trio consistent. |
| D10 | Added package `WidgetCore` (snapshot model, App Group snapshot I/O, timeline entries), owned by WS5. | §7.4 requires snapshot and timeline tests; a package makes them host-testable. |
| D11 | (**Confirmed by Michael 2026-09-23.**) S6 vs §10 gate 4 / §11 step 1: the alert engine may accept `.replay` readings **in DEBUG builds only** (`LiveReadingGate.validateAllowingReplay`, compiled only under `#if DEBUG`). Trio bridge and uploaders never accept replay. | Gate 4 requires alerts to fire on replay scenarios; S6's purpose (no non-sensor data reaching live consumers in a real build) is preserved because replay code does not exist in Release (`check.sh` verifies with `nm`). |
| D12 | All tests use XCTest; safety tests named `test_S<n>_…`. Packages declare iOS 17 + macOS 14 so `swift test` and coverage run on the host. | Gate 3 greps names; host tests are fast. |
| D13 | Sounds and fonts are copied flat into the bundle root from `Resources/Sounds` and `Resources/Fonts` (file names must be unique). | `UNNotificationSound` requires sounds in the main bundle; `UIAppFonts` lists file names. |
| D14 | Subagents are dispatched as general-purpose agents with the full role prompt (§2 verbatim, working rules, brief, return format) embedded; opus for ble/alerts/trio/reviewer roles. The `.claude/agents/*.md` definitions are committed and load in future sessions. | Custom agent types are read at session start, so this session could not select them by name. |
| D15 | Branch model: `main` = Phase 0 bootstrap only until all §10 gates pass; day-to-day orchestrator work happens on `integration`; each workstream branches from `integration` in `../wt-<ws>`. | §10: every merge to `main` needs all gates; gate 4 needs Phase 2. The Phase 0 bootstrap commit itself could not pass gates 3–4 (no feature code yet). |
| D16 | **Sensor calibration added to v1** (not in HANDOFF). G7Kit ports xDrip4iOS 7.1.0's primary-mode calibration (`0x34` command, `0x32` bounds record, all rejection reasons); UI requires re-typed confirmation, warns on > 20 mg/dL / 20% difference from the current reading and when not steady. A calibration is never a reading (S1); no app-side calibration math. Nightscout "BG Check" upload and chart markers beyond the Now chart are v1.1. | Michael, 2026-09-23. |
| D17 | Alarm audibility on silent: in-app `AVAudioSession .playback` while awake for a BLE event is the primary path (xDrip4iOS "override mute" model); Time Sensitive notifications for banner/vibration; Critical Alerts optional, used automatically if ever granted. Per-alert "Sound on silent" setting. Missed-readings/signal-loss alarms while the app is suspended are vibrate-only on silent (Time Sensitive) — accepted by Michael; no keep-alive technique. | Michael prefers not to depend on Critical Alerts; Time Sensitive does not bypass the silent switch. |
| D18 | Phase 0 safety review (FAIL → fixed): `LiveReadingGate` also refuses numeric values outside `GlucoseValue.sensorReportableRange` (40...400, G7SensorKit `GlucoseLimits`), non-finite trend rates, and malformed sessions (`SensorSession.isWellFormed`); repository `latestReading()` replaced by `latestLiveReading()` (never imported); ±2.5 min = ≤ 150 s inclusive and applies across import origins; `CGMSource` stream rules (unbounded, one instance, not finished by `stop()`); calibration contract (`CalibrationRequest`, `CalibrationStatus`, `CalibrationUpdate`, `CalibrationRefusal`, `CalibratingCGMSource`). `check.sh`: fresh derived data / scratch paths per run, 0 tests fails, skipped or XCTSkip/XCTExpectFailure safety tests fail, S6 compile-out checks with Debug positive controls, S6 caller lint, plist lint, gate 4 requires both suites; `scripts/check-selftest.sh` proves planted defects are caught. | Reviewer blockers B1 (cached builds hid warnings), B2 (no value-range check), majors M2–M6. |
| D19 | **§11 steps 2–5 (live sensor, Trio, soak) use a Release build.** DEBUG builds contain ReplayKit and the replay-accepting alert path (D11); they are for §11 step 1 only. | Reviewer M1: keep replay acceptance out of any build that talks to a real sensor. |
| D20 | Store roles (Phase 0 re-review B3): a **production** repository stores only `.sensor`/`.imported`, throws `GlucoseReadingRepositoryError.sourceNotAllowed` for `.replay`/`.mock`, and purges any such rows on open; replay runs use a separate DEBUG-only **replay** repository (in-memory or separate file). `latestLiveReading()` = latest `.sensor` in production, latest `.replay`/`.mock` in replay. In DEBUG builds the Now screen shows a persistent "DEBUG BUILD" banner, and Phase 2 wiring keeps the Trio bridge and uploaders off in DEBUG unless a developer switch is on. `check.sh` deletes fresh build trees after each run (`KEEP_BUILD_DIRS=1` keeps them), the `.replay`/`.mock` lint tracks `#if DEBUG` blocks per line, and the self-test also plants a Release symbol leak and an unguarded `.mock` construction. | Reviewer B3 (replay rows could reach the production DB shared by DEBUG and Release builds), n1–n3. |
| D21 | **LOW/HIGH to Trio: LOW → 39, HIGH → 401** (`TrioBridge` `OutOfRangePolicy` sentinel for both), set explicitly in the app wiring with a comment citing this decision; the package default stays "withhold both" so it cannot be enabled by accident. Stored readings, the UI, stats and alerts keep the flags (S4); 39/401 exist only in the Trio payload as the ecosystem's LOW/HIGH encoding (Nightscout renders 39/401 as LOW/HIGH, `sandbox.js:249-252`). Not 40/400 (S4). | Michael, 2026-09-23, after WS6 evidence: Trio's native G7 path sends 40/400 and drops the flag; oref treats 39 as a real low (SMB off, zero temp); withholding lets scheduled basal resume during a long LOW. Michael chose 401 for HIGH (matches Trio's native behaviour) over withholding HIGH. |
| D22 | No Trio patch. Michael selects Trio's existing **xDrip4iOS** CGM source. "Trio not consuming for 15 min" is not detectable (Trio writes nothing to the group) and is not built; bridge write failures still alert. Single upload: Trio → Nightscout → "Allow Uploading" ON, "Upload Glucose" OFF (this also stops Trio uploading manual fingersticks). | Michael, 2026-09-23 (WS6 findings, `docs/trio-bridge.md`). |
| D23 | Chart scrubbing with haptic ticks (Now chart, Trends 1 D/3 D): drag selects the nearest **real** reading (never interpolated, S1), callout shows value/time (LOW/HIGH as text, S4), selection haptic on each change, no tick and "No data" inside gaps > 15 min; accessible via Swift Charts audio graph. Settings → Appearance: System (default) / Light / Dark; widgets follow the system. Dark mode itself was already in scope (§7.1). | Michael, 2026-09-23. |
| D24 | Hypo events follow the 2023 consensus Table 4 (Battelino et al., Lancet Diabetes Endocrinol 2023;11:42–57, p. 50): level 1 ends after ≥ 15 consecutive min ≥ 70, **level 2 ends after ≥ 15 consecutive min ≥ 54** (changes HANDOFF §6, which ended both at ≥ 70). | Michael, 2026-09-23, after the WS3 reviewer verified the primary source. |
| D25 | **Database lives in the app's own container** (Application Support, `completeUntilFirstUserAuthentication`, included in backup); only the widget snapshot lives in the App Group. Deviates from HANDOFF §4.5, which put both in the App Group. Both stores refuse numeric values outside 40...400 (`GlucoseReadingRepositoryError.implausibleValue`, whole batch). | WS2: iOS terminates a suspended app holding a SQLite lock on a file in a shared container (0xDEAD10CC); only the app opens the DB — the widget reads the snapshot (D10), which is what §4.5's locked-read requirement needs. Store-level range check is defence in depth for S1 (WS2 open question 4). |
| D26 | **AlarmKit for urgent low** (iOS 26+ at runtime; deployment target stays 17.0): urgent low and its repeats are scheduled as system alarms that ring on silent and in Focus while the app is suspended; other alerts unchanged; older iOS falls back to D17. Needs `NSAlarmKitUsageDescription` (added), an onboarding permission step, a Settings row, and a Stop/Snooze intent. | Michael, 2026-09-23 (WS4 finding: Loop uses AlarmKit for this; closes the urgent-low-repeat gap between BLE wake-ups without the Critical Alerts entitlement). |
| D27 | Quiet hours silence every alert except urgent low, exactly as HANDOFF §5 (including Low and missed readings). | Michael, 2026-09-23, asked explicitly. |
| D28 | `CGMSource.currentSession` lifetime pinned: non-nil across routine disconnects and relaunches until the session ends; `nil` means "no valid session". TrioBridge removes Trio's payload only on positive evidence (new session, session ended, `clear()`), never because of a transient `nil`. | WS6 delta review B1: a transient nil session would have deleted Trio's payload at exactly the moment Trio polls. |
| D29 | **Nightscout LOW = sgv 39** (displays "LOW"). Nightscout's own web/push alarms ignore 39 and auto-send "All Clear" (cgm-remote-monitor 15.0.8 `simplealarms.js:21`, `bgnow.js:96`, `notifications.js:52,151-152`); `docs/following.md` states this plainly and makes LoopFollow (alarms on 39) the required follower app for anyone relying on alarms. HIGH = 401. | Michael, 2026-09-23 (WS7 review B1). |
| D30 | **Dexcom Share LOW/HIGH = 39/401** (not withheld), to be verified with a real follower in §11 step 4a (Dexcom Follow shows LOW/HIGH and alarms); revert to withholding if it doesn't. | Michael, 2026-09-23 (WS7 evidence: LoopKit's Share reader treats < 40 / > 400 as below/above range). |
| D31 | G7 raw glucose 0, 0x0FFF and 0xFFFE are "no value" (withheld, logged, surfaced) — never LOW/HIGH; other raw < 40 → LOW, > 400 → HIGH (G7SensorKit mapping). No real LOW/HIGH G7 packet exists in any reference: capturing one is a §11 item before relying on HIGH → 401 in closed loop. | WS1 review M1: a misread packet would otherwise become HIGH and reach Trio as 401. |
| D32 | Design tokens: light `high` #C58A2B → **#B07B26** (the §7.1 value is 2.64:1 on the background, fails 3:1) and `veryHigh` #8A5A12 → **#754D0F** (keeps the step between them); dark values unchanged; dark accents #4BAA7E, #D57B53, #6A92C8, #EDE8DE. Recorded in `docs/design-tokens.md`. | §7.1 requires WCAG AA; WS5's contrast test, accepted by the WS5 reviewer. |
| D33 | Stores also reject (whole batch) non-finite trend rates (`.nonFiniteTrendRate`, never rewritten to nil) and readings dated later than the store clock + `LiveReadingGate.futureTolerance` (`.futureDated`); `insert` returns readings exactly as passed. Importers skip future-dated rows (counted). | WS2 review M1: rewriting NaN → nil let a parse-fault reading pass the gate downstream; reviewer's contract note on future-dated rows becoming the current value. |
| D34 | AlarmKit details (WS4): precedence Critical Alert > AlarmKit > D17; urgent-low repeat interval 2–5 min (was 1–5) to keep ≥ 60 min of pre-scheduled repeats under iOS's 64 pending-notification limit; alarm title is just "Urgent low" (no value — pre-scheduled repeats would show a stale number, S1); no separate Snooze button (Stop = acknowledge, ≤ 30 min); a backwards clock jump ends an urgent-low snooze (errs loud). | Orchestrator, following WS4's evidence; S1/S7 considerations. |
| D35 | Residual P1c risk accepted: if a second primary-mode G7 app on the same phone sends a spoofed `05 01 01` milliseconds before the sensor's real rejection, one genuine live `0x4E` could be published (backfill from that window is discarded). Not holding live readings until disconnect, because Trio's heartbeat reads at sensor disconnect (+5 min dosing latency for every reading otherwise). Conditions: pinned test, documented in `docs/g7-protocol.md` §3, §11 item, and Phase 2 onboarding/diagnostics flag other G7 apps. | WS1 second delta review concurred; setup forbids a second primary collector (HANDOFF §4.6). |

## Discrepancies with HANDOFF (resolved)

- CV target: HANDOFF "≤ 36%" kept (consensus tables print "<36%"; differs only at exactly 36.0).
- Trends "prior period" = the same number of calendar days before the current period (1 D = today so far vs all of yesterday), matching §7.3's "vs yesterday" wording; GMI shown when the period touches ≥ 14 local calendar dates.

- Mockups are in `designs/`, not `design/`.
- Trends mockup shows a 7/14/30/90 D selector, a forecast line (Now), and an "In range after runs" row; §7.3/§7.5/§6 win: 1/3/7/14/30/90 D, no forecast, after-runs row hidden until v1.1.
- xDrip4iOS has a `7.1.1` tag after `7.1.0`. Reference checkout is `7.1.0` as specified; WS1 reviews the `7.1.0..7.1.1` diff for G7 fixes and reports.
- Trio's App Group key is resolved through Info.plist `AppGroupID`, not a hard-coded string (see D2).

## Phase 2 must-dos (carried from reviews)

- **Trio heartbeat (WS6 review M1):** publish the G7 peripheral + service/auth-characteristic UUIDs into Trio's App Group (xDrip4iOS 7.1.0 `CGMG7Transmitter.swift:875-876`) so Trio is woken every ~5 min; without it Trio will not loop in the background on DASH/Dana/Medtrum. Pending WS1's assessment of a second central on the authenticated sensor. §11 step 4 must verify closed loop, backgrounded, locked, 30+ min.
- Wire `OutOfRangePolicy` to LOW→39 / HIGH→401 explicitly, citing D21; add a `check.sh` lint that `.writeSentinel` appears outside `Packages/TrioBridge` only in lines citing D21 (WS6 review m7).
- App calls `TrioBridge.publish([], session:)` on foreground and on a timer so a failed write retries without waiting for the next reading (WS6 review m4); re-seed the last ~5 h of `.sensor` readings on launch.
- In DEBUG builds keep Trio bridge and uploaders off unless the developer switch is on (D20).

- Uploaders don't flush on their own: the app calls `ReadingUploader.flushIfDue()` after each submitted reading and on foreground/background time, `flush()` after credential changes; queue directory in the App Group container; Nightscout token + Share credentials via `KeychainCredentialStore`; import checkpoint via `UserDefaultsNightscoutImportCheckpointStore`; `deviceName` from `APP_DISPLAY_NAME` (WS7).
- NOTICE.md at merge: xDrip4iOS Share files (WS7 list); cgm-remote-monitor (AGPL-3.0, reference only, no code); share2nightscout-bridge (**GPL-3.0-only** per its package.json — WS7 guessed MIT; reference only); LoopKit dexcom-share-client-swift (MIT, reference); micro-ecc etc. from WS1.

- Store opening before first unlock (BLE state-restoration launch after reboot) throws by design: retry on `protectedDataDidBecomeAvailable`, surface S5 until open, and hold incoming readings in memory meanwhile (G7 backfill covers the rest); base backfill requests on the latest *stored* reading (WS2).
- DEBUG accelerated replay: the app uses `ReplayClock.now()` for staleness, alerts and the gate's `now` in replay wiring (WS2).

- Contract additions deferred to Phase 2 (to avoid breaking in-flight exhaustive switches): `SensorState.calibrationRequired(code:)` / `.calibrationError(code:)` (WS1 stand-in: `.error(code: algorithmState)`), `CalibrationRefusal.invalidTime` (stand-in: immediate `.unknown`). Update WS4/WS5 switches in the same change.
- Signal loss must be derived from reading age, never from `SensorState` (G7Kit suppresses connecting/authenticating after the first sensor state; WS1 review minor 8).
- Hosted (simulator) Keychain round-trip tests for G7Kit and NightscoutKit credential stores (WS1 review M3, WS7): accessibility `AfterFirstUnlock`, not synchronizable.
- Trio heartbeat: WS1 assessed it as low risk (Trio subscribes to Receive_Authentication only, never writes); implement per `docs/trio-bridge.md` "Heartbeat wiring".

- TrioBridge follow-ups (WS6 re-review r1/r2, minor): doc note that after a relaunch a leftover ended-session payload is replaced only by the next write; a named test for a sensor stopped early before grace end.

- NightscoutKit wiring (WS7): `try` on uploader factories (one uploader per queue file, enforced); `credentialsChanged()` then `flush()` after saving credentials; `flush()` again after `.alreadyFlushing`; show `rejectedFutureDated` / `skipped[.futureDated]` in import progress.
- Stats wiring (WS3): fetch readings for [period start − 24 h, now) (hypo context); "Today so far → lows" = `level1EventCountOverlappingPeriod`; show the data-sufficiency warning next to GMI.

- AlertEngine wiring (WS4, `docs/alerts.md` §9): add `StopUrgentLowAlarmIntent` in the app target; pass `SystemAlarmAdapter(makeStopIntent:)` to `AlertService`; connect `UrgentLowAlarmIntentBridge.shared`; onboarding step `requestUrgentLowAlarmAuthorization()`; Settings row from `deliveryStatus.urgentLowAlarm`; call `start()`; feed `.reading` only with readings returned by `insert` (after the gate); tick ~1/min in foreground and on every wake; hook `UNUserNotificationCenterDelegate` to `handleNotificationResponse`; DEBUG replay → `acceptsReplayReadings`.

- GlucoseStore: comment in `StoreSchema` that equal-date ordering depends on `rowid` (never run `VACUUM` without reconsidering) (WS2 delta review minor).
- NightscoutKit: release the old `ReadingUploader` (incl. status-stream tasks) before creating a replacement; surface `QueueFileInUse` as an S5 error (WS7 n3).

- Alert threshold ranges: one source of truth — the UI clamps (WS5 `AppModel.updateAlert`: Low 60–100, High 120–400, rate 2–5) must use AlertEngine's `AlertLimits`, not its own numbers (reconcile in wiring).

- Persist `NowViewState.clockMismatchLatchedFor` across app relaunch; carry it over on every view-state rebuild and mirror into `CalibrationViewState` (WS5).

- Map G7Kit's new failure reasons in AlertEngine and UI (`sensorFailed`, `sessionStopped` → sensor-ended alert; `rejectedAfterAuthentication`, `otherAppRejected`, `sessionLengthUnknown`, `sensorClockMismatch`, `noGlucoseValue`, `credentialsUnavailable`).

- Clock-mismatch latch in the app (WS5 final check): update it on every reading/store change incl. background BLE wakes and at launch/foreground, persist it, and add a memoryless check (store wall clock + uptime at each ingest; wall-clock delta ≠ uptime delta by > 60 s → latch). A future-dated newest stored reading must count as stale for missed-readings logic in both app and AlertEngine (WS1 final check).
- Onboarding/diagnostics: flag other G7 apps (D35).

## §11 on-device checklist additions (collected from reviews; goes into docs/setup.md in Phase 3)

- Capture raw G7 packets for a real LOW and HIGH (D31) before relying on HIGH→401 in closed loop.
- J-PAKE/certificates accepted by a real G7; pairing prompt accept/cancel/timeout error codes; state-restoration relaunch reconnects.
- Receiver (slot 1) + app (slot 2) side by side 24 h; reading times match the receiver within seconds; backfill after a gap lands on the same ids.
- With another G7 app installed, an unsolicited auth status is not taken as ours (WS1 review B1 fix).
- Calibration round trip and display-only duration; warm-up length reported by 0x52; expired sensor keeps advertising; 15-day sensor refused.
- Trio loop cadence with the phone locked 30+ min (heartbeat); Dexcom Follow shows LOW/HIGH from Share (D30); Nightscout LOW shows "LOW" and LoopFollow alarms (D29).
- Urgent low as an AlarmKit system alarm on silent while suspended, incl. repeats and Stop → acknowledge (D26).
- Widget lag measured and recorded in docs/widgets.md; DB writes while locked for hours (file protection).
- WidgetKit reload behaviour when the phone clock is set back 1 h with a timeline queued (WS5 final check).
- Residual P1c: with another G7 app installed, confirm `otherAppRejected` surfaces (D35).
- Change the phone's time manually during an urgent-low snooze (rollback detection with the monotonic clock, WS4); AlarmKit: 31 alarms at the 2-min floor, wake 30 s before / 3 s after a repeat, revoke alarm permission with repeats pending.

## Open questions for Michael

- Critical Alerts entitlement: optional (D17). Applying is free but approval for a build-from-source app is unlikely; if ever granted, flip `SENSOR_APP_ENTITLEMENTS` (D4).
- Nightscout token (read + write), when ready — enter it in the app, not in chat or files.

## Phase log

### Phase 1 — Parallel build (2026-09-23)

- Seven workstreams in parallel worktrees; every one reviewed by an independent safety reviewer; 16 review rounds in total (initial + deltas), 11 blockers found and fixed before merge. Two API usage-limit interruptions; affected agents resumed from their transcripts.
- Merged into `integration`: WS6 9305a72, WS3 3002c9d, WS2 3b51811, WS7 6113de7, WS5 5421924, WS4 f9ffac4, WS1 1ad1b27; NOTICE updated.
- Gates on `integration` (`.build-logs/20260923-222836`): build Debug/Release zero warnings; 973 tests, 0 failures; coverage G7Kit Messages 99.04%, GlucoseStats 99.88%, AlertEngine 99.06%, TrioBridge 97.75%; safety S1 36, S2 69, S3 62, S4 47, S5 66, S6 34, S7 25, S8 2; S6 compile-out checks PASS. Gate 4 (replay run) needs Phase 2 wiring, so `main` is not updated yet (D15).
- Owner decisions this phase: D16, D17, D21–D24, D26, D27, D29, D30 (plus orchestrator decisions D18–D20, D25, D28, D31–D35).

### Phase 0 — Bootstrap (2026-09-23)

- Scaffold: `LICENSE` (GPL-3.0), `NOTICE.md`, `README.md`, `project.yml` (XcodeGen 2.46.0), `Config/` xcconfigs, nine packages under `Packages/`, app + widget + test targets, `.claude/agents/*` (9 roles, §2 verbatim), `scripts/check.sh`.
- Contracts in `GlucoseCore` with 17 contract tests (S2, S3, S4, S6 covered).
- `vendor-ref/xdripswift` @ `7.1.0` (`0370937`), `vendor-ref/Trio` @ `29350e31a` with submodules.
- Phase 0 safety review: **FAIL** (2 blockers, 6 majors, 11 minors). All fixed in the follow-up commit (D18, D19, test-verifier role corrected); re-review: B1/B2 fixed, new blocker B3 (replay rows in production DB) → fixed (D20); second re-review: **PASS** (no blockers; minors p1/p2 addressed — whole-batch rejection documented, lint limitation noted).
- Process slip: two of my `PROGRESS.md` edits truncated the file after the decisions table; restored from `1ec40ee` (reviewer m10).
- Gate results on the scaffold: build Debug/Release pass with zero warnings; package tests pass; safety S2/S3/S4/S6 pass, S1/S5/S7/S8 have no tests yet; coverage minimums fail (no code yet); replay gate fails (Phase 2). Expected at this point.
