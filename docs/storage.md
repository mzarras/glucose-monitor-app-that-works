# Storage (`Packages/GlucoseStore`)

GRDB 7.11.1 (pinned exactly, PROGRESS D8) implementation of `GlucoseReadingRepository`
(`Packages/GlucoseCore/Sources/GlucoseCore/GlucoseReadingRepository.swift`). HANDOFF §4.4, §4.5.

| File | What it holds |
|---|---|
| `StoreSchema.swift` | The migrations and the `CREATE TABLE` / `CREATE INDEX` SQL |
| `ReadingRow.swift` | The only `GlucoseReading` ↔ column mapping |
| `ReadingInsertion.swift` | The insert rules (dedupe, ±150 s import rule), all SQL visible |
| `StoreRole.swift` | Production vs replay role: allowed sources, `latestLiveReading` SQL |
| `GlucoseStore.swift` | The repository: `insert`, `readings(from:to:)`, `latestLiveReading`, `changes` |
| `GlucoseStore+Opening.swift` | Factories, file opening, file protection |
| `GlucoseStore+Maintenance.swift` | Retention purge, Settings summary, CSV export |
| `ChangeNotification.swift` | GRDB transaction observer + fan-out for `changes()` |
| `FileProtection.swift` | Data-protection seam |
| `CSVExport.swift`, `CSVFileWriter.swift` | CSV line format and streaming writer |
| `RetentionPolicy.swift`, `StoreSummary.swift`, `GlucoseStoreError.swift` | Small value types |

## Roles and factories (PROGRESS D20)

A store has one role for its whole life; the two roles never share a database.

| Factory | Role | Stores | `latestLiveReading()` |
|---|---|---|---|
| `GlucoseStore.production(at:)` | production, file (WAL) | `.sensor`, `.imported` | newest `.sensor` |
| `GlucoseStore.productionInMemory()` | production, memory (tests, previews) | `.sensor`, `.imported` | newest `.sensor` |
| `GlucoseStore.replay()` — `#if DEBUG` | replay, memory | `.replay`, `.mock` | newest `.replay`/`.mock` |
| `GlucoseStore.replay(at:)` — `#if DEBUG` | replay, separate file | `.replay`, `.mock` | newest `.replay`/`.mock` |

- `insert` checks every reading's source before writing. If any is not allowed in the role, it
  throws `GlucoseReadingRepositoryError.sourceNotAllowed(source)` and stores nothing from the batch.
- Opening a **production** store deletes any `replay`/`mock` rows (a DEBUG build from before roles
  existed could have written them to the same App Group file) and records a `DiagnosticEvent`
  (`"Removed N replay/mock reading(s) from the production database on open (S6)"`).
- Opening a **replay** store on a file that contains `sensor`/`imported` rows throws
  `GlucoseStoreError.replayStoreFileContainsLiveData(rowCount:)` and changes nothing, so the
  production file can never be opened as a replay store by mistake.
- The replay role, both replay factories and their tests are compiled only in DEBUG.

## Schema (migration `v1-create-reading`)

```sql
CREATE TABLE reading (
    id TEXT NOT NULL PRIMARY KEY,          -- GlucoseReading.id: the S3 dedupe key
    date REAL NOT NULL,                    -- UTC instant, seconds since 2001-01-01T00:00:00Z
    valueKind TEXT NOT NULL CHECK (valueKind IN ('mgdl', 'belowRange', 'aboveRange')),
    mgdl INTEGER CHECK ((valueKind = 'mgdl') = (mgdl IS NOT NULL)),
    trendRate REAL,                        -- mg/dL/min as reported; NULL = not reported
    isBackfill INTEGER NOT NULL CHECK (isBackfill IN (0, 1)),
    sourceKind TEXT NOT NULL CHECK (sourceKind IN ('sensor', 'imported', 'replay', 'mock')),
    importOrigin TEXT
        CHECK ((sourceKind = 'imported') = (importOrigin IS NOT NULL))
        CHECK (importOrigin IS NULL OR importOrigin IN ('nightscout', 'clarityCSV')),
    sensorSerial TEXT NOT NULL             -- '' when unknown
);
CREATE INDEX reading_on_date ON reading(date, id);
CREATE INDEX reading_sensor_on_date ON reading(date, id) WHERE sourceKind = 'sensor';
```

