# Replay (`Packages/ReplayKit`, DEBUG only)

`CGMSource` implementations that play a scripted scenario or a Nightscout export, so UI, stats and
alerts can be exercised without a sensor (HANDOFF §4.2, §9.3 WS2, §10 gate 4, §11 step 1).

## DEBUG only (S6)

Every file in `Sources/ReplayKit` is wrapped entirely in `#if DEBUG … #endif`, so a Release build
contains no replay code. Two checks:

- `DebugOnlyTests.test_S6_everyReplayKitSourceFileIsWrappedInIfDebug` scans the source files
  (first line of code `#if DEBUG`, last line `#endif`, balanced, no `#else`).
- `scripts/check.sh` (safety gate) builds ReplayKit in Release and Debug and requires zero
  `$s9ReplayKit` symbols in Release (and some in Debug, so the check cannot pass vacuously).

Every reading a replay source emits has `source == .replay` (`ReplaySource.init` refuses a
timeline with anything else). `LiveReadingGate.validate` refuses them; only the alert engine, in
DEBUG, may use the replay-accepting variant (PROGRESS D11). The Trio bridge and uploaders never
accept replay readings.

**Store:** a replay run writes to a DEBUG replay store — `GlucoseStore.replay()` (in memory) or
`GlucoseStore.replay(at:)` (a separate file) — never the production database. The production
store refuses `.replay` readings and deletes any it finds on open (docs/storage.md, PROGRESS D20).

## Types

| Type | Role |
|---|---|
| `ReplaySource` (actor, `CGMSource`) | Plays any `ReplayTimeline` against a `ReplayClock` |
| `ReplayScenario` | The five scripted scenarios: `timeline(origin:)`, `milestones`, `makeSource(origin:clock:)` |
| `NightscoutExport` | Parses a Nightscout `entries.json` export; LOW/HIGH mapping |
| `NightscoutReplaySource` (`CGMSource`) | Plays a parsed export |
| `ReplayTimeline`, `ReplayEvent` | The data: session, initial state, events (`reading`, `backfill`, `state`) at offsets |
| `ScenarioMilestone` | Named moments (first ≤ 55, backfill delivered, …) |
| `ImmediateReplayClock` | Virtual time that jumps to each deadline: a scenario plays instantly (tests) |
| `ManualReplayClock` | Virtual time moved by `advance(to:)` / `advance(by:)` (step-through tests) |
| `ScaledReplayClock(start:speed:)` | Wall-clock time; `speed` 1 = real time, 60 = one scenario hour per minute (UI demos) |
| `G7ReplaySession` | G7 session shape: 30 min warm-up, 10 days, 12 h grace |

## Using a source

```swift
#if DEBUG
let origin = Date()
let clock = ScaledReplayClock(start: origin, speed: 60)          // or ImmediateReplayClock(start: origin)
let source = ReplayScenario.slowFallToUrgentLow.makeSource(origin: origin, clock: clock)
let store = try GlucoseStore.replay()
try await source.start(pairingCode: nil)
for await reading in source.readings { _ = try await store.insert([reading]) }
#endif
```

- **Time.** Readings are dated `origin + offset`. With `ScaledReplayClock` at speed > 1 scenario
  time runs ahead of the phone clock, so the app's DEBUG replay wiring must use `clock.now()` as its
  clock for staleness, alerts and the `now` passed to `LiveReadingGate` (otherwise readings look
  like they are from the future). At speed 1 with `start: Date()` the two agree.
- **Stream rules** (`CGMSource`): `readings` and `state` are created once, unbounded, returned as
  the same instance for the source's lifetime, and never finished — not by `stop()`, and not when
  the timeline runs out. One consumer each; keep one iterator per stream (dropping an `AsyncStream`
  iterator cancels the stream).
- **State** starts with `.searching` (emitted when the source is created), then follows the
  timeline's state events.
- **`currentSession`** follows the CGMSource lifetime rule (PROGRESS D28): nil until the first
  `start`; then the timeline's session, unchanged across `stop`/`start` (a routine disconnect);
  nil again once the session has ended — the timeline delivered `.expired` or `.failed` (set before
  the state is yielded, so a consumer that sees `.expired` already gets nil), or replay time
  (`clock.now()`) is past `gracePeriodEndsAt`. In `sensorExpiry` it becomes nil at +750 min; the
  other scenarios' timelines end before their sessions do, so the session stays. A replay run is
  not persisted: after an app relaunch a new source starts a new run. Tests:
  `test_currentSessionLifetimeFollowsTheCGMSourceRule`,
  `test_currentSessionAfterPlaybackEndsOnlyWhenTheScenarioEndsTheSession`,
  `test_currentSessionEndsWhenReplayTimePassesTheGracePeriod`.
