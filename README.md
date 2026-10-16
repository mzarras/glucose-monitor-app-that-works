# glucose

An open-source iOS app that connects directly to a **Dexcom G7 10-day sensor** as its primary
(authenticating) Bluetooth device. It stores and shows the readings, runs its own alerts, hands
valid readings to [Trio](https://github.com/nightscout/Trio) through Trio's existing App Group
source, and uploads to Nightscout and, optionally, Dexcom Share so followers keep getting data.
Build from source only. GPL-3.0.

> **Not a medical device.** No regulator has cleared or approved this software. It comes with
> **no warranty** of any kind (GPL-3.0, sections 15 and 16). Its output can reach an automated
> insulin delivery system: if you build and run it, what it does is your responsibility. Check
> readings that don't match how you feel with a fingerstick meter.

**Status:** tested with a live G7 sensor in **listen mode**, following the Dexcom app's own
connection on the same phone. Testing continues in **primary mode** with the Dexcom app fully
deleted: pairing, the Trio handoff and the Nightscout and Dexcom Share uploads, over a full sensor
session (`docs/setup.md` §5). The automated gates pass (`PROGRESS.md`). The app is called "glucose" (D52); "Sensor" is the working name of the project, its targets and packages.

## What it is, and what it isn't

It is:

- a primary-mode G7 collector: pairing with the sensor's 4-digit code (J-PAKE), ported from
  [xDrip4iOS](https://github.com/JohanDegraeve/xdripswift) 7.1.0. Only one app can be a sensor's
  primary device, so the Dexcom app must be removed from the phone. A Dexcom receiver is expected to
  keep working alongside in its own slot (unverified on hardware). A listen mode can instead run
  alongside the Dexcom app (below);
- a reader and reporter: readings, statistics, alerts, Trio handoff, Nightscout and Dexcom Share
  uploads, history import, widgets.

It is not:

- an insulin-dosing app. There is no dosing logic of any kind; Trio doses;
- a predictor of its own: the Predict tab only displays forecasts from an external model you host
  (below). Forecasts never drive alerts ("urgent low soon" uses only the sensor's reported rate),
  never reach Trio or the uploads, and are never shown as a reading;
- for other sensors: G7 15-day, ONE+, Stelo, G6 and Libre are not supported (a 15-day G7 is refused);
- on the App Store or TestFlight;
- in v1: Apple Watch, Live Activities, HealthKit, mmol/L, a follower mode.

## Safety

The app's output feeds an insulin-dosing system, so eight rules (HANDOFF §2) are enforced in code
and each has named tests (`test_S1_…` … `test_S8_…`); `scripts/check.sh` fails unless every rule has
at least one passing test. Where each rule is enforced and which tests prove it:
[`docs/safety-review.md`](docs/safety-review.md). Failure modes (system kill, reboot, Bluetooth,
permissions, disk full, clock and time-zone changes): [`docs/failure-modes.md`](docs/failure-modes.md).

| Rule | In short | How |
|---|---|---|
| S1 | Never fabricate a reading | Nothing interpolated, smoothed or synthetic is stored, shown as current, sent to Trio or used for alerts. Charts draw lines only between real readings and break at gaps over 15 minutes; AGP percentile lines are smoothed for display only. A reading dated ahead of the phone clock is never shown as current. |
| S2 | Only authenticated, valid readings | G7Kit publishes only from an authenticated connection when the sensor reports the value valid. Every live reading then passes `LiveReadingGate` (sensor source, a known session with a matching serial, after warm-up, before the grace period ends, at most 60 s ahead of the clock, a number within 40–400) **before** it is stored; each consumer checks again. |
| S3 | Timestamps are derived | Dates come from the sensor's own clock and session start; readings are deduplicated by sensor timestamp and kept in sensor-time order; backfill keeps its time and is flagged `isBackfill`. |
| S4 | LOW and HIGH stay flags | Never stored or shown as 40/400. Only the Trio, Nightscout and Dexcom Share payloads encode them, as the ecosystem's 39/401 (D21, D29, D30). |
| S5 | Fail loud | Missed readings, Bluetooth off or not allowed, sensor errors and expiry, a failing Trio handoff, a failing database and failing uploads each show a banner; the ones HANDOFF §5 lists also alert. |
| S6 | Only live sensor data reaches Trio, alerts and uploads | Imported history feeds charts and statistics only. Replay code exists only in DEBUG builds (`check.sh` verifies the Release objects with `nm`), and DEBUG builds keep the Trio handoff and uploads paused. |
| S7 | Urgent low can't be disabled | No off switch in the settings types, the UI or stored settings; snooze is clamped to 30 minutes everywhere, including the lock screen and the alarm's Stop button. |
| S8 | Auditable | Small packages with one job each; ported files carry their source and release; protocol bytes are cited in [`docs/g7-protocol.md`](docs/g7-protocol.md). |

## Features

- **Sensor**: pairing and the iOS pairing prompt, warm-up countdown, a reading every 5 minutes,
  backfill after a gap, CoreBluetooth state restoration, session and grace-period tracking,
  fingerstick calibration sent to the sensor (never stored as a reading), "Forget sensor".
- **Listen mode** ([`docs/g7-protocol.md`](docs/g7-protocol.md) §14): reads the sensor through the
  Dexcom app's own connection on the same phone, with no pairing code; no backfill, no calibration,
  and no Trio handoff or uploads while listening.
- **Now**: current reading, trend arrow from the sensor-reported rate, 5-minute delta, a 3/6/12/24 h
  chart with the 70–180 band and scrubbing to the nearest real reading, "Today so far", sensor and
  Trio status, a live countdown during the grace period, and a banner for every problem.
- **Trends** (1/3/7/14/30/90 days): time in range bins, tight range, mean, SD, CV, GMI (14 days and
  longer), data sufficiency, AGP, hypoglycaemia events (2023 consensus definitions), overnight vs
  day, change against the prior period, longest in-range streak
  ([`docs/statistics.md`](docs/statistics.md)).
- **Alerts** ([`docs/alerts.md`](docs/alerts.md)): urgent low, urgent low soon, low, high (with an
  optional delay), rising and falling fast, missed readings, sensor warm-up done, expiry reminders
  (24 h, 12 h, 2 h, grace period, expired), sensor failed or error, calibration needed, Bluetooth,
  Trio handoff, history not being saved. Eight original sounds with preview, a default per alert,
  each changeable. Quiet hours (urgent low always sounds). On silent: the app plays the sound itself
  while it is awake for a sensor wake-up; on iOS 26+ urgent low and its repeats can ring as system
  alarms (AlarmKit); Critical Alerts are used if Apple grants the entitlement.
- **Predict** ([`docs/forecast.md`](docs/forecast.md)): forecasts at +5, +30, +60 and +120
  minutes from the author's own machine-learning model (Zen Predict), trained on the author's
  historical glucose data and run every 5 minutes in a private cloud account; the app reads its JSON
  feed. The model is personal and not part of this repository; to use the tab, point it at a feed of
  your own in the same format (`ZEN_PREDICT_FEED_HOST`, `docs/setup.md` §4.6). Without a feed host
  the tab explains how to set one up. Forecasts are labelled as predictions with their model-run
  time, fetched only while the app is open, never saved, and hidden once a run is more than
  15 minutes old.
- **Trio** ([`docs/trio-bridge.md`](docs/trio-bridge.md)): writes valid sensor readings in the format
  Trio's xDrip4iOS source reads, plus the heartbeat that lets Trio loop in the background. No Trio
  patch.
- **Followers** ([`docs/following.md`](docs/following.md)): Nightscout upload; Dexcom Share upload
  (unofficial interface) so Dexcom Follow keeps working. Queued and retried offline.
- **History import** ([`docs/import.md`](docs/import.md)): from Nightscout or a Dexcom Clarity CSV
  export, for charts and statistics.
- **Widgets** ([`docs/widgets.md`](docs/widgets.md)): medium, small, and Lock Screen rectangular and
  inline; they turn stale at 10 minutes and "No data" at 20 on their own.
- **Data**: on the phone only, in SQLite; kept 2 years by default (90 days, 1 year, 2 years or
  forever); included in device backups; CSV export; a diagnostic log export for bug reports.
  Readings leave the app only through the Trio App Group (on the phone), the Nightscout and Dexcom
  Share uploads you turn on, files you export, and your backups.
- Light, dark or system appearance; four accent colours. mg/dL only.

## Architecture

```
G7 sensor ─BLE─▶ G7Kit ─▶ LiveReadingGate ─▶ GlucoseStore ─▶ newly stored readings ─┬─▶ TrioBridge ─▶ Trio's App Group
                                                                                    ├─▶ AlertEngine ─▶ notifications, audio, AlarmKit
                                                                                    ├─▶ NightscoutKit uploaders ─▶ Nightscout, Dexcom Share
                                                                                    └─▶ WidgetCore snapshot ─▶ widgets
Nightscout, Clarity CSV ─▶ NightscoutKit importers ─▶ GlucoseStore ─▶ charts and statistics only
```

Each consumer checks the reading again. If the database fails, gated readings still reach alerts
and Trio (D42). Details: [`docs/architecture.md`](docs/architecture.md),
[`docs/app-wiring.md`](docs/app-wiring.md).

| Package (`Packages/`) | Responsibility | Docs |
|---|---|---|
| `GlucoseCore` | Domain types (readings, LOW/HIGH flags, sensor state and session), the `CGMSource` protocol, `LiveReadingGate`, trend arrows, diagnostics. No I/O | [`docs/architecture.md`](docs/architecture.md) |
| `G7Kit` | Bluetooth, J-PAKE pairing, authentication, message parsing, backfill, session timing, calibration. Ported from xDrip4iOS 7.1.0 | [`docs/g7-protocol.md`](docs/g7-protocol.md) |
| `GlucoseStore` | SQLite (GRDB): deduplication, range queries, retention, CSV export; production and DEBUG replay roles | [`docs/storage.md`](docs/storage.md) |
| `GlucoseStats` | Pure functions for every statistic | [`docs/statistics.md`](docs/statistics.md) |
| `AlertEngine` | Alert rules, state machine, delivery (notifications, in-app audio, AlarmKit, Critical Alerts), sounds | [`docs/alerts.md`](docs/alerts.md) |
| `TrioBridge` | Trio's App Group contract and heartbeat keys | [`docs/trio-bridge.md`](docs/trio-bridge.md) |
| `NightscoutKit` | Nightscout and Dexcom Share uploaders; Nightscout and Clarity CSV importers | [`docs/following.md`](docs/following.md), [`docs/import.md`](docs/import.md) |
| `ForecastKit` | Fetches and validates the Predict feed; no dependencies, so a forecast can't become a reading (D57) | [`docs/forecast.md`](docs/forecast.md) |
| `ReplayKit` | DEBUG only: scripted scenarios and Nightscout-export replay | [`docs/replay.md`](docs/replay.md) |
| `WidgetCore` | Widget snapshot, timelines, display rules and views shared with the app | [`docs/widgets.md`](docs/widgets.md), [`docs/design-tokens.md`](docs/design-tokens.md) |

The app target (`App/`) composes them: the reading pipeline, services, screens and onboarding. The
widget extension is `Widgets/`. The Xcode project is generated from `project.yml` with XcodeGen.

## Building

You need Xcode 26.2, XcodeGen, an iPhone on iOS 17 or later (iOS 26 for AlarmKit), and the Apple
Developer team that signs your Trio build. Signing, App Groups, building to the phone,
configuration and the on-device validation plan: **[`docs/setup.md`](docs/setup.md)**.

```sh
brew install xcodegen
cp Config/Signing.example.xcconfig Config/Signing.xcconfig   # Team ID, bundle ID, App Groups
xcodegen generate
scripts/check.sh                                             # gates: build, tests, safety, replay
```

Use a DEBUG build only for replay scenarios; anything with a real sensor uses a Release build
(`docs/setup.md` §3). Certify and fast gate runs, targeted tests, build slots and the simulator pool:
[`docs/gates.md`](docs/gates.md).

## License and credits

GPL-3.0: see [`LICENSE`](LICENSE). This project builds on the diabetes open-source community: code
ported from xDrip4iOS (with micro-ecc), GRDB.swift, and research and test vectors from LoopKit,
xDrip+, Juggluco, Mbed TLS, Loop, Nightscout and Trio. Ported files keep their original copyright
header where upstream had one, and name the file and release they came from. The full list, licences, fonts (SIL Open Font License)
and sounds: [`NOTICE.md`](NOTICE.md).

## Trademarks

"Dexcom" and "G7", and the names of Dexcom's services (Dexcom Share, Dexcom Follow, Dexcom Clarity),
are trademarks of Dexcom, Inc. This project is not affiliated with or endorsed by Dexcom, nor by
the Trio, Nightscout, xDrip4iOS or Loop projects. It calls the sensor "G7 sensor" and keeps
"Dexcom" out of the app's name and bundle ID.
