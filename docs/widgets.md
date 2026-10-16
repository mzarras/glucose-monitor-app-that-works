# Widgets

HANDOFF §7.4. One widget ("Glucose", kind `GlucoseWidget`) in four families: **medium** (priority:
reading, arrow, delta, live age on the left; 3-hour chart with the 70–180 band on the right),
**small** (reading, arrow, age), Lock Screen **rectangular** (reading, arrow, age, sparkline) and
**inline** ("105 → · 3m"). An old reading stays on screen, muted and labelled with its time (D61,
"Staleness and refresh"). Tapping any of them opens the Now screen. Widgets always follow the
system light/dark setting (the app's Appearance override does not apply to them); the accent comes
from the snapshot.

## Architecture

```
app (Phase 2 wiring)                      App Group container                 widget extension
─────────────────────                     ───────────────────                 ────────────────
store change / sensor state change
  → WidgetSnapshot.make(readings:…)        widget-snapshot.json   ──read──→   GlucoseTimelineProvider
  → WidgetSnapshotStore.write   ──write──→ (atomic, protection:                 → WidgetTimeline.entries
  → WidgetCenter.reloadAllTimelines         completeUntilFirstUser-             → MediumWidgetView / …
    only if WidgetReloadKey changed         Authentication)
    (LiveWidgetPublisher, D61)
```

| Piece | File | Notes |
|---|---|---|
| Snapshot model | `Packages/WidgetCore/Sources/WidgetCore/Snapshot/WidgetSnapshot.swift` | `WidgetSnapshot.make(latestLive:previousLive:recent:…)` only *selects*: the repository's `latestLiveReading()` however old (so a reading older than 3 h is still shown as the last reading, D61), the live reading before it for the delta, and the stored readings from `chartWindowStart` (3 h before the latest reading or before now, whichever is earlier) for the chart. An imported reading passed as "live" is ignored (S6). |
| File I/O | `…/Snapshot/WidgetSnapshotStore.swift` | `[.atomic, .completeFileProtectionUntilFirstUserAuthentication]` (HANDOFF §4.5); App Group from Info.plist `AppGroupID`. The widget reads through `snapshotForWidget()` / `readOrNil()`: empty, truncated, corrupt or other-schema files all read as nil (tested). |
| Timeline | `…/Timeline/WidgetTimeline.swift` | Pure: entries and reload date from a snapshot and `now`. |
| Display rules | `…/Formatting/GlucoseDisplayState.swift` | Shared with the Now screen: fresh / stale / no data / warm-up / expired / error / not paired. |
| Widget number | `…/Formatting/WidgetReading.swift` | Widget only (D61): `GlucoseDisplayState.widgetReading` — current, stale or last reading, with the arrow and delta only while current; `ReadingDay` for the last reading's day label. The Now screen keeps `displayedReading`. |
| Reload key | `…/Snapshot/WidgetReloadKey.swift` | What the widget displays from a snapshot; the app reloads only when it changes (D61, "Reload policy"). |
| Layouts | `…/Views/WidgetViews.swift` | Plain SwiftUI (no WidgetKit) so the app's tests can render them to `docs/screenshots/`. |
| Extension | `Widgets/Sources/SensorWidgets.swift` | Provider, `containerBackground`, `widgetURL`. Previews: `Widgets/Sources/WidgetPreviews.swift`. |
| App side | `App/Sources/WidgetBridge/WidgetSnapshotPublisher.swift`, `App/Sources/Services/LiveWidgetPublisher.swift` | The pipeline publishes after every drain (store change, sensor-state change); the snapshot is written every time, the reload requested only when the `WidgetReloadKey` changes. |

The widget **never computes or guesses a value** (S1): every number it shows is the snapshot's
`latest` exactly as written, and the chart draws the snapshot's `recent` points through the same
`ChartSeries` segmentation as the app (gaps > 15 min break the line; LOW/HIGH are edge markers,
never 40/400). `WidgetTimelineTests.test_S1_widgetTimelineNeverSynthesizesAValue` asserts that no
timeline entry can display anything but the snapshot's own reading.

## Snapshot format (schema version 1)

JSON, keys sorted, dates as integer **milliseconds since 1970** (same unit as Nightscout `date`).
Enums use Swift's synthesized `Codable` shape. Example (105 mg/dL, steady, −3 in 5 min, a LOW 10
minutes earlier):

