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

- `insert` checks the whole batch before writing (`ReadingInsertion.validate`) and, if any check
  fails, throws and stores nothing from the batch. Both roles, in this order:
  1. a source not allowed in the role → `GlucoseReadingRepositoryError.sourceNotAllowed(source)` (D20);
  2. a numeric value outside `GlucoseValue.sensorReportableRange` (40...400) →
     `.implausibleValue(value)` (D25);
  3. a trend rate that is NaN or infinite → `.nonFiniteTrendRate` (D33);
  4. a date later than the store's clock + `LiveReadingGate.futureTolerance` (60 s; exactly +60 s is
     accepted, +61 s is not) → `.futureDated(date)` (D33). A future-dated row would otherwise
     become the current value (S5).

  Each can only come from a parse or clock fault; storing it would put it in charts, stats or the
  current value (S1, S5). Nothing is ever rewritten to make it fit: `insert` returns the newly
  stored readings **exactly as passed** (test `test_S2_insertReturnsReadingsExactlyAsPassed`).
- Opening a **production** store deletes any `replay`/`mock` rows (a DEBUG build from before roles
  existed could have written them to the same file) and records a `DiagnosticEvent`
  (`"Removed N replay/mock reading(s) from the production database on open (S6)"`).
- Opening a **replay** store on a file that contains `sensor`/`imported` rows throws
  `GlucoseStoreError.replayStoreFileContainsLiveData(rowCount:)`. The check is read-only and runs
  **before any migration**, so the file comes out unchanged, even an older one that a migration
  would have rewritten (test `test_S6_refusingAProductionFileAsReplayChangesNothingInIt`).
- The replay role, both replay factories and their tests are compiled only in DEBUG.

## Schema

Migrations (append-only; `StoreSchema.swift`):

