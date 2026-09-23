# Widgets

HANDOFF §7.4. One widget ("Glucose", kind `GlucoseWidget`) in four families: **medium** (priority:
reading, arrow, delta, live age on the left; 3-hour chart with the 70–180 band on the right),
**small** (reading, arrow, age), Lock Screen **rectangular** (reading, arrow, age, sparkline) and
**inline** ("105 → · 3m"). Tapping any of them opens the Now screen. Widgets always follow the
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
    (WidgetSnapshotPublisher)               Authentication)
```

| Piece | File | Notes |
|---|---|---|
| Snapshot model | `Packages/WidgetCore/Sources/WidgetCore/Snapshot/WidgetSnapshot.swift` | `WidgetSnapshot.make(latestLive:previousLive:recent:…)` only *selects*: the repository's `latestLiveReading()` however old (so a reading older than 3 h still reads "Last reading 4 h ago"), the live reading before it for the delta, and the last 3 h of stored readings for the chart. An imported reading passed as "live" is ignored (S6). |
| File I/O | `…/Snapshot/WidgetSnapshotStore.swift` | `[.atomic, .completeFileProtectionUntilFirstUserAuthentication]` (HANDOFF §4.5); App Group from Info.plist `AppGroupID`. The widget reads through `snapshotForWidget()` / `readOrNil()`: empty, truncated, corrupt or other-schema files all read as nil (tested). |
| Timeline | `…/Timeline/WidgetTimeline.swift` | Pure: entries and reload date from a snapshot and `now`. |
| Display rules | `…/Formatting/GlucoseDisplayState.swift` | Shared with the Now screen: fresh / stale / no data / warm-up / expired / error / not paired. |
| Layouts | `…/Views/WidgetViews.swift` | Plain SwiftUI (no WidgetKit) so the app's tests can render them to `docs/screenshots/`. |
| Extension | `Widgets/Sources/SensorWidgets.swift` | Provider, `containerBackground`, `widgetURL`. Previews: `Widgets/Sources/WidgetPreviews.swift`. |
| App side | `App/Sources/WidgetBridge/WidgetSnapshotPublisher.swift` | Phase 2 calls `publish(latestLive:previousLive:recent:sensorState:accent:now:)` after every committed store change and every sensor-state change. |

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
| `recent` | Readings in the 3 h before `writtenAt`, ascending; may include imported history (charts only). |
| `accent` | `forest` / `rust` / `navy` / `ink`. |

A missing, unreadable or wrong-version file, or a missing App Group, all read as "no snapshot" and
render *No data* — never a number.

## Staleness and refresh

The ages are **live relative text** (`LiveAge`): the system keeps them counting without a widget
reload. On iOS 18+ they show whole minutes rounded down ("3 min ago", "1 hr, 5 min ago"), matching
the thresholds below; on iOS 17 the only live style counts seconds ("3 min, 12 sec ago").

Each timeline carries future entries, so the widget changes state on time even if the app never
runs again (S5):

| When | Entry |
|---|---|
| now | current state |
| latest − 60 s | only when the reading is dated ahead of the phone's clock (clock moved back): until then **"Check phone clock"**, no number |
| latest + 10 min | **stale**: number in the muted colour (≥ 3:1, not faded), VoiceOver "Stale: 105 …", "STALE · 10 min ago" in the alert colour, chart dimmed to 0.6 without the "latest" dot |
| latest + 20 min | **no data**: the number is gone; "No data · Last reading 20 min ago" |
| warm-up end | stops claiming warm-up; *No data* until the app writes a reading |
| grace-period end | *Sensor expired* |

Timeline policy: `.after(last entry + 1 min)`, or `.after(now + 15 min)` when nothing is scheduled
(so a snapshot written while the app's reload request was throttled is still picked up).

The app asks for a reload (`WidgetCenter.shared.reloadAllTimelines()`) after every write. iOS
budgets widget reloads while the app is in the background, so the widget can lag the app by
several minutes. If that is too much in practice, the fix is a Live Activity (v1.1, HANDOFF §12).

## Deep link

`widgetURL` = `<BUNDLE_ID_PREFIX>://now` (`Widgets/Info.plist` `HostAppURLScheme`; the app registers
the same scheme in `App/Info.plist` `CFBundleURLTypes`). The app selects the Now tab on any
`…://now` URL.

## Tests

- `WidgetSnapshotTests`: JSON round trip for every sensor state, flags survive encoding (S4),
  millisecond dates, wrong schema rejected, store write/read/overwrite, writing options (atomic +
  `completeUntilFirstUserAuthentication` on iOS), live-only current value (`test_S6_…`).
- `WidgetTimelineTests`: fresh / stale / no-data / LOW / HIGH / warm-up / expired / grace-period
  timelines, `test_S5_timelineAlwaysEndsWithoutAStaleNumberOnScreen`,
  `test_S5_futureDatedReadingIsNeverShownAsCurrent`, `test_S1_widgetTimelineNeverSynthesizesAValue`,
  reload policy.
- `WidgetSnapshotTests`: also `test_S5_oldLatestReadingIsKeptOutsideTheChartWindow` and
  `test_S5_corruptTruncatedOrEmptyFileReadsAsNoData`.
- Previews for every family × state, light and dark: `Widgets/Sources/WidgetPreviews.swift`.
- Rendered: `docs/screenshots/widget-medium-*.png`, `widget-small-*.png`.

File protection itself cannot be observed in the simulator or on the macOS host; §11 step 3a checks
it on device (widget keeps updating while the phone stays locked for hours).

## Measured on device

To be filled in by Michael during HANDOFF §11 step 3a (24-hour soak with the medium widget on the
Home Screen).

| Date | iOS | Condition (unlocked / locked / Low Power) | Typical lag app → widget | Worst lag | Stale / no-data states seen correctly? | Notes |
|---|---|---|---|---|---|---|
| | | | | | | |