```json
{
  "accent" : "forest",
  "latest" : {
    "date" : 1790166720000,
    "delta" : { "mgdl" : -3, "minutes" : 5 },
    "trend" : "flat",
    "value" : { "mgdl" : { "_0" : 105 } }
  },
  "recent" : [
    { "date" : 1790166120000, "value" : { "belowRange" : {} } },
    { "date" : 1790166420000, "value" : { "mgdl" : { "_0" : 108 } } },
    { "date" : 1790166720000, "value" : { "mgdl" : { "_0" : 105 } } }
  ],
  "schemaVersion" : 1,
  "sensorState" : { "active" : { "expiresAt" : 1790550900000, "sessionStart" : 1789686900000 } },
  "writtenAt" : 1790166900000
}
```

| Field | Meaning |
|---|---|
| `schemaVersion` | 1. The widget treats any other version as "no snapshot" and shows *No data*. Bump on incompatible changes. |
| `writtenAt` | When the app wrote the file ("last updated"). |
| `latest` | Newest live reading or absent. `value` keeps LOW/HIGH as `belowRange`/`aboveRange` (S4). `trend` is `TrendArrow` from the sensor-reported rate. `delta` is absent when either reading is a flag or they are > 15 min apart. |
| `sensorState` | `SensorState` at write time (drives warm-up / expired / error / not-paired messages). |
| `recent` | Readings from 3 h before the earlier of `latest` and `writtenAt`, up to `writtenAt`, ascending; may include imported history (charts only). For an old `latest` this is its last 3 h (D61). |
| `accent` | `forest` / `rust` / `navy` / `ink`. |
| `isReplay` | DEBUG only (audit m9): `latest` came from a replay or mock source, and the widget shows "REPLAY" beside it. Always `false` in Release; absent in older snapshots (read as `false`). |

A missing, unreadable or wrong-version file, or a missing App Group, all read as "no snapshot" and
render *No data* — never a number.

## Staleness and refresh

