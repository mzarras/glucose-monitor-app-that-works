# History import

Onboarding offers to import history before pairing (HANDOFF §4.5), so 90-day patterns work from
day one. Two paths, both in `Packages/NightscoutKit`:

| Path | Type | Default range |
|---|---|---|
| Nightscout (primary) | `NightscoutHistoryImporter` | last 90 days; option "everything" |
| Dexcom Clarity CSV (fallback) | `ClarityHistoryImporter` + `ClarityExportParser` | whatever the file holds (Clarity exports ≤ 90 days per file) |

Both produce readings with `source: .imported(origin)`, id `imported:<origin>:<epoch-ms>`
(`GlucoseReading.importedID`), `isBackfill: false`, `sensorSerial: ""`, and hand them to
`GlucoseReadingRepository.insert`. Imported readings feed charts and stats only (S6): they never
reach Trio, alerts, or uploaders — every uploader refuses them through `LiveReadingGate`.

The store, not the importer, decides what is kept: insert-or-ignore by id, and an imported
reading is skipped when any stored reading (sensor, or another import) lies within ±150 s. That
collapses the near-duplicates Nightscout collects when two uploaders posted the same reading, and
the overlap between a Nightscout and a Clarity import. Importers report
`readingsImported` (newly stored) and `readingsSkippedByStore` from `insert`'s return value.

Line numbers below refer to cgm-remote-monitor 15.0.8 (`92d08342`).

## Nightscout

**Request** — `GET <site>/api/v1/entries.json` with

| Parameter | Value | Source |
|---|---|---|
| `find[type]` | `sgv` | `lib/api/entries/index.js:130-134, 339-349` |
| `find[date][$gte]` / `find[date][$lt]` | epoch ms, window bounds | `date` compared as an integer, `lib/server/entries.js:183-198` |
| `count` | 3000 (default would be 10) | `lib/constants.json:8`, `entries/index.js:462-465` |

Results come newest first (`lib/server/entries.js:29-31`). An explicit date bound also disables
Nightscout's implicit "last 4 days" filter (`lib/server/query.js:82-87`).

**Authentication** — the access token goes in the `api-secret` header
(`lib/authorization/index.js:76-96`); Nightscout accepts an access token there when it is not the
API_SECRET hash (`:194-200`; same in 14.2.6). The `?token=` alternative (`:43-61`) would put the
token in URLs that proxies and load balancers log. Reading may work without a token if the site
allows anonymous read; the importer sends the token whenever one is stored.

**Windows** — the plan is fixed when it starts: `planEnd` = now, `planStart` = now − 90 × 24 h
(or none for "everything"). The importer walks backwards in 7-day windows `[upper − 7 d, upper)`,
newest first. Inside a window, a full page (3000 entries) means there may be more: the next page
ends 1 ms after the oldest entry of the full page, so entries sharing that millisecond are fetched
again rather than lost (duplicates are dropped by `_id`, then by reading id). If more than a page
of entries share one millisecond, the import stops with `pageTooDense` instead of guessing.

**"Everything"** — after an empty window, one probe (`count=1`, `$lt` only) returns the newest
entry older than the window. If there is none, the import is finished; otherwise the walk resumes
just above it, so a months-long gap costs one request, not one per week. The walk never goes
below 1970.

**Mapping** (`NightscoutEntryMapper`, `NightscoutGlucoseEncoding`):

| Entry | Result | Source |
|---|---|---|
| `type` ≠ `sgv` (`mbg` fingersticks, `cal` calibrations, …) | ignored, counted `notSGV` | brief; the server filter makes this rare |
| no numeric `date` > 0 | skipped, `missingDate` | |
| `date` later than now + 60 s (`LiveReadingGate.futureTolerance`) | skipped, `futureDated` | PROGRESS D33: stores reject a batch holding one, so skipping keeps one bad entry from stalling the import |
| `sgv` missing or not finite | skipped, `missingValue` | |
| `sgv` < 39 | skipped, `errorCode` — Dexcom error codes, not glucose | `lib/plugins/errorcodes.js:13-22`, `lib/plugins/bgnow.js:95-101` |
| 39 ≤ `sgv` < 40 | `.belowRange` (LOW) | `lib/client/index.js:544-545`, `lib/sandbox.js:249-250` |
| 40 ≤ `sgv` ≤ 400 | `.mgdl(round(sgv))` | `lib/client/index.js:548-549` |
| `sgv` > 400 | `.aboveRange` (HIGH) | `lib/client/index.js:546-547`, `lib/sandbox.js:251-252` |

The classification is exactly Nightscout's own display rule, so a value shows the same here as on
the Nightscout site.

**LOW/HIGH that were already lost.** History uploaded by Trio's native G7 path holds a sensor LOW
as sgv 40 and a HIGH as 400 (Trio sends 40/400 and drops the flag; PROGRESS D21). Those entries
are indistinguishable from real 40 and 400 readings, so they import as the numbers 40 and 400; the
flags cannot be recovered. Only entries uploaded as 39/401 (e.g. by this app)
import as LOW/HIGH. `trendRate` is always `nil`: Nightscout has no rate field (`direction` and
`trend` are arrow buckets, `delta` is a difference between readings). The timestamp is the entry's
`date`, unchanged (S3).

## Dexcom Clarity CSV

