# PROGRESS

Orchestrator log for the build described in `HANDOFF.md`. Only the orchestrator edits this file.

## Status

| Phase | State |
|---|---|
| 0 — Bootstrap | done (2026-09-23) |
| 1 — Parallel build | in progress |
| 2 — Integration | not started |
| 3 — Hardening | not started |
| 4 — Device build | not started |

### Workstreams (Phase 1)

| WS | Agent | Branch / worktree | State | Review | Merged to `integration` |
|---|---|---|---|---|---|
| WS1 G7Kit | ble-engineer | `ws1-g7kit` / `../wt-ws1-g7kit` | dispatched | — | — |
| WS2 Store + Replay | data-engineer | `ws2-store-replay` / `../wt-ws2-store-replay` | dispatched | — | — |
| WS3 Stats | stats-engineer | `ws3-stats` / `../wt-ws3-stats` | dispatched | — | — |
| WS4 Alerts | alerts-engineer | `ws4-alerts` / `../wt-ws4-alerts` | dispatched | — | — |
| WS5 UI + Widgets | ui-engineer | `ws5-ui` / `../wt-ws5-ui` | dispatched | — | — |
| WS6 TrioBridge | trio-integrator | `ws6-trio` / `../wt-ws6-trio` | dispatched | — | — |
| WS7 Import + Follow | sync-engineer | `ws7-sync` / `../wt-ws7-sync` | dispatched | — | — |

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
| D11 | S6 vs §10 gate 4 / §11 step 1: the alert engine may accept `.replay` readings **in DEBUG builds only** (`LiveReadingGate.validateAllowingReplay`, compiled only under `#if DEBUG`). Trio bridge and uploaders never accept replay. | Gate 4 requires alerts to fire on replay scenarios; S6's purpose (no non-sensor data reaching live consumers in a real build) is preserved because replay code does not exist in Release (`check.sh` verifies with `nm`). |
| D12 | All tests use XCTest; safety tests named `test_S<n>_…`. Packages declare iOS 17 + macOS 14 so `swift test` and coverage run on the host. | Gate 3 greps names; host tests are fast. |
| D13 | Sounds and fonts are copied flat into the bundle root from `Resources/Sounds` and `Resources/Fonts` (file names must be unique). | `UNNotificationSound` requires sounds in the main bundle; `UIAppFonts` lists file names. |
| D14 | Subagents are dispatched as general-purpose agents with the full role prompt (§2 verbatim, working rules, brief, return format) embedded; opus for ble/alerts/trio/reviewer roles. The `.claude/agents/*.md` definitions are committed and load in future sessions. | Custom agent types are read at session start, so this session could not select them by name. |
| D15 | Branch model: `main` = Phase 0 bootstrap only until all §10 gates pass; day-to-day orchestrator work happens on `integration`; each workstream branches from `integration` in `../wt-<ws>`. | §10: every merge to `main` needs all gates; gate 4 needs Phase 2. The Phase 0 bootstrap commit itself could not pass gates 3–4 (no feature code yet). |

## Discrepancies with HANDOFF (resolved)

- Mockups are in `designs/`, not `design/`.
- Trends mockup shows a 7/14/30/90 D selector, a forecast line (Now), and an "In range after runs" row; §7.3/§7.5/§6 win: 1/3/7/14/30/90 D, no forecast, after-runs row hidden until v1.1.
- xDrip4iOS has a `7.1.1` tag after `7.1.0`. Reference checkout is `7.1.0` as specified; WS1 reviews the `7.1.0..7.1.1` diff for G7 fixes and reports.
- Trio's App Group key is resolved through Info.plist `AppGroupID`, not a hard-coded string (see D2).

## Open questions for Michael

- Apply for the Critical Alerts entitlement (developer.apple.com → Contact → "Critical Alerts Entitlement request"), then flip `SENSOR_APP_ENTITLEMENTS` (D4).
- Nightscout token (read + write), when ready — enter it in the app, not in chat or files.

## Phase log

### Phase 0 — Bootstrap (2026-09-23)

- Scaffold: `LICENSE` (GPL-3.0), `NOTICE.md`, `README.md`, `project.yml` (XcodeGen 2.46.0), `Config/` xcconfigs, nine packages under `Packages/`, app + widget + test targets, `.claude/agents/*` (9 roles, §2 verbatim), `scripts/check.sh`.
- Contracts in `GlucoseCore` with 17 contract tests (S2, S3, S4, S6 covered).
- `vendor-ref/xdripswift` @ `7.1.0` (`0370937`), `vendor-ref/Trio` @ `29350e31a` with submodules.
- Phase 0 contracts sent to an independent safety review (in progress).
- Gate results on the scaffold: build Debug/Release pass with zero warnings; package tests pass; safety S2/S3/S4/S6 pass, S1/S5/S7/S8 have no tests yet; coverage minimums fail (no code yet); replay gate fails (Phase 2). Expected at this point.