- **`start` / `stop`.** `start` begins or resumes playback (a second `start` while playing does
  nothing). `stop` pauses and returns only once the playback task has ended, so nothing is
  delivered while stopped. After `start` again, events whose time passed while stopped are
  delivered at once, in order, with their original dates (like a sensor delivering on reconnect).
- `waitForPlayback()` waits until the timeline has been delivered (useful with the immediate clock).

## Scenarios

All offsets are delivery times after `origin`. Every reading is delivered at its own date except
backfill. Values are mg/dL, rates mg/dL/min as "reported". Reading ids are
`GlucoseReading.sensorID(serial:sensorTimestamp:)` with seconds since the session start, so they do
not depend on the origin. Milestones are exposed as data (`ReplayScenario.milestones`) and
`ScenarioTests.test_milestonesMatchTheTimelines` recomputes every one from the timeline, so these
tables cannot drift from the code. No numeric value leaves 40…400; LOW/HIGH are flags with no
rate (S4). Every reading passes `LiveReadingGate`'s DEBUG replay check for the scenario's session at
its delivery time (`test_S2_everyScriptedReadingPassesTheReplayGateForItsSession`).

### `steady` — warm-up, then in range (serial `REPLAY-STEADY`)

Session starts at the origin (new sensor).

| Offset | Event |
|---|---|
| +0 | state `.warmingUp(endsAt: +30 min)` — no readings during warm-up (S2) |
| +30 | state `.active(sessionStart: origin, expiresAt: origin + 10 d)` |
| +30 … +150 every 5 min | 25 readings cycling 112, 113, 114, 113 (rates −0.2, +0.2, +0.2, −0.2) |

Milestones: `warmUpEnds` +30, `firstReading` +30, `lastReading` +150 min.

### `slowFallToUrgentLow` (serial `REPLAY-FALL`)

Session started 3 days before the origin; state `.active` at +0. 31 readings every 5 min, +0…+150.

| min | 0 | 5 | 10 | 15 | 20 | 25 | 30 | 35 | 40 | 45 | 50 | 55 | 60 | **65** | 70 | 75 | 80 | **85** |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| value | 120 | 119 | 118 | 116 | 112 | 107 | 102 | 97 | 92 | 87 | 82 | 77 | 73 | **70** | 66 | 62 | 58 | **55** |
| rate | −0.2 | −0.2 | −0.2 | −0.4 | −0.8 | −1.0 | −1.0 | −1.0 | −1.0 | −1.0 | −1.0 | −1.0 | −0.8 | −0.6 | −0.8 | −0.8 | −0.8 | −0.6 |

| min | 90 | 95 | 100 | 105 | **110** | 115 | 120 | 125 | **130** | 135 | **140** | 145 | 150 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| value | 51 | 47 | 43 | 40 | **LOW** | LOW | 45 | 52 | **60** | 68 | **75** | 82 | 88 |
| rate | −0.8 | −0.8 | −0.8 | −0.6 | — | — | +1.0 | +1.4 | +1.6 | +1.6 | +1.4 | +1.4 | +1.2 |

Milestones: `firstAtOrBelow70` **+65** (70), `firstAtOrBelow55` **+85** (55), `firstLowFlag`
**+110**, `backAbove55` +130 (60), `backAbove70` +140 (75), `firstReading` +0, `lastReading` +150.
No |rate| reaches 3, so rise/fall alerts must not fire.

### `compressionLowSpike` (serial `REPLAY-COMPRESSION`)

Session started 5 days before the origin; state `.active` at +0. 25 readings, +0…+120.

| min | 0–30 | **35** | **40** | **45** | 50 | 55 | **60** | 65 | 70 | 75–120 |
|---|---|---|---|---|---|---|---|---|---|---|
| value | 129–131 | **98** | **64** | **52** | 51 | 53 | **90** | 124 | 128 | 129–131 |
| rate | 0.0 or ±0.2 | −6.2 | −6.8 | −2.4 | −0.2 | +0.4 | +7.4 | +6.8 | +0.8 | 0.0 or ±0.2 |