| Migration | Change |
|---|---|
| `v1-create-reading` | the `reading` table and its two indexes |
| `v2-mgdl-range-check` | PROGRESS D25: `mgdl` must be 40...400. SQLite cannot add a CHECK to an existing table, so v2 rebuilds it the standard way (create `reading_v2`, copy in rowid order, drop, rename, recreate the indexes; https://www.sqlite.org/lang_altertable.html#otheralter). Rows with a number outside 40...400 are not copied; the store records `Migration v2-mgdl-range-check removed N stored reading(s) with a number outside 40...400 (parse faults, S1)`. v2 also changes both indexes from `(date, id)` to `(date)` (see "Ordering"). |

Current schema (after v2):

```sql
CREATE TABLE reading (
    id TEXT NOT NULL PRIMARY KEY,          -- GlucoseReading.id: the S3 dedupe key
    date REAL NOT NULL,                    -- UTC instant, seconds since 2001-01-01T00:00:00Z
    valueKind TEXT NOT NULL CHECK (valueKind IN ('mgdl', 'belowRange', 'aboveRange')),
    mgdl INTEGER
        CHECK ((valueKind = 'mgdl') = (mgdl IS NOT NULL))
        CHECK (mgdl IS NULL OR mgdl BETWEEN 40 AND 400),
    trendRate REAL,                        -- mg/dL/min as reported; NULL = not reported
    isBackfill INTEGER NOT NULL CHECK (isBackfill IN (0, 1)),
    sourceKind TEXT NOT NULL CHECK (sourceKind IN ('sensor', 'imported', 'replay', 'mock')),
    importOrigin TEXT
        CHECK ((sourceKind = 'imported') = (importOrigin IS NOT NULL))
        CHECK (importOrigin IS NULL OR importOrigin IN ('nightscout', 'clarityCSV')),
    sensorSerial TEXT NOT NULL             -- '' when unknown
);
CREATE INDEX reading_on_date ON reading(date);
CREATE INDEX reading_sensor_on_date ON reading(date) WHERE sourceKind = 'sensor';
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
- **Numbers are 40...400** (D25): refused by `insert` with `implausibleValue`, and by a CHECK as a
  backstop (tests `test_S1_storeRefusesNumericValueOutsideSensorRange`,
  `test_S1_schemaRejectsNumericValueOutsideSensorRange`, `test_migratesAV1DatabaseAddingTheRangeCheck`).
- **Source and origin are exact** (S6): `sourceKind` + `importOrigin`, both CHECK-constrained. An
  imported row cannot come back as `.sensor`.
- `trendRate` is stored exactly as reported. A non-finite rate never reaches the table: the whole
  batch is rejected with `.nonFiniteTrendRate` (D33; test `test_S2_nonFiniteTrendRateRejectsWholeBatch`).
  It is never rewritten to nil, which would hide a parse fault from `LiveReadingGate` (and SQLite
  would store NaN as NULL).
- Decoding never guesses: a row with an unknown `valueKind`/`sourceKind`/`importOrigin` throws
  `GlucoseStoreError.unreadableRow`.
- Migrations are append-only. A database containing migrations this version does not know (written
  by a newer app) is refused: `GlucoseStoreError.databaseFromNewerAppVersion`.

## Insert rules (`ReadingInsertion.swift`)

First the whole batch is validated (the four checks above); a refused batch writes nothing. Then
one write transaction per `insert` call. Readings in the call are applied in ascending date order,
equal dates in the order they were passed, so every rule holds inside a batch exactly as across
batches. If the write itself fails partway (an SQL error, or the calling task being cancelled —
GRDB then interrupts the connection) the transaction rolls back: nothing is stored, nothing is
returned, `changes()` does not yield (tests `test_S5_insertFailingMidBatchWithASQLErrorStoresNothing`,
`test_S5_insertCancelledMidBatchStoresNothing`).

1. **Same id already stored** → nothing is written; the stored row wins (S3: dedupe by the
   sensor-reported timestamp, which the id encodes).
   - Differs only in `isBackfill` and/or by ≤ 2 s in `date` (inclusive): a **benign re-delivery**,
     the expected shape of a G7 backfilled copy of a reading already stored live (the date is
     re-derived at each connection from the phone clock and a 1-second sensor clock). Counted, and
     one aggregate diagnostic per `insert` call:
     `Ignored N re-delivered reading(s) already stored (differing only in isBackfill and/or by ≤ 2 s in date)`.
   - Any other difference (value, trend rate, source or origin, serial, or a date more than 2 s
     away): one diagnostic per reading naming the id and fields:
     `Kept stored reading <id>; a re-delivered copy differed in: value, isBackfill`.
   - Tests: `test_S3_benignRedeliveriesAreCountedNotLoggedPerReading`,
     `test_S3_realDifferencesInARedeliveryStillRecordAFullDiagnostic`.
2. **`.imported`** → skipped when any stored reading of any source lies within ±150 s
   (|Δt| ≤ 150 s, inclusive: exactly 150 s overlaps, 151 s does not). This also drops Nightscout's
   near-duplicates (two uploaders) and the overlap between a Nightscout and a Clarity import.
3. Otherwise the row is inserted with a plain `INSERT` (any constraint violation throws and rolls
   back the whole batch — nothing is ignored silently; `INSERT OR IGNORE` is deliberately not used
   because it also swallows CHECK violations).
4. **`.sensor`** → deletes `.imported` rows within ±150 s, including imported rows stored earlier in
   the same call (they are removed from the returned list too). One diagnostic per call:
   `Removed N imported reading(s) within ±150 s of new sensor readings`.

`insert` returns only the readings newly stored and still present at commit, exactly as the caller
passed them, ascending by date (equal dates in the order passed). The pipeline passes each through
`LiveReadingGate` before Trio, alerts or uploads.

The SQL, in order, per reading:

```sql
SELECT … FROM reading WHERE id = ?;                                          -- rule 1
SELECT EXISTS (SELECT 1 FROM reading WHERE date BETWEEN ? AND ?);            -- rule 2 (d−150, d+150)
INSERT INTO reading (…) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);                  -- rule 3
SELECT id FROM reading WHERE sourceKind = 'imported' AND date BETWEEN ? AND ?; -- rule 4
DELETE FROM reading WHERE sourceKind = 'imported' AND date BETWEEN ? AND ?;
```

## Queries

**Ordering.** Everything is ordered by `date`, and readings with the *same* date by storage order
(`rowid`): the one stored later comes later, and `latestLiveReading()` returns the one stored last.
Storage order is delivery order (separate calls in call order; one call in the order passed), never
the text order of ids (`"S:10"` sorts before `"S:9"`). Equal dates happen when, for example, an old
and a new sensor report the same instant. Every index on a rowid table ends with the rowid, so
`ORDER BY date, rowid` is read straight from the `(date)` indexes with no sort step (tests
`test_latestLiveReadingOnEqualDatesIsTheReadingStoredLast`, `test_orderedQueriesNeedNoSortStep`).

- `readings(from:to:)`: `WHERE date >= ? AND date < ? ORDER BY date, rowid` (half-open), served by
  `reading_on_date`. Returns stored rows only; gaps stay gaps (S1).
- `latestLiveReading()`: production `WHERE sourceKind = 'sensor' ORDER BY date DESC, rowid DESC
  LIMIT 1`, served by the partial index `reading_sensor_on_date`, one index entry read. Replay role:
  `WHERE sourceKind IN ('replay', 'mock')`, same ordering.
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

- **Location (PROGRESS D25, deviates from HANDOFF §4.5):** the database lives in the app's own
  container, e.g. `Application Support/GlucoseStore/readings.sqlite`, not in the App Group
  container. Only the widget snapshot (WidgetCore, D10) lives in the App Group; that snapshot is
  what the widget reads while the phone is locked. The caller passes the database file URL; the
  parent directory is created if needed. Give the database a directory of its own (as above): the
  store sets the protection class on that directory too.
- On every open the store applies `FileProtectionType.completeUntilFirstUserAuthentication` first
  to the **parent directory** (so a `-wal`/`-shm` that SQLite deletes on close and recreates later
  inherits the class rather than the app's default), then to the database, `-wal` and `-shm` files
  (after migration, when all three exist; a missing one is recorded as a diagnostic). BLE wakes the app in the background while the phone is locked, and
  with `.complete` those writes would start failing after the phone locks. The seam
  (`FileProtectionApplying`) lets a host test prove the exact value requested for each file
  (`test_openRequestsProtectionForTheDirectoryTheDatabaseAndItsWALFiles`); the real `SystemFileProtection`
  calls `FileManager.setAttributes` under `#if os(iOS)` and does nothing on macOS.
  **The effect itself can only be verified on a device** (HANDOFF §11 step 3a: readings keep
  saving while the phone stays locked for hours).