- **Rowid table on purpose.** SQLite does not call the update hook for `WITHOUT ROWID` tables, and
  GRDB's transaction observer (which drives `changes()`) depends on that hook.
- **Timestamps are lossless.** `date` holds exactly the `Double` that Foundation's `Date` stores
  (`timeIntervalSinceReferenceDate`), so a round trip is bit-exact (test
  `test_S3_datesRoundTripBitExact`). GRDB's default `Date` encoding (a millisecond string) is not
  used. Values are UTC instants: no time zone, no local wall-clock time, nothing for DST to break
  (tests `test_springForwardDayKeepsEveryReadingInOrder`, `test_fallBackDayKeepsTheRepeatedHourDistinct`).
  Readable form in SQL: `datetime(date + 978307200, 'unixepoch')`.
- **LOW/HIGH are flags** (S4): `valueKind = 'belowRange' | 'aboveRange'` with `mgdl` NULL. The
  CHECK makes a flag with a number (or a number without one) impossible to store.
- **Source and origin are exact** (S6): `sourceKind` + `importOrigin`, both CHECK-constrained. An
  imported row cannot come back as `.sensor`.
- `trendRate` NaN: SQLite stores NaN as NULL, so the store normalises NaN to nil before storing and
  before comparing; `TrendArrow` treats both as `.notComputable`. (`LiveReadingGate` refuses
  non-finite rates anyway.)
- Decoding never guesses: a row with an unknown `valueKind`/`sourceKind`/`importOrigin` throws
  `GlucoseStoreError.unreadableRow`.
- Migrations are append-only. A database containing migrations this version does not know (written
  by a newer app) is refused: `GlucoseStoreError.databaseFromNewerAppVersion`.

## Insert rules (`ReadingInsertion.swift`)

One write transaction per `insert` call. Readings in the call are applied in ascending date order
(ties by id), so every rule holds inside a batch exactly as across batches.

1. **Same id already stored** → nothing is written; the stored row wins (S3: dedupe by the
   sensor-reported timestamp, which the id encodes). If the content differs (for example a
   backfilled copy with a slightly different derived date), a `DiagnosticEvent` names the id and
   the differing fields: `Kept stored reading <id>; a re-delivered copy differed in: date, isBackfill`.
2. **`.imported`** → skipped when any stored reading of any source lies within ±150 s
   (|Δt| ≤ 150 s, inclusive: exactly 150 s overlaps, 151 s does not). This also drops Nightscout's
   near-duplicates (two uploaders) and the overlap between a Nightscout and a Clarity import.
3. Otherwise the row is inserted with a plain `INSERT` (any constraint violation throws and rolls
   back the whole batch — nothing is ignored silently; `INSERT OR IGNORE` is deliberately not used
   because it also swallows CHECK violations).
4. **`.sensor`** → deletes `.imported` rows within ±150 s, including imported rows stored earlier in
   the same call (they are removed from the returned list too). One diagnostic per call:
   `Removed N imported reading(s) within ±150 s of new sensor readings`.

`insert` returns only the rows newly stored and still present at commit, ascending by date. The
pipeline passes each through `LiveReadingGate` before Trio, alerts or uploads.

The SQL, in order, per reading:

```sql
SELECT … FROM reading WHERE id = ?;                                          -- rule 1
SELECT EXISTS (SELECT 1 FROM reading WHERE date BETWEEN ? AND ?);            -- rule 2 (d−150, d+150)
INSERT INTO reading (…) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);                  -- rule 3
SELECT id FROM reading WHERE sourceKind = 'imported' AND date BETWEEN ? AND ?; -- rule 4
DELETE FROM reading WHERE sourceKind = 'imported' AND date BETWEEN ? AND ?;
```

## Queries