The ages are **live relative text** (`LiveAge`): the system keeps them counting without a widget
reload. On iOS 18+ they show whole minutes rounded down ("3 min ago", "1 hr, 5 min ago", "2 days,
3 hr ago"), matching the thresholds below; on iOS 17 the only live style counts seconds ("3 min,
12 sec ago").

Each timeline carries future entries, so the widget changes state on time even if the app never
runs again (S5):

| When | Entry |
|---|---|
| now | current state |
| latest + 10 min | **stale**: number in the muted colour (≥ 3:1, not faded), **no trend arrow, no delta**, "STALE · 10 min ago" in the alert colour, VoiceOver "Stale: 105 milligrams per deciliter", chart dimmed to 0.6 without the "latest" dot |
| latest + 20 min | **last reading** (D61), with no upper age limit: the same muted number, no arrow, no delta, "LAST READING" and "2:14 PM · 47 min ago" in the alert colour; VoiceOver "Last reading 105 milligrams per deciliter at 2:14 PM, 47 min ago"; the dimmed chart ends at the reading (below) |
| local midnight after the reading, and the one after | the last reading's day label: "Yesterday 11:02 PM", then "Sep 21 11:02 PM" |
| warm-up end | stops claiming warm-up; the age rules apply again (*No data* when there is no reading) |
| grace-period end | *Sensor expired* |

The arrow and the delta describe the moment of the reading; next to an old number they would read
as the current direction, so only a current reading has them. LOW and HIGH stay "LOW"/"HIGH" in
every state (S4). The Now screen is unchanged: its hero never shows an old number on its own
(HANDOFF §7.3); only the widget uses `GlucoseDisplayState.widgetReading`.

Still no number: no snapshot or never a reading ("No data · Open the app to check the sensor"),
warm-up, sensor expired (also at the grace period's end), sensor error, a failure that raises the
sensor alert, calibration needed or rejected, not paired, and a clock mismatch.

Per family (last reading):

| Family | Shows |
|---|---|
| medium | muted number, unit, "LAST READING", "2:14 PM · 47 min ago" (another day: "Yesterday 11:02 PM", then "12 hr, 13 min ago" on its own line); chart (right) ends at the reading, with the reading's time under its right edge so the axis isn't read as "now" |
| small | as the medium's left side |
| rectangular | muted number, "LAST READING", "2:14 PM · 47m" (another day: a smaller number, "Yesterday 11:02 PM", then "12h 13m ago"), dimmed sparkline ending at the reading (no time label: no room, the text beside it gives the time) |
| inline | "Last 112 · 2:14 PM" (stale: "Stale 112 · 12m", no arrow) |

**Clock and day label.** The time uses the system time style (`Text(date, style: .time)`), so a
24-hour locale shows "14:14". When the reading was not taken on the entry's local day the label
names the day: "Yesterday 11:02 PM", or an abbreviated date ("Sep 21 11:02 PM") from the day after.
The timeline has an entry at each of the two local midnights that change it (`ReadingDay`, calendar
arithmetic, so a 23- or 25-hour DST day is still one day); midnights while the widget shows a
message or a current/stale reading add no entry. These entries don't move the reload date (below).

**Chart anchoring.** For a last reading the 3-hour chart (medium) and sparkline (rectangular) end at
the reading's own date instead of the entry's, so the last known 3 hours stay visible instead of
scrolling off to an empty chart (`WidgetEntryContent.chartDomain`). Not `writtenAt`: the app rewrites
the snapshot on every wake, so that date keeps moving with no new reading. The snapshot carries the
3 hours before the latest reading for this (`WidgetSnapshot.chartWindowStart`). Still only real
points through `ChartSeries` (S1); gaps > 15 min still break the line. Stale entries keep the
chart ending at the entry's date (the empty right edge is the gap).

**Clock mismatch (reviews M1, N1).** If the latest reading is dated more than 60 s ahead of the
phone's clock, dated after the snapshot's own write time, or the clock is now earlier than that
write time (the clock was moved back), the widget shows **"Check phone clock"** and no number. This
is latched (`ClockMismatchLatch`): every later entry of the timeline, and every timeline built from
the same reading (the extension keeps the reading's date in its own `UserDefaults`), stays a
mismatch — even after the clock passes the reading's date — until the app writes a newer reading.

Timeline policy: `.after(last state change + 1 min)`, or `.after(now + 15 min)` when no state
change is scheduled (so a snapshot written while the app's reload request was throttled is still
picked up). Midnight day-label entries are ignored for this (they can be two days away).

## Reload policy (D61)

iOS gives a widget a budget of roughly 40–70 reloads a day while its app is in the background
(reloads requested while the app is in the foreground are not budgeted). The pipeline publishes
after every drain — every sensor state event (searching, connecting, authenticating, active, …),
several per 5-minute wake — and requesting a reload each time can spend the budget within hours,
mostly on snapshots that display nothing new, after which the widget goes stale while the app keeps
running in the background.

So the app writes the snapshot file on every publish (cheap; keeps `writtenAt` fresh for the
widget's own idle reload and its clock check) but calls `WidgetCenter.shared.reloadAllTimelines()`
only when `WidgetReloadKey` differs from the key of the last snapshot it requested a reload for:

| In the key | Why |
|---|---|
| latest reading (date, value, trend, delta) | the number, arrow, delta and every age transition |
| chart points from 3 h before the earlier of the latest reading and `writtenAt` | every chart the timeline can draw starts there or later; points that drop out below it change nothing |
| sensor state, reduced (`WidgetSensorKey`) | searching / connecting / authenticating / active / Bluetooth unavailable / a transient failure are one value (readings judged by age); warm-up (with its end), grace period (with its end), expired, error (code, text), an alerting failure (kind, message), calibration needed, calibration rejected, not paired are each distinct |
| accent, `isReplay` | colours, the DEBUG REPLAY marker |
| reading dated after its snapshot (beyond 60 s) | the clock-moved-back check |

The first publish of the process (no key yet) reloads, and so does the first one after the app
comes to the foreground (`LiveAppServices.handleForeground` calls `reloadOnNextPublish()`). A
failed write never reloads. Each requested reload is one diagnostic line (category `app`), e.g.
`widget reload requested: new reading 2026-10-16T18:14:00Z` or `… sensor state expired`; skipped
ones are not logged. In steady state that is one reload and one line per reading.

iOS can still throttle a requested reload, so the widget can lag the app by several minutes; its
own scheduled reload (timeline policy above) then picks up the file. If that is too much in practice, the fix is a Live
Activity (v1.1, HANDOFF §12).

## Deep link

`widgetURL` = `<BUNDLE_ID_PREFIX>://now` (`Widgets/Info.plist` `HostAppURLScheme`; the app registers
the same scheme in `App/Info.plist` `CFBundleURLTypes`). The app selects the Now tab on any
`…://now` URL.

## Tests

- `WidgetSnapshotTests`: JSON round trip for every sensor state, flags survive encoding (S4),
  millisecond dates, wrong schema rejected, store write/read/overwrite, writing options (atomic +
  `completeUntilFirstUserAuthentication` on iOS), live-only current value (`test_S6_…`),
  `test_S5_oldLatestReadingIsKeptOutsideTheChartWindow`, `test_S5_corruptTruncatedOrEmptyFileReadsAsNoData`,
  `test_oldLatestReadingKeepsItsLastThreeHoursForTheChart` (D61), and the REPLAY marker on every
  displayed number, a last reading included (`test_m9_…`).
- `WidgetTimelineTests`: fresh → stale → last reading (with the midnight entries), LOW / HIGH,
  warm-up, expired, grace period, `test_S5_oldReadingIsShownOnlyMutedWithItsAgeAndNeverAsCurrent`
  (every entry ≥ 10 min old is muted, without arrow or delta, with its STALE label or its time; never
  current styling), `test_S4_lastReadingKeepsLowAndHighFlags`, `test_S5_messageStatesShowNoNumber`,
  `test_S5_futureDatedReadingIsNeverShownAsCurrent` and the other clock-mismatch tests,
  `test_S1_widgetTimelineNeverSynthesizesAValue`, the day label at local midnight and across a DST
  change, chart anchoring, reload policy (midnight entries don't move it).
- `WidgetReloadKeyTests`: state churn and rewrites don't reload; a new reading, expired, warm-up
  (and its end), grace period, error, alerting failures, calibration, not paired, accent, replay,
  chart history and the clock check do; points leaving below the chart floor don't; log text.
- App: `WidgetReloadPolicyTests` (the publisher reloads only when the key changes, through an
  injected reload call; one log line per reload; the foreground reload; a failed write never
  reloads).
- Previews for every family × state, light and dark, plus a stale / last-reading set per family:
  `Widgets/Sources/WidgetPreviews.swift`.
- Rendered (`ScreenshotTests.test_renderWidgets`): `docs/screenshots/widget-medium-*.png`
  (`widget-medium-last-reading-*` for D61), `widget-small-*.png`, `widget-lock-screen-*.png`
  (rectangular and inline), `widget-replay-debug-*.png`.

File protection itself cannot be observed in the simulator or on the macOS host; §11 step 3a checks
it on device (widget keeps updating while the phone stays locked for hours).

## Measured on device

To be filled in by Michael during HANDOFF §11 step 3a (24-hour soak with the medium widget on the
Home Screen).

Also check once, on device:

- [ ] **Clock moved back.** With a widget timeline already queued (medium widget showing a current
  reading), set the phone clock back 1 h (Settings › General › Date & Time, Set Automatically off).
  Confirm WidgetKit reloads and the widget shows the clock-mismatch state ("Check phone clock"),
  not an old number as current. Then turn Set Automatically back on and confirm the widget returns
  to normal after the next reading.

| Date | iOS | Condition (unlocked / locked / Low Power) | Typical lag app → widget | Worst lag | Stale / last-reading states seen correctly? | Notes |
|---|---|---|---|---|---|---|
| | | | | | | |