Exact values +0…+30: 130, 131, 130, 129, 130, 130, 129; +75…+120: 129, 130, 130, 129, 130, 131,
130, 130, 129, 130.

Milestones: `firstFallRateAtLeast3` **+35** (−6.2), `firstAtOrBelow70` **+40** (64),
`firstAtOrBelow55` **+45** (52), `backAbove55` **+60**, `backAbove70` **+60** (90),
`firstRiseRateAtLeast3` **+60** (+7.4), `firstReading` +0, `lastReading` +120. Readings ≤ 55 at
+45, +50, +55 (15 minutes).

### `signalGapWithBackfill` (serial `REPLAY-GAP`)

Session started 1 day before the origin; state `.active` at +0.

| Offset | Delivered |
|---|---|
| +0 … +30 every 5 min | live: 140, 143, 146, 149, 152, 155, 158 (rate +0.6) |
| +35 … +70 | **nothing** — 45 minutes without a delivery (+30 → +75) |
| +75 | live +75 reading (180, +0.4) **then** one backfill batch: +35 … +70 = 161, 164, 167, 170, 172, 174, 176, 178, each `isBackfill = true`, original timestamps, ascending (S3) |
| +80 … +120 every 5 min | live: 181, 182, 182, 181, 180, 178, 176, 174, 172 |

The live reading comes before the backfill in the same delivery, the order a G7 connection
delivers, so consumers see an older reading after a newer one and must not treat it as current.
All values in range. Milestones: `lastReadingBeforeGap` +30, `liveReadingsResume` +75,
`backfillDelivered` +75, `firstReading` +0, `lastReading` +120. (With the default 15-minute
missed-readings window, that alert becomes due at +45.)

### `sensorExpiry` (serial `REPLAY-EXPIRY`)

Session started 10 days − 30 min before the origin: rated life ends at +30 min, grace period ends
at +750 min (12 h later).

| Offset | Event |
|---|---|
| +0 | state `.active(…, expiresAt: +30 min)` |
| +30 | state `.gracePeriod(endsAt: +750 min)` |
| +750 | state `.expired` — last event; no reading after it |

150 readings, every 5 min from +0 to **+745** (the last reading):

| Offsets | Values | Rate |
|---|---|---|
| +0 … +55 | 125 | 0.0 |
| +60 | 128 | +0.6 |
| +65 … +155 | 142 + 14·k, k = 0…18 (142 … 394; **254 at +105**) | +2.8 |
| **+160, +165, +170** | **HIGH** flag | — |
| +175 … +285 | 396 − 12·k, k = 0…22 (396 … 132; **240 at +240**) | −2.4 |
| +290 | 130 | −0.4 |
| +295 … +745 | 130 | 0.0 |

Milestones: `gracePeriodStarts` +30, `firstAtOrAbove250` **+105** (254), `firstHighFlag` **+160**,
`backBelow250` +240 (240), `lastReading` +745, `expired` **+750**, `firstReading` +0. No |rate|
reaches 3.

### Where the flags are

| Flag | Scenario | Offsets |
|---|---|---|
| LOW (`.belowRange`) | `slowFallToUrgentLow` | +110, +115 |
| HIGH (`.aboveRange`) | `sensorExpiry` | +160, +165, +170 |
| warm-up | `steady` | +0 … +30 |

## Nightscout export replay

```swift
let export = try NightscoutExport.parse(data)             // entries.json, any order
let source = try NightscoutReplaySource(export: export, origin: Date(), clock: ScaledReplayClock(start: Date(), speed: 1))
```

- Only `type == "sgv"` entries are used; `mbg`, `cal` and entries without a type are ignored.
  Time comes from `date` (ms since 1970, the canonical Nightscout field); `dateString` is ignored.
  An sgv entry without a numeric `sgv` or `date` is skipped as malformed (numeric strings are
  accepted; booleans are not). Entries with exactly the same `date` as an earlier one are dropped
  (Nightscout often holds a reading from two uploaders). Counts of everything skipped are on
  `NightscoutExport`.
