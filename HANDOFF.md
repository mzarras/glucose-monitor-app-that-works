# HANDOFF — Open-source G7 CGM app for iOS (name TBD by Michael — use [APP_NAME] until §13 is answered)

Owner: Michael (mzarras on GitHub). Orchestrator: Claude Code running Opus 5.5.
This document is the single source of truth for the build. Read it end to end before doing anything.

---

## 0. Kickoff prompt (paste this into Claude Code)

> Read `HANDOFF.md` in full, plus the two files in `design/`. You are the orchestrator. Do not write feature code yourself; plan, create the contracts and scaffolding in Phase 0, then delegate every workstream to subagents running in parallel, each in its own git worktree, exactly as described in §9. Gate every merge on the checks in §10. Before Phase 0, ask me only the decision-point questions in §13, all in one message. After that, work autonomously and report progress at the end of each phase using the template in §9.6.

---

## 1. What we are building

A native iOS app that talks **directly to a Dexcom G7 (10-day) sensor over Bluetooth** as the *primary* (authenticating) device, replacing the official Dexcom app on the owner's phone. It:

1. Pairs with and authenticates to the sensor itself (J-PAKE), using code reused from **xDrip4iOS** (GPL-3.0), which added native G7 "Primary" mode in release 7.1.0 (Sept 19, 2026).
2. Stores readings locally and shows them in a clean, editorial UI (design "B", see §7 and `design/`).
3. Computes richer statistics than the Dexcom app (§6).
4. Runs its own alerts with **distinct, user-chosen sounds** (the trigger for this project was a Dexcom update changing the alert sound to one indistinguishable from PagerDuty).
5. **Hands every valid reading to Trio** (the owner's automated insulin delivery app) through a shared App Group, so Trio keeps looping without the Dexcom app.
6. **Imports the owner's existing history** on first launch, so 90-day patterns work from day one (§4.5).
7. **Supports followers** by uploading to the owner's Nightscout, optionally also to Dexcom Share so existing Dexcom Follow users keep working (§8A).
8. Has **Home Screen widgets**, medium size first, since that's the owner's daily view today (§7.4).
9. Is open source under GPL-3.0.

The owner is an experienced engineer (lead developer on a high-reliability API authorization platform, Trio contributor, runs self-hosted Nightscout on AWS). Write code and reports at that level; do not explain basics.

### 1.1 Non-goals for v1

- No App Store / TestFlight distribution. Build-from-source only, like Loop, Trio and xDrip4iOS.
- No "Dexcom" in the app name, icon, or bundle ID (trademark). Refer to "G7 sensor" in UI copy.
- No insulin dosing logic of any kind. This app measures and reports; Trio doses.
- No glucose prediction line in v1 (the mockup's dashed forecast is out of scope, see §7.5).
- No G7 15-day, ONE+, Stelo, G6, Libre. The code must be structured so they could be added later, but do not build them.
- No Apple Watch app, Live Activities, or HealthKit in v1. These are v1.1 (§12). Widgets ARE in v1 (§7.4).
- No custom follow backend or separate follower app in v1. Nightscout is the follow backend (§8A).
- **No code from this repo goes into CorrelateWell, and no CorrelateWell code comes in.** GPL-3.0 would otherwise attach to it.

---

## 2. Safety rules (non-negotiable; every subagent gets these verbatim)

This app's output feeds an insulin-dosing system. Treat bugs here like bugs in a payments ledger, not a UI.

- **S1. Never fabricate a reading.** No interpolation, smoothing, or synthetic values are ever stored as readings, shown as the current value, sent to Trio, or used for alerts. Charts may draw lines between real points; that is all.
- **S2. Only publish authenticated, valid readings.** A reading goes to storage/Trio/alerts only if it came from an authenticated sensor session, the sensor's status says the value is valid (not warm-up, not error, not expired), and its timestamp is within the plausibility window (not in the future, not older than the session start).
- **S3. Timestamps are derived, never assumed.** G7 reports times relative to the sensor session. Convert using the session start reported by the sensor, keep a monotonic ordering, and deduplicate by sensor-reported timestamp. A backfilled reading keeps its original timestamp and is flagged `isBackfill`.
- **S4. Out-of-range values stay out of range.** Preserve the sensor's LOW/HIGH flags. Never clamp a LOW to 40 or a HIGH to 400 and present it as a normal number.
- **S5. Fail loud, not silent.** Any of: no reading for 15 min, BLE unavailable/unauthorized, sensor error, sensor expiring/expired, Trio bridge write failure, must surface in the UI and (where listed in §5) as an alert.
- **S6. Only live sensor data reaches Trio, alerts, or uploads.** Replay/mock sources are compiled only in DEBUG. Imported history is stored and used for charts and stats only. The Trio bridge, the alert engine, and every uploader refuse any reading whose `source != .sensor`. Enforce this in code and in a test.
- **S7. Urgent low (≤55 mg/dL) cannot be disabled.** It can be snoozed for at most 30 minutes. Every other alert is configurable.
- **S8. Nothing ships that Michael cannot audit.** Small modules, clear names, no clever abstractions, every non-obvious protocol byte commented with its source.

---

## 3. Licensing and attribution

- Whole repository: **GPL-3.0**. Add `LICENSE` (GPL-3.0 text) at root.
- Code reused from xDrip4iOS keeps its original copyright headers; add a line noting the source file and the xDrip4iOS release/commit it came from.
- `NOTICE.md` credits: xDrip4iOS (JohanDegraeve/xdripswift), LoopKit G7SensorKit, the xDrip+ Android project, and DiaBLE's protocol research, as used.
- Fonts (Newsreader, IBM Plex Sans, IBM Plex Mono) are SIL Open Font License; bundle them with their license files in `Resources/Fonts/licenses/`.
- Trio is AGPL-3.0; the patch to Trio stays in the owner's Trio fork, not this repo.

---

## 4. Architecture

### 4.1 Project generation (important for parallel agents)

Use **XcodeGen** (`project.yml`) so the `.xcodeproj` is generated, not hand-merged. Parallel subagents editing `project.pbxproj` will conflict constantly; with XcodeGen they only touch `project.yml` or add files inside their own package. Commit `project.yml`; gitignore the generated project, or commit it but always regenerate before building.

Language: Swift 6, strict concurrency on, zero warnings. UI: SwiftUI + Swift Charts. Deployment target: **match the owner's Trio fork** (read it from Trio's project settings) so both run on the same phone.

### 4.2 Modules (local Swift packages under `Packages/`)

| Package | Responsibility | Depends on |
|---|---|---|
| `G7Kit` | BLE scan/connect, pairing-code entry → J-PAKE auth, bonding, message parsing, glucose + backfill streams, sensor status. Ported from xDrip4iOS. | Foundation, CoreBluetooth |
| `GlucoseCore` | Domain types (`GlucoseReading`, `SensorSession`, `TrendArrow`, `ReadingSource`), units, the `CGMSource` protocol. No I/O. | — |
| `GlucoseStore` | Persistence (see 4.4), dedupe, queries by range, retention. | GlucoseCore |
| `GlucoseStats` | Pure functions for every metric in §6. No UI, no storage. | GlucoseCore |
| `AlertEngine` | Alert rules, state machine (armed → firing → snoozed → cleared), sound selection, notification scheduling. | GlucoseCore |
| `TrioBridge` | Writes valid sensor readings into the shared App Group in the format Trio reads (§8). | GlucoseCore |
| `NightscoutKit` | Nightscout REST client: history import (§4.5) and live upload for followers (§8A). Optional Dexcom Share uploader behind a flag. | GlucoseCore |
| `ReplayKit` (DEBUG only) | `CGMSource` implementations fed from a Nightscout JSON export or a scripted scenario, for UI/stats/alert testing without a sensor. | GlucoseCore |
| App target | SwiftUI screens, dependency wiring, settings, onboarding. | all of the above |

### 4.3 Core contracts (orchestrator writes these in Phase 0, before any subagent starts)

```swift
// GlucoseCore
public enum ReadingSource: Sendable, Equatable { case sensor, imported(ImportOrigin), replay, mock }
public enum ImportOrigin: String, Sendable, Equatable { case nightscout, clarityCSV }

public enum GlucoseValue: Sendable, Equatable {
    case mgdl(Int)      // 40...400 as reported
    case belowRange     // sensor LOW flag
    case aboveRange     // sensor HIGH flag
}

public struct GlucoseReading: Sendable, Equatable, Identifiable {
    public let id: String            // stable: sensorSerial + sensorTimestamp
    public let date: Date            // derived per S3
    public let value: GlucoseValue
    public let trendRate: Double?    // mg/dL/min as reported, nil if unavailable
    public let isBackfill: Bool
    public let source: ReadingSource
    public let sensorSerial: String
}

public enum SensorState: Sendable, Equatable {
    case notPaired, searching, connecting, authenticating
    case warmingUp(endsAt: Date)
    case active(sessionStart: Date, expiresAt: Date)
    case gracePeriod(endsAt: Date)
    case expired, failed(reason: String), error(code: Int, description: String)
}

public protocol CGMSource: Sendable {
    var readings: AsyncStream<GlucoseReading> { get }   // new + backfill
    var state: AsyncStream<SensorState> { get }
    func start(pairingCode: String?) async throws
    func stop() async
}
```

Everything downstream consumes `CGMSource`, which is what lets UI, stats, alerts and the bridge be built in parallel against `ReplayKit` while `G7Kit` is still in progress.

### 4.4 Persistence

Recommended: **GRDB** (SQLite, MIT) for deterministic, testable background writes and fast range queries over 90+ days of 5-minute data (~26k rows/90 days). SwiftData is acceptable if the orchestrator documents why. Either way:
- Unique key on `id` (S3 dedupe). Upserts are idempotent.
- Index on `date`.
- Keep 2 years by default; configurable.
- Writes happen off the main actor; the UI observes.

### 4.5 Data storage, retention, backup, and first-run import

**Where data lives:** on the device only, in the app's SQLite database (§4.4). No server of ours is involved. Copies leave the device only through channels the owner turns on: Trio (local App Group), Nightscout upload, and optional Dexcom Share upload.

**Retention:** keep 2 years by default (configurable: 90 days / 1 year / 2 years / forever). Trends supports 1/3/7/14/30/90 days in v1 (covering what the Dexcom app offers); the storage holds more so longer views can be added later without a migration.

**File protection (important):** the app writes readings while the phone is locked (BLE wakes it in the background), and the widget reads while locked. Put the database and the widget snapshot in the App Group container with `completeUntilFirstUserAuthentication` protection, not `complete`, or background writes will fail silently after the phone locks. Test this on device (§11).

**Backup:** the database lives in the app container and is included in the phone's iCloud/device backup (do not set the exclude-from-backup flag). Settings shows the database size and offers "Export all data (CSV)". Nightscout acts as the off-device copy.

**First-run import (v1):** onboarding offers to import history before pairing.
1. **Nightscout (primary path).** The owner self-hosts Nightscout, and Trio already uploads CGM readings there, so it holds his history. Read `GET /api/v1/entries.json` with the owner's URL and access token, paged by date (e.g. `find[date][$gte]`/`$lt` in 7-day windows), `type=sgv` only. Import 90 days by default, with an option for everything.
2. **Dexcom Clarity CSV export (fallback).** Parse the Clarity export file picked through the Files app. Handle its header rows, "Low"/"High" text values (map to `belowRange`/`aboveRange`, S4), and local timestamps without an offset (ask for the time zone the data was recorded in; default to the current one).
3. Imported rows get `source: .imported(...)`, the dedupe key `imported:<origin>:<epoch-ms>`, and are skipped where a `.sensor` reading exists within ±2.5 min. Import is resumable and idempotent; a progress view shows readings imported and the date range covered.
4. Imported data feeds charts and stats only (S6). The Trends screen footnotes periods that include imported data.
5. Tests: fixture Nightscout pages (including duplicates, mbg/cal entries to ignore, and gaps), a real-format Clarity CSV fixture, DST-crossing timestamps, and re-running the import changes nothing.

### 4.6 BLE lifecycle on iOS

- Background mode `bluetooth-central`. Use `CBCentralManager` state restoration with a fixed restore identifier so iOS relaunches the app for sensor events after a system termination.
- The G7 advertises about every 5 minutes, connects briefly to deliver the new reading plus any backfill, then disconnects. Design for that cycle; do not hold a long-lived connection.
- iOS will **not** relaunch the app after the user force-quits it. Detect a gap on next launch and show a clear banner explaining that force-quitting stops readings.
- Pairing: the 4-digit sensor pairing code is the J-PAKE secret. Expect an iOS system pairing/bonding prompt; handle both accept and cancel.
- Investigate and document what xDrip4iOS 7.1.0 calls **"slot choice"** before finalizing connection logic; it likely determines whether the app and a Dexcom receiver can both be authenticated at once, which the owner needs for side-by-side validation (§11).
- Only one primary collector per sensor. The official Dexcom app must be removed from the phone before pairing in primary mode.

### 4.7 Alert delivery on iOS

- **Critical Alerts** (break through silent mode and Focus) require an Apple-granted entitlement. A self-built app will not have it unless the owner applies and is approved. Build for that possibility behind a flag, but do not depend on it.
- Default path: Time Sensitive notifications (enable the capability) plus, when the app is awake for a BLE event, playing the alert sound via an `AVAudioSession` playback category so it is audible with the ringer switch off. Confirm how xDrip4iOS and Trio handle this today and follow the proven approach; document it in `docs/alerts.md`.
- Repeat unacknowledged urgent alerts every 5 minutes until acknowledged.

---

## 5. Alerts spec (v1)

| Alert | Default | Configurable | Notes |
|---|---|---|---|
| Urgent low | ≤ 55 mg/dL | threshold 50–60, sound, repeat | **Cannot be disabled** (S7). Snooze max 30 min. |
| Urgent low soon | projected ≤ 55 within 20 min using the sensor's reported trend rate | on/off, sound | Off by default. Uses reported rate only, never a model. |
| Low | ≤ 70 | on/off, threshold, sound, snooze | |
| High | ≥ 250 | on/off, threshold, sound, snooze, delay (fire only after N min above) | |
| Rise / fall rate | ≥ 3 mg/dL/min | on/off, threshold, sound | Off by default. |
| Missed readings | no valid reading for 15 min | on/off, window 10–60 | S5. |
| Sensor | warm-up done, expiring in 24 h / 2 h, grace period, failed, error | on/off each | |
| Trio bridge | bridge write failing or Trio not consuming for 15 min (if detectable) | on/off | S5. |

Quiet hours: a schedule that silences non-urgent alerts. Urgent low always sounds.
Sounds: ship 6–8 original, clearly distinct sounds (license-clean, generated or CC0). Each alert has its own default so they are distinguishable by ear. Include a preview button per sound.

---

## 6. Statistics spec

Standard consensus metrics (International Consensus on Time in Range). Implement in `GlucoseStats` as pure functions over `[GlucoseReading]` for a period. Exclude `belowRange`/`aboveRange` from mean/SD but count them in the range bins (below 54 and above 250 respectively).

| Metric | Definition |
|---|---|
| Time in range bins | % of readings in <54, 54–69, 70–180, 181–250, >250 |
| Time in tight range | % in 70–140 |
| Mean glucose | mean of numeric readings |
| SD, CV | CV = SD / mean × 100. Target ≤ 36% |
| GMI | GMI (%) = 3.31 + 0.02392 × mean (mg/dL) |
| Data sufficiency | % of expected 5-min readings present. Show a warning under 70% (AGP standard for 14 days) |
| AGP | 5th/25th/50th/75th/95th percentiles by time of day, bucketed (e.g. 15-min buckets, lightly smoothed for display only) |
| Hypo events | Level 1: ≥15 consecutive min < 70; Level 2: ≥15 consecutive min < 54. An event ends after ≥15 consecutive min ≥ 70. Report count, mean duration, and time-of-day histogram |
| Overnight vs day | TIR split 00:00–06:00 vs 06:00–24:00 (window configurable) |
| Period comparison | Each metric vs the immediately preceding equal-length period |
| Longest in-range streak | Longest continuous run in 70–180 (gaps > 15 min break the run) |
| After-exercise TIR | **v1.1**, needs HealthKit workouts. Stub the UI row behind a flag |

Every metric gets unit tests with hand-computed fixtures, including: empty input, all LOW, all HIGH, gaps, duplicate timestamps, DST transitions (both directions), and a 90-day dataset for performance (all stats for 90 days must compute in < 100 ms on device-class hardware; measure in a test).

---

## 7. Design spec (option B, "Editorial")

Reference mockups: `design/now-screen.reference.html` and `design/trends-screen.reference.html`. They are HTML mockups from a design tool: `{{accent}}` is a template variable (default `#2F6B4F`) and `./support.js` is the tool's runtime, not something to port. Use them for layout, hierarchy, spacing and copy tone. All numbers in them are sample data.

### 7.1 Tokens

| Token | Light | Dark (proposed; tune on device) |
|---|---|---|
| background | `#F4F1EA` | `#161513` |
| ink | `#1B1A17` | `#EDE8DE` |
| muted | `#6B665C` | `#A39C8E` |
| rule | `#D9D3C7` | `#2E2B26` |
| rangeBand | `#E8E2D5` | `#24211C` |
| accent (user-selectable) | `#2F6B4F` default; options `#9A4A26`, `#2D4E7A`, `#1B1A17` | lightened equivalents, same hues |
| veryLow <54 | `#7A2418` | `#E0786A` |
| low 54–69 | `#B3412E` | `#E89080` |
| high 181–250 | `#C58A2B` | `#E0B060` |
| veryHigh >250 | `#8A5A12` | `#D49A40` |

Check every text/background pair at WCAG AA (4.5:1 body, 3:1 for ≥24 pt) in both modes; adjust dark values if needed and record the final values in `docs/design-tokens.md`.

### 7.2 Type

- Display numerals: **Newsreader** Light (300). Current reading ~132 pt, stat hero ~104 pt, section titles 20–36 pt.
- UI text: **IBM Plex Sans** 400/500/600, 13–14 pt body.
- Data labels, timestamps, axis labels: **IBM Plex Mono** 400/500, 10–12 pt, uppercase labels tracked +0.06–0.08 em.
- Support Dynamic Type: scale body and labels; cap the hero reading so it never truncates.

### 7.3 Screens

1. **Now**: header (italic "glucose" wordmark, date/time, sound and menu buttons) · hero reading + trend arrow + "mg/dL" + delta ("−3 in 5 min") · state line ("STEADY · IN RANGE · 3 MIN AGO", colored dot) · chart with 70–180 band, 3/6/12/24 H selector · "Today so far" (TIR, average, lows) · status rows (sensor day and time left; Trio last handoff). Stale or invalid states replace the hero with a clear message, never the last number alone (S5).
2. **Trends**: period selector 1/3/7/14/30/90 D (default 14 D) · hero TIR with delta vs prior period · 5-segment range bar with labels · "A typical day" AGP chart · metric rows (tight range, mean, GMI, CV, lows with time-of-day note, overnight TIR, longest streak; after-runs row hidden until v1.1).
   - **1 D and 3 D behave differently:** percentile bands over one to three days are misleading, so replace the "A typical day" AGP chart with the actual readings (1 D: today's trace with the range band; 3 D: the three days overlaid by time of day, today emphasized, the other two lighter). The comparison line reads "vs yesterday" / "vs prior 3 days".
   - **GMI is shown only for 14 D and longer** (it isn't meaningful over shorter windows); below that the row says "needs 14 days". Every period shows the data-sufficiency warning from §6 when coverage is under 70%.
3. **Alerts**: list of alerts with threshold, sound and on/off; quiet hours; sound picker with preview. (PROGRESS D56: now Settings › Alerts, the first Settings group.)
4. **Settings**: sensor (pair, pairing code entry, status, stop session), Trio bridge (toggle, status, last write), sharing (Nightscout URL/token, upload status, optional Dexcom Share), import history, export all data (CSV), accent color, units (mg/dL only in v1, keep the type ready for mmol/L), data retention, about/licenses/open-source credits.
5. **Onboarding / pairing**: optional history import (§4.5), remove-Dexcom-app warning (and a note that Dexcom Follow stops unless Share upload is on), Bluetooth + notification permissions, pairing code, warm-up countdown.

Tab bar: text-only "Now · Predict · Trends · Settings", 44 pt minimum targets (PROGRESS D56, which supersedes "Now · Trends · Alerts · Settings"; Predict per D57).

### 7.4 Widgets (v1)

Widget extension target in `project.yml`, reading a small snapshot the app writes to the App Group (latest reading, trend, delta, sensor state, last 3 h of readings, last-updated time). The widget never computes or guesses values itself (S1).

- **Medium Home Screen widget (priority, the owner's current setup):** left side, hero reading in Newsreader with trend arrow, delta and relative age ("3 min ago"); right side, a 3-hour mini chart with the 70–180 band. Background and colors from §7.1, following system light/dark.
- **Small Home Screen widget:** reading, arrow, age.
- **Lock Screen accessories:** rectangular (reading, arrow, age, tiny sparkline) and inline (e.g. "105 → · 3m").
- **Staleness is explicit (S5):** render the age with a relative date so it keeps counting up without a refresh. Each timeline also includes future entries that switch the widget to a dimmed "stale" state at 10 min and, from 20 min, the last reading muted without arrow or delta, labelled with its time (D61), so an old number never looks current.
- **Refresh:** the app calls `WidgetCenter` to reload after each new reading. iOS limits how often widgets refresh when the app is in the background, so the widget can lag behind the app by several minutes at times; measure the real lag on device (§11) and record it in `docs/widgets.md`. If it's too laggy, the fix is a Live Activity (v1.1), which iOS lets update more often.
- Tapping a widget opens the Now screen.
- Tests: snapshot-encoding tests, timeline-generation tests for fresh/stale/no-data/LOW/HIGH/warm-up/expired, and SwiftUI previews for every widget size and state in light and dark.

### 7.5 Trend arrows and chart rules

- Map the sensor-reported rate (mg/dL/min) to arrows: |r| < 1 flat; 1–2 forty-five degrees; 2–3 single; > 3 double. Put thresholds in one constant and unit-test the mapping.
- Charts draw real points only (S1). Gaps > 15 min break the line. No forecast in v1.
- VoiceOver: hero reads as "105 milligrams per deciliter, steady, 3 minutes ago"; charts get a summary label.

---

## 8. Trio integration

Goal: Trio gets readings from this app with **zero or minimal Trio changes**.

1. Read the owner's Trio fork. Find how Trio consumes readings from xDrip4iOS through a shared App Group (a CGM source that reads shared `UserDefaults` in the App Group). Document the exact App Group ID pattern, key(s), payload shape, units, and date format in `docs/trio-bridge.md`, citing file paths and line numbers in Trio.
2. Implement `TrioBridge` to write exactly that contract. Both apps must be signed with the **same Team ID** and share the App Group.
3. If Trio's existing source can consume our writes unchanged, no Trio patch is needed; the owner selects that source in Trio. If a small patch is cleaner (for example, a distinct source name so it is obvious in Trio's UI), produce it as a separate branch in the Trio fork with a minimal diff, and explain it.
4. Tests: the bridge encodes a fixture reading exactly as Trio expects (golden file); the bridge rejects non-`.sensor` sources (S6); the bridge rejects invalid/warm-up readings (S2).
5. Do not also run Trio's G7SensorKit follower against the same sensor in the final setup; one path in, clearly configured. Note this in the setup guide.

### 8A. Following (sharing readings with other people)

Removing the Dexcom app stops Dexcom's own uploads to Dexcom Share, so **anyone following in the Dexcom Follow app stops getting data** unless this app uploads for it. Plan:

1. **Nightscout upload (v1, primary).** After each valid sensor reading (S2, S6), `POST /api/v1/entries` with `type: sgv`, value, `direction` (Nightscout arrow names from §7.5 mapping), `date`/`dateString`, `device: "<app name>"`. Queue and retry offline; backfill uploads with original timestamps; dedupe on the server by date + device. Settings shows last upload and failure count; failures raise the S5 banner.
   - **Avoid double uploads:** Trio also uploads CGM readings to Nightscout. Check how Trio behaves when its CGM source is the App Group, document it in `docs/following.md`, and make sure exactly one of the two uploads each reading (default: this app uploads; Trio's CGM upload off, or the reverse if Trio's is cleaner). Test for duplicate entries.
   - Followers use the owner's existing Nightscout site or a Nightscout follower app with alarms (for example LoopFollow or Nightguard). Write a one-page `docs/following.md` the owner can send to followers.
2. **Dexcom Share upload (v1, optional, off by default).** Keeps current Dexcom Follow users working with no change on their side. xDrip4iOS already has a Share uploader; port it into `NightscoutKit` as a separate uploader behind a setting. Mark it clearly as unofficial and subject to breaking. Same S2/S6 rules, same queue/retry.
3. **Follower mode in this app (v1.1).** The same app, switched to "Follow someone", reads a Nightscout URL + read token, shows the Now/Trends screens, and runs local alerts. No new server needed. A dedicated push-alert backend (APNs from the owner's AWS) is v2 and out of scope.

---

## 9. Orchestration plan (Opus 5.5 + subagents)

### 9.1 Rules for the orchestrator

- You plan, write the Phase 0 contracts, dispatch, review, and merge. Subagents implement.
- Subagents do not share context. Every dispatch prompt must be self-contained: the safety rules (§2) verbatim, the relevant sections of this doc, the contracts, the exact file/package boundary, acceptance criteria, and the return format (§9.5).
- Run independent workstreams **in parallel**. Each writing subagent works on its own branch in its own `git worktree` (`../wt-<workstream>`) and touches only its package, to avoid conflicts.
- **No agent approves its own work.** Every workstream is reviewed by a separate `safety-reviewer` subagent and must pass §10 gates before you merge.
- Keep `PROGRESS.md` at repo root: phase, workstream status, decisions made and why, open questions for Michael.
- When something in this doc is ambiguous or wrong in light of the actual code (xDrip4iOS, Trio), prefer the real code, record the discrepancy in `PROGRESS.md`, and continue. Stop and ask Michael only for the decision points in §13 or a genuine safety conflict.

### 9.2 Subagent definitions (create in Phase 0 as `.claude/agents/*.md`)

Create one file per role with frontmatter `name`, `description`, `tools`, `model`, followed by a system prompt that includes §2 verbatim.

| name | model | tools | role |
|---|---|---|---|
| `ble-engineer` | opus | Read, Edit, Write, Bash, Grep, Glob | WS1: port G7 primary mode into `G7Kit` |
| `data-engineer` | inherit | Read, Edit, Write, Bash, Grep, Glob | WS2: `GlucoseCore` impl details, `GlucoseStore`, `ReplayKit` |
| `stats-engineer` | inherit | Read, Edit, Write, Bash, Grep, Glob | WS3: `GlucoseStats`, test-first |
| `alerts-engineer` | opus | Read, Edit, Write, Bash, Grep, Glob | WS4: `AlertEngine`, notifications, sounds |
| `ui-engineer` | inherit | Read, Edit, Write, Bash, Grep, Glob | WS5: SwiftUI screens per §7 |
| `trio-integrator` | opus | Read, Edit, Write, Bash, Grep, Glob | WS6: `TrioBridge`, Trio fork analysis/patch |
| `sync-engineer` | inherit | Read, Edit, Write, Bash, Grep, Glob | WS7: `NightscoutKit` import + upload, Clarity CSV import, optional Share uploader |
| `safety-reviewer` | opus | Read, Grep, Glob, Bash | Reviews every workstream against §2, §10; read-only except running tests |
| `test-verifier` | inherit | Read, Grep, Glob, Bash | Runs the full gate suite on the integration branch and reports raw results |

### 9.3 Phases

**Phase 0 — Bootstrap (orchestrator, sequential)**
- Repo scaffold, `LICENSE`, `NOTICE.md`, `project.yml` (XcodeGen), empty packages, `.claude/agents/*`, `PROGRESS.md`.
- Write the §4.3 contracts in `GlucoseCore` and compile them.
- Signing via `Config/Signing.xcconfig` (gitignored) with `DEVELOPMENT_TEAM`, bundle ID prefix, App Group ID; a checked-in `Signing.example.xcconfig`.
- CI-equivalent script `scripts/check.sh` that runs every §10 gate locally.
- Clone xDrip4iOS at tag `7.1.0` and the owner's Trio fork into `vendor-ref/` (gitignored, read-only reference).

**Phase 1 — Parallel build (all at once)**
- WS1 `ble-engineer`: locate the native G7 primary-mode implementation in xDrip4iOS 7.1.0 (pairing code → J-PAKE, bonding, message handling, backfill). Port the minimal set into `G7Kit` behind `CGMSource`. Strip unrelated transmitter types. Build parser tests from packet fixtures (reuse any in xDrip4iOS; otherwise construct from its parsing code and document each byte). Document "slot choice" semantics (§4.6).
- WS2 `data-engineer`: `GlucoseStore` (§4.4) and `ReplayKit` (Nightscout JSON export → `CGMSource`, plus scripted scenarios: steady, slow fall to urgent low, compression-low spike, 45-min signal gap with backfill, sensor expiry).
- WS3 `stats-engineer`: all of §6, tests first.
- WS4 `alerts-engineer`: §5 and §4.7; state machine fully unit-tested including snooze, repeat, quiet hours, and S7.
- WS5 `ui-engineer`: §7 screens and the §7.4 widget extension against `ReplayKit`, SwiftUI previews for every state (normal, low, high, LOW/HIGH flags, stale, warm-up, expired, BLE off, Trio failing), light and dark.
- WS6 `trio-integrator`: §8 steps 1–4, plus the Trio side of the double-upload check in §8A.
- WS7 `sync-engineer`: §4.5 import (Nightscout + Clarity CSV) and §8A upload paths, with tests against fixture pages and a local mock server.

**Phase 2 — Integration (orchestrator + subagents)**
- Wire `G7Kit` → `GlucoseStore` → UI, `AlertEngine`, `TrioBridge` in the app target. Replay source selectable only in DEBUG.
- `test-verifier` runs all gates on the integration branch; fix-forward via the owning subagent.

**Phase 3 — Hardening (parallel)**
- `safety-reviewer`: full audit against §2 with a written report `docs/safety-review.md` listing each rule, where it is enforced, and the test that proves it.
- Failure-mode pass: app killed by system, BLE toggled, Bluetooth permission revoked, notification permission denied, phone reboot, time zone change, DST, clock skew, disk full, 90-day dataset performance.
- `docs/setup.md` for Michael (see §11) and `README.md` for the open-source repo.

**Phase 4 — Device build**
- Release-configuration build for a connected iPhone succeeds with the owner's signing. If a device is connected, install with `xcrun devicectl` and confirm launch; otherwise leave exact steps in `docs/setup.md`.
- Final report to Michael (§9.6).

### 9.4 Dependency graph

```
Phase 0 contracts ──┬─ WS1 G7Kit ──────────────┐
                    ├─ WS2 Store + Replay ─────┤
                    ├─ WS3 Stats ──────────────┤
                    ├─ WS4 Alerts ─────────────┼─ Phase 2 integration ─ Phase 3 hardening ─ Phase 4 device build
                    ├─ WS5 UI (on Replay) ─────┤
                    ├─ WS6 TrioBridge ─────────┤
                    └─ WS7 Import + Follow ────┘
```

### 9.5 Subagent return format (required)

```
WORKSTREAM: <id>
STATUS: done | blocked | partial
SUMMARY: <5 lines max>
FILES CHANGED: <list>
TESTS: <commands run> → <pass/fail counts, pasted output tail>
SAFETY RULES TOUCHED: <S#: where enforced, which test proves it>
DEVIATIONS FROM HANDOFF: <what and why>
OPEN QUESTIONS: <for orchestrator>
```

### 9.6 Phase report to Michael

Per phase: what merged, gate results, decisions made, deviations, anything needing his input. Keep it short; link to `PROGRESS.md` for detail.

---

## 10. Validation gates (all must pass before any merge to `main`)

1. **Build**: `xcodebuild` for the app scheme, `generic/platform=iOS`, Debug and Release, zero warnings, Swift 6 strict concurrency.
2. **Unit tests**: every package's tests green. Minimum coverage targets: `GlucoseStats` 95%, `AlertEngine` 90%, `TrioBridge` 90%, `G7Kit` parsers 90%.
3. **Safety tests** (named `test_S1_…` through `test_S8_…`): one or more per rule in §2.
4. **Replay run**: app launches in the simulator on each `ReplayKit` scenario; alerts fire when and only when expected (asserted in tests, not by eye).
5. **Independent review**: `safety-reviewer` report attached to the merge with no open blockers.
6. `scripts/check.sh` runs gates 1–4 in one command and exits non-zero on any failure.

What the gates cannot prove: real BLE behavior with a live sensor, real Trio looping, and real alert audibility. Those are §11 and belong to Michael.

---

## 11. On-device validation plan (Michael runs this; write it into `docs/setup.md`)

Safety net throughout: fingerstick meter on hand; Dexcom G7 receiver authenticated to the same sensor as the side-by-side reference (if slot semantics allow; otherwise meter only).

1. **Replay on device** (DEBUG): UI, alerts audible with ringer off, Trio bridge and uploaders verified disabled for replay.
1a. **Import**: run the Nightscout import; spot-check a few days against Nightscout, and 90-day Trends against Dexcom Clarity for the same period.
2. **Pair a spare or end-of-life sensor** not used for treatment. Confirm pairing, warm-up countdown, first reading, 5-minute cadence for 2 hours, readings match the receiver.
3. **24-hour soak** with the app backgrounded: no gaps beyond sensor behavior, backfill after walking out of range for 30+ min, survives phone reboot, correct banner after a deliberate force-quit.
4. **Trio handoff** with looping in open loop first: readings appear in Trio with correct values and timestamps; then closed loop once satisfied.
3a. **Widget**: medium widget on the Home Screen for the whole soak; note how far it lags the app, and that it shows stale/no-data states correctly. Confirm readings keep saving while the phone stays locked for hours (file protection, §4.5).
4a. **Followers**: each reading appears once in Nightscout within a minute; if Share upload is on, a follower confirms Dexcom Follow updates. Tell followers before switching.
5. **Full sensor session** (10 days + grace period) before removing the Dexcom app permanently: track missed readings/day, alert correctness, battery impact.
6. Log issues as GitHub issues with the in-app diagnostic export (add a "Export diagnostics" button in Settings that writes BLE state transitions and bridge writes, no personal data beyond readings).

---

## 12. v1.1 backlog (do not build now; keep seams for them)

HealthKit write + workout overlay stat ("in range after runs") · follower mode in-app (§8A.3) · longer Trends periods (6/12 months) · Live Activity (if widget refresh lag is a problem) · Apple Watch · mmol/L · additional sensor families · camera scan of pairing code · forecast line sourced from Trio or the owner's Zen Predict model, clearly labelled.

---

## 13. Decision points — ask Michael once, before Phase 0

1. App name, bundle ID prefix, and repo name. Michael is choosing a new name; keep clear of the Dexcom trademark.
2. Apple Developer Team ID (must match his Trio build) and the App Group ID Trio uses.
3. Path or URL of his Trio fork and branch to integrate with.
4. Whether to apply for the Critical Alerts entitlement now (it only affects a feature flag).
5. Minimum iOS version, if he wants something other than Trio's.
6. Nightscout URL and an access token with read + write (for import and upload), and whether Trio or this app should be the one uploading CGM readings.
7. Whether to turn on Dexcom Share upload for current followers, and his Share region (US or outside US).