**Format** (verified against public real exports, e.g. GlucoseDAO/sugar-sugar `data/example.csv`,
dhruv-aron/Glucose360 `datasets/Clarity_Export_*.csv`): optional UTF-8 BOM, CRLF lines, header

    Index, Timestamp (YYYY-MM-DDThh:mm:ss), Event Type, Event Subtype, Patient Info, Device Info,
    Source Device ID, Glucose Value (mg/dL), Insulin Value (u), Carb Value (grams),
    Duration (hh:mm:ss), Glucose Rate of Change (mg/dL/min), Transmitter Time (Long Integer),
    Transmitter ID

then metadata rows with an empty timestamp (`FirstName`, `LastName`, `DateOfBirth`, `Device`, one
`Alert` row per setting) and event rows (`EGV`, `Calibration`, `Insulin`, `Carbs`, `Exercise`,
`Health`, …). Columns are found by header name. Only `EGV` rows become readings; everything else
is counted as ignored. Older exports use `Timestamp (YYYY-MM-DD hh:mm:ss)` (space instead of `T`),
which is accepted. mmol/L exports are refused (v1 stores mg/dL; a converted value is not what the
sensor reported).

**Values**: `Low` → `.belowRange`, `High` → `.aboveRange` (S4); a whole number 40–400 →
`.mgdl`; anything else (e.g. 39, 401, 0, text) is rejected and counted — never clamped.
`trendRate` is Clarity's "Glucose Rate of Change" when the row has one (usually empty); a
non-numeric or non-finite rate becomes `nil`, never NaN/∞. A row dated later than the import time
+ 60 s (wrong time zone chosen, device clock fault) is rejected and counted
(`rejectedFutureDated`): stores reject a whole batch holding one (PROGRESS D33), so skipping it
keeps one bad row from stalling the import.

**Time zone**: timestamps are local wall-clock time without an offset. The app asks which zone the
data was recorded in (default: the current one) and passes it to the parser.

**DST rules** (`LocalTimeResolver`, `FallBackHourResolver`): a local time is converted by finding
every instant at which the zone's clocks showed it (candidate offsets are the zone's offsets a day
either side).

- *Spring forward* (e.g. 02:30 on the US spring-forward day): no instant exists. The row is
  rejected and counted (`rejectedNonexistentLocalTime`).
- *Fall back* (e.g. 01:30 on the US fall-back day happens twice, earlier E and later L):
  1. **Transmitter time decides when available.** "Transmitter Time (Long Integer)" counts seconds
     on the transmitter's own clock, which does not jump at DST. Take the nearest row in file
     order whose instant is already known and has a transmitter time from the same transmitter
     (same "Transmitter ID"). The row must be at
     `anchor instant + (row transmitter time − anchor transmitter time)` ± 60 s: the candidate
     (E or L) within that tolerance is used; if neither is, the row is rejected
     (`rejectedAmbiguousLocalTime`). File order plays no part, so an export that lists the two
     passes interleaved is still placed correctly.
  2. **A row with a transmitter time but no comparable known row** (e.g. a new sensor whose only
     rows sit inside the repeated hour after a data gap) is rejected: its clock cannot be tied to
     an instant, and file order could place it an hour off.
  3. **Only rows with no transmitter time at all** use chronological file order, with P = the
     nearest earlier known instant: no earlier row → rejected; E and L both not before P → E if
     E is at most 10 min after P (continuous 5-minute data; E equal to P is the same reading
     listed twice — a duplicate, not a new reading an hour away, S1), otherwise rejected (across
     a gap either pass fits); only L not before P → L (second pass); neither → rejected (out of
     order).

  No instant is assumed: a placed row matches the transmitter clock, or is the only candidate
  consistent with chronological order, or continues the sequence within 10 min. Everything else
  is rejected and counted (`rejectedAmbiguousLocalTime`).
  So two readings at the same wall-clock time, one per pass, get two instants and two ids.

## Resume and idempotency

- **Nightscout**: after each window's readings are stored, a `NightscoutImportCheckpoint` is saved
  through `NightscoutImportCheckpointStore` (the app uses `UserDefaultsNightscoutImportCheckpointStore`).
  It records the site, scope, `planEnd`, `planStart`, `completedDownTo` (everything in
  `[completedDownTo, planEnd)` is done), counts, and `isFinished`. A new run with the same site and
  scope continues below `completedDownTo` with the original `planEnd`; a different site or scope
  starts a new plan. A crash between the insert and the checkpoint save only repeats that window.
  Running a finished plan does nothing (no requests); `reset()` starts over.
- **Clarity**: the whole file is parsed first, then stored in batches; re-importing the same or an
  overlapping file stores nothing new.
- **Both**: ids are derived from the timestamp, and the repository inserts-or-ignores, so importing
  the same history twice changes nothing (tested: `test_S3_nightscoutImportIsIdempotent`,
  `test_S3_clarityImportIsIdempotent`).

## Progress

`NightscoutHistoryImporter.progressStream(scope:)` yields `NightscoutImportProgress` (readings
imported, skipped by the store, skipped entries by reason, and the covered range
`[coveredFrom, coveredTo)`) after the start and after every window. The Clarity importer calls
back with `ClarityImportProgress` after each batch. Errors (network, 401, storage) end the import
with a thrown error for the UI to show; the checkpoint keeps what finished.

## Validating on device (HANDOFF §11 step 1a)

Spot-check a few days against the Nightscout site, and 90-day Trends against Clarity for the same
period. A redacted real Clarity export would confirm the parser against the current export
format (the test fixture is synthetic).