- `readings(from:to:)`: `WHERE date >= ? AND date < ? ORDER BY date, id` (half-open), served by
  `reading_on_date`. Returns stored rows only; gaps stay gaps (S1).
- `latestLiveReading()`: production `WHERE sourceKind = 'sensor' ORDER BY date DESC, id DESC
  LIMIT 1`, served by the partial index `reading_sensor_on_date` with no sort step (test
  `test_latestLiveReadingUsesThePartialIndex` checks the query plan). Replay role:
  `WHERE sourceKind IN ('replay', 'mock')`.
- `changes()`: a new `AsyncStream<Void>` per call (unbounded). A GRDB `TransactionObserver` on the
  `reading` table notes the first changed row of a transaction and yields once to every stream on
  commit. Transactions that changed nothing (all ids already stored, all imports skipped, a purge
  that deleted nothing) and rolled-back transactions do not yield. Streams finish when the store is
  deallocated.

## Threading

Every repository method is nonisolated `async`; GRDB runs writes on its serial writer queue and
reads on its reader pool (WAL `DatabasePool` for files), so no SQL runs on the main actor and the
UI can read during a background write. `production(at:)` and `replay(at:)` are `@concurrent`, so
the migration and file work never run on the caller's actor. The in-memory factories are
synchronous (for previews).

## File location, protection and backup

- The caller passes the database file URL. The app passes a file in its App Group container
  (HANDOFF §4.5); the parent directory is created if needed.
- On every open the store applies `FileProtectionType.completeUntilFirstUserAuthentication` to the
  database, `-wal` and `-shm` files (after migration, when all three exist; a missing one is
  recorded as a diagnostic). BLE wakes the app in the background while the phone is locked, and
  with `.complete` those writes would start failing after the phone locks. The seam
  (`FileProtectionApplying`) lets a host test prove the exact value requested for each file
  (`test_openRequestsProtectionForTheDatabaseAndItsWALFiles`); the real `SystemFileProtection`
  calls `FileManager.setAttributes` under `#if os(iOS)` and does nothing on macOS.
  **The effect itself can only be verified on a device** (HANDOFF §11 step 3a: readings keep
  saving while the phone stays locked for hours).
- Before the first unlock after a reboot the file is unreadable by design (class C). Opening the
  store then throws; the app must retry after first unlock (Phase 2 wiring).
- The database is **not** excluded from backup (test `test_databaseIsNotExcludedFromBackup`);
  it goes into iCloud/device backups. Nightscout is the off-device copy.

### App Group container and 0xDEAD10CC

iOS terminates an app (`0xDEAD10CC`) that is suspended while holding a file lock on a file in a
shared container, and SQLite takes such locks. GRDB's documentation (`DatabaseSharing.md`,
"How to limit the 0xDEAD10CC exception") describes the mitigation: set
`Configuration.observesSuspensionNotifications` and post `Database.suspendNotification` before the
app is suspended and `Database.resumeNotification` from every callback that may use the database
(including BLE background callbacks). `production(at:observesSuspensionNotifications:)` exposes the
flag; posting the notifications is Phase 2 app wiring. Only this app's process opens the database
(the widget reads the WidgetCore snapshot, PROGRESS D10), so the database itself does not need to
be in the App Group container; keeping it in the app's own container would remove this risk
entirely. See OPEN QUESTIONS in the WS2 report.

## Retention