- **LOW/HIGH mapping** (cgm-remote-monitor 15.0.8, commit `92d0834`, in `vendor-ref/cgm-remote-monitor`):

  | sgv | Nightscout meaning | Source | Replay |
  |---|---|---|---|
  | < 39 | Dexcom error/status code (1 SENSOR_NOT_ACTIVE, 2 MINIMAL_DEVIATION, 3 NO_ANTENNA, 5 SENSOR_NOT_CALIBRATED, 6 COUNTS_DEVIATION, 9 ABSOLUTE_DEVIATION, 10 POWER_DEVIATION, 12 BAD_RF) | `lib/plugins/errorcodes.js:13-22`, `:42`; `lib/plugins/bgnow.js:99-100`; `lib/client/index.js:542-543` | skipped: not a reading (S1) |
  | 39 (anything < 40) | LOW | `lib/client/index.js:544-545`; `lib/sandbox.js:249-250` (`=== 39`) | `.belowRange` (S4) |
  | 40 … 400 | glucose | | `.mgdl(n)`, fractional sgv rounded |
  | > 400 (uploaders send 401) | HIGH | `lib/client/index.js:546-547`; `lib/sandbox.js:251-252` (`=== 401`) | `.aboveRange` (S4) |

- **Timing.** The first entry lands on `origin`; spacing and gaps are kept exactly (nothing is
  filled in, S1). Pass `export.entries.first!.date` as the origin to keep the export's own times.
  Every reading is live (`isBackfill = false`), delivered at its own date.
- **Trend rate is always nil.** Entries carry a `direction` name, not the sensor's rate; turning a
  name back into a number would fabricate one (S1). Arrows show "not computable" during a
  Nightscout replay.
- **Session** (synthetic, serial `REPLAY-NIGHTSCOUT`): starts 1 h before the first entry
  (warm-up over 30 min before it), expires at the later of start + 10 days and the last entry,
  plus 12 h grace. State: `.searching`, then `.active` at +0. Reading ids:
  `REPLAY-NIGHTSCOUT:<milliseconds since session start>` (the first is `:3600000`). Milliseconds,
  not the G7's seconds, because an export carries millisecond timestamps: two entries less than a
  second apart (two uploaders) stay two distinct readings instead of colliding on one id and being
  dropped as a re-delivery. Entries with exactly the same `date` are dropped and counted by
  `NightscoutExport` (test `test_S3_entriesLessThanASecondApartStayDistinct`).

### Fixture

`Tests/ReplayKitTests/Fixtures/nightscout-entries.json` — synthetic, no personal data, 25 entries,
newest first, device `synthetic-fixture`:

- Segment A from 2026-01-10T08:00Z: 352, 371, 389, **401, 401 (HIGH)**, 396, 380 at 08:30 plus an
  exact-date duplicate from `second-uploader`, an `mbg` entry, 362 at 08:35; **a 30-minute hole
  (08:40–09:05)**; 301 at 09:10, 287.6 at 09:15 (→ 288); a `cal` entry.
- Segment B from 14:00Z: 96, 84, 72, 61, 50, 42, **39 (LOW)** at 14:30, **10 (error code)** at
  14:35, 44, 58, 75 at 14:50; one `sgv` entry without `date`.
- Result: 20 readings; 2 non-sgv ignored, 1 error code, 1 malformed, 1 duplicate.

## Tests

`swift test` in `Packages/ReplayKit` (39 tests; every test file is also inside `#if DEBUG`):

- determinism: same origin → same timeline and same streams; ids independent of the origin;
- `test_S1_*`: a source emits exactly the script/export and nothing else (the playback log is the
  single place that yields); gaps stay gaps until the scripted backfill;
- `test_S2_*`: every scripted and every exported reading passes the DEBUG replay check of
  `LiveReadingGate` for its session at its delivery time (two origins, one fractional);
- `test_S3_*`: backfill flagged, original timestamps, ascending, ids from session time; live
  readings in date order;
- `test_S4_*`: Nightscout 39/401 conventions → flags; scenario flags where documented; no numeric
  value outside 40…400;
- `test_S6_*`: every emitted reading is `.replay` (and the production gate refuses it); every
  source file is inside `#if DEBUG`;
- stream rules: a 288-reading backfill burst arrives complete (scripted and Nightscout);
  `stop()` then `start()` keeps delivering on the same streams (scripted and Nightscout);
- `currentSession` lifetime (nil before start, kept across stop/start, nil once ended);
- milestones recomputed from the timelines.