- Before the first unlock after a reboot the files are unreadable by design (that is what this
  class means), so opening the store then throws; the app must retry once protected data becomes
  available (Phase 2 must-do). The `production(at:)` doc comment says so.
- The database is **not** excluded from backup (test `test_databaseIsNotExcludedFromBackup`);
  it goes into iCloud/device backups. Nightscout is the off-device copy.

### Why not the App Group container (0xDEAD10CC)

iOS terminates an app (`0xDEAD10CC`) that is suspended while holding a file lock on a file in a
shared container, and SQLite takes such locks. Only this app's process opens the database, so there
is no reason to put it in a shared container, and in the app's own container the risk does not
apply. `production(at:observesSuspensionNotifications:)` still exposes GRDB's flag (default
`false`): it is **not needed** for the app-container location. It would only matter if the database
were ever moved to a shared container, in which case the app would also have to post
`Database.suspendNotification` before suspension and `Database.resumeNotification` from every
callback that may use the database, including BLE background callbacks (GRDB `DatabaseSharing.md`,
"How to limit the 0xDEAD10CC exception").

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
endings, RFC 4180 quoting where a field contains `,` `"` CR or LF. Rows ascending by date, equal
dates in storage order.

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

Re-measured after migration v2 and the insert-time range check (debug, load ~15): insert 10.2 s,
90-day query 77 ms, `latestLiveReading()` 0.24 ms, `summary()` 74 ms, export 1.83 s — the same
range as before.

Re-measured after the D33 checks and the `(date)` indexes (debug): insert 9.4 s, 90-day query
53 ms, `latestLiveReading()` 0.10 ms warm, `summary()` 20 ms, export 1.18 s; file size down to
**30.3 MB** (the indexes no longer repeat the id text).

The test asserts the 90-day query takes < 1 s and the warm `latestLiveReading()` < 50 ms (loose
bounds so a loaded CI host still passes; the numbers above are what matter). Device numbers are for
the Phase 3 "90-day dataset performance" pass.

## Tests

`swift test` in `Packages/GlucoseStore` (92 tests in DEBUG; in `-c release` the replay-role tests
are compiled out, as the replay role does not exist). Tests never use the wall clock: every store
gets an injected clock (`testClock`, 2030-01-01, or a test's own). Safety tests:
- `test_S1_*`: range queries return stored rows only; numbers outside 40...400 refused by insert
  and by the schema;
- `test_S2_*`: non-finite trend rate rejects the whole batch; `insert` returns readings exactly as
  passed, ties in the order passed;
- `test_S3_*`: dedupe, same-id conflicts vs benign re-deliveries, ordering, ±150 s rule both
  directions incl. 150/151 s, cross-origin, both origins deleted by one sensor reading, within a
  batch, backfill;
- `test_S4_*`: flags round-trip and are enforced by CHECK;
- `test_S5_*`: future-dated reading rejects the whole batch (+60 s accepted, +61 s not); an insert
  failing mid-batch (SQL error, task cancellation) stores nothing and does not yield;
- `test_S6_*`: source/origin round-trip, imported never `.sensor`, `latestLiveReading` sensor-only,
  role refusals both ways, mixed batches rejected whole, purge on open, refusing a production file
  as replay leaves it untouched.