`RetentionPolicy`: `.days90`, `.oneYear` (365 d), `.twoYears` (730 d, **default**), `.forever`.
Fixed-length 86 400 s days on UTC instants (no calendar or DST involved).
`purge(keeping:)` runs `DELETE FROM reading WHERE date < ?` with `cutoff = now − maximumAge`
(the store's injected clock); a reading exactly at the cutoff is kept. It applies to every source,
returns the number of rows deleted and records a diagnostic when it deleted anything. The file does
not shrink (SQLite reuses the freed pages); no `VACUUM` is run. The app decides when to call it.

## Settings summary

`summary()` → `StoreSummary(readingCount:earliest:latest:fileSizeBytes:)`:
`SELECT COUNT(*), MIN(date), MAX(date) FROM reading`, plus the on-disk size of the database,
`-wal` and `-shm` files (nil in memory).

## "Export all data (CSV)"

`exportCSV(to:)` streams every row through a cursor, writing 64 KB chunks to a hidden
`.<name>.partial` file next to the destination and moving it into place only when complete; a
failed export leaves nothing at the destination. Returns the row count. UTF-8, no BOM, LF line
endings, RFC 4180 quoting where a field contains `,` `"` CR or LF. Rows ascending by date, then id.

```
date_utc,glucose_mgdl,trend_mgdl_per_min,is_backfill,source,import_origin,sensor_serial,id
2026-01-14T12:05:00.000Z,LOW,,false,imported,clarityCSV,,imported:clarityCSV:1768392300000
2026-01-15T12:00:00.000Z,112,0.2,false,sensor,,3M1234,3M1234:0
2026-01-15T12:10:00.000Z,HIGH,,true,sensor,,3M1234,3M1234:600
```

| Column | Content |
|---|---|
| `date_utc` | ISO 8601 UTC, millisecond precision (rounded to the nearest ms, formatted from integer ms) |
| `glucose_mgdl` | integer 40–400, or the text `LOW` / `HIGH` (S4: never 40 / 400 for a flag) |
| `trend_mgdl_per_min` | as reported, shortest round-trip decimal; empty when not reported |
| `is_backfill` | `true` / `false` |
| `source` | `sensor` / `imported` / `replay` / `mock` |
| `import_origin` | `nightscout` / `clarityCSV` / empty |
| `sensor_serial` | serial, empty when unknown |
| `id` | the dedupe key |

The golden test `test_exportMatchesGoldenFile` pins the format byte for byte.

## Performance (HANDOFF §4.4)

Test: `PerformanceTests.test_twoYearsOfFiveMinuteDataThenQuery90Days` on a file-backed production
store. 730 days × 288 = 210 240 rows: 720 days as `.imported(.nightscout)` in 7-day batches
(the Nightscout import pages in 7-day windows) plus 10 days of `.sensor` readings in 1-day batches;
values cycle through 40–400 with LOW/HIGH flags. Then a 90-day range query (25 920 rows), the
latest live reading, the summary and a full CSV export.

Host: Apple M4 (10 cores, 16 GB), macOS, Xcode 26.2 toolchain, 2026-09-23. The machine was shared
with six other workstreams building in parallel (load average 20–75 on 10 cores), so these are
pessimistic.

| Operation | debug, lighter load | debug, load 50–75 (3 runs) | release (`-c release`), load 21–35 |
|---|---|---|---|
| Insert 210 240 rows via `insert` | 5.8 s | 8.5–13.9 s | 5.8 s |
| `readings(from:to:)`, 90 days, 25 920 rows | **48 ms** | 74–98 ms | **30 ms** |
| `latestLiveReading()` (warm) | 0.10 ms | 0.15–0.23 ms | 0.10 ms |
| `summary()` | 9 ms | 52–115 ms | 97 ms |
| `exportCSV` (all rows, 19.0 MB) | 1.05 s | 1.35–1.71 s | 1.46 s |
| File size (db + wal + shm) | 38.6 MB | | |

The test asserts the 90-day query takes < 1 s and the warm `latestLiveReading()` < 50 ms (loose
bounds so a loaded CI host still passes; the numbers above are what matter). Device numbers are for
the Phase 3 "90-day dataset performance" pass.

## Tests

`swift test` in `Packages/GlucoseStore` (77 tests in DEBUG; 68 compile in `-c release`, where the
replay role does not exist). Safety tests: `test_S1_*` (range queries return stored rows only; the
replay store refuses sensor/imported), `test_S3_*` (dedupe, same-id conflicts, ordering, ±150 s
rule both directions incl. 150/151 s, cross-origin, within a batch, backfill), `test_S4_*` (flags
round-trip and are enforced by CHECK), `test_S6_*` (source/origin round-trip, imported never
`.sensor`, `latestLiveReading` sensor-only, role refusals, mixed batches rejected whole, purge on
open).
