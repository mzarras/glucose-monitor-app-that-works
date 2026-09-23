# Statistics (GlucoseStats)

What every number on the Trends screen and in "Today so far" means, how it is computed, and which
test proves it. Source: `Packages/GlucoseStats/Sources/GlucoseStats/`. Spec: HANDOFF §6, §7.3.

GlucoseStats is pure functions over `[GlucoseReading]`: no UI, no storage, no clock, no I/O. It
never creates, changes or smooths a reading (S1) and never turns LOW/HIGH into a number (S4).

## API

```swift
let options = StatisticsOptions(calendar: .current)   // time zone + calendar; overnight window optional

// One period, every metric:
let stats: PeriodStatistics = GlucoseStatistics.compute(readings: readings, interval: interval, options: options)

// Trends: N calendar days ending now, vs the N days before:
let comparison: PeriodComparison = GlucoseStatistics.compare(readings: readings, period: .fourteenDays, now: now, options: options)

// Now screen, "Today so far":
let today: PeriodStatistics = GlucoseStatistics.todaySoFar(readings: readings, now: now, options: options)

// AGP chart geometry (display only, never a metric):
let lines: [AGPDisplayBucket] = AGPDisplaySmoothing.smoothedForDisplay(stats.agp)
```

`readings` is normally `GlucoseReadingRepository.readings(from:to:)` covering the whole span plus
**24 h on each side** (for `compare`: `[previous.start − 24 h, now)`); the margin is context for
hypo events that cross a period boundary (see below). With less margin, such a low may be missed. Each metric is also a standalone type built from `PeriodReadings`
(`RangeDistribution`, `MeanAndVariability`, `DataSufficiency`, `AGPProfile`, `HypoEvents`,
`OvernightAndDayTimeInRange`, `InRangeStreak.longest`), which is how the tests exercise them.

### Units

| Kind | Unit | Example field |
|---|---|---|
| Any share or proportion | **percent, 0…100, unrounded** (never a 0…1 fraction) | `ranges.inRange.percent` |
| CV, GMI | percent | `meanAndVariability.coefficientOfVariationPercent`, `gmi.percent` |
| Glucose | mg/dL (`Double` for mean/SD) | `meanAndVariability.meanMgdl` |
| Durations | seconds (`TimeInterval`) | `hypoEvents.level1.meanDuration`, `longestInRangeStreak.duration` |
| Comparison deltas | percentage points (`…DeltaPoints`), mg/dL (`…DeltaMgdl`), seconds (`…DeltaSeconds`), counts (`…CountDelta`) | `comparison.inRangeDeltaPoints` |

A value that cannot be computed is `nil`, never 0: no readings → no TIR; one reading → no SD.
The UI rounds for display; bins may then not add to exactly 100.

## Which readings count (`PeriodReadings`)

1. **Interval.** `start <= date < end` (half-open, same as the repository). Everything else is ignored.
2. **One reading per instant.** Readings with an identical `date` count once. Kept: `.sensor` over
   `.imported` over the DEBUG-only replay/mock sources; then live over backfill; then the smallest
   `id`. Deterministic regardless of input order. Readings at *different* instants are never merged
   here; the store already drops imported readings within ±150 s of another reading
   (`GlucoseReadingRepository.insert`). `duplicateCount` reports what was dropped.
3. **Order.** Ascending by date. Input that is not strictly ascending is sorted.
4. **Context.** Readings up to 24 h before and after the interval are kept, under the same rules, as
   `lookBackReadings` / `lookAheadReadings`. Only hypo-event detection reads them; every other metric
   reads the in-interval `readings` only. `duplicateCount` and `containsImportedReadings` describe the
   interval only.
5. **All sources count.** Imported history is used for stats (S6 allows charts and stats);
   `containsImportedReadings` is true when any *counted* reading is imported and drives the Trends
   footnote (HANDOFF §4.5 step 4). An imported copy that lost to a sensor reading does not set it.
6. **Values are used as reported.** LOW/HIGH stay flags. Numbers outside the sensor's 40–400 (only
   possible in imported history) are binned by their band and used in the mean.

Each counted reading carries its local wall-clock time of day (`secondOfDay`), its band, and
whether a gap precedes it (`startsAfterGap`, judged against the previous reading of the whole
window, look-back included).

### Local time of day and DST

`secondOfDay = (Unix time + the zone's UTC offset at that instant) mod 86 400`, using the injected
calendar's time zone. On a fall-back day both 01:30s map to 01:30; on a spring-forward day nothing
maps to 02:00–02:59. AGP buckets, the overnight window and the hypo histogram use wall-clock time.
Anything that counts *expected* readings uses real elapsed seconds (a 23-hour day expects 276
readings, a 25-hour day 300). Tests: `PeriodReadingsTests.testSecondOfDay*`,
`AGPTests.testFallBack…`, `…SpringForward…`, `DataSufficiencyTests.test…Day…`.

### Continuity: gaps and durations (`Continuity`)

- A reading **covers** from its timestamp until the earliest of: +5 minutes, the next counted
  reading, a limit. For the in-range streak the limit is the period end, so a streak never exceeds
  the period. Hypo events are detected over the period ± 24 h, so their limit is the end of that
  window: an event can continue past the period end, and the last reading before "now" covers its
  full 5 minutes (three low readings = 15 min, even if the third was 2 minutes ago).
- Consecutive readings **more than 15 minutes apart** are a gap. A gap ends every run and every
  hypo event. 15 minutes exactly is bridged (as the chart draws a line across it, §7.5).
- A run's **duration** = coverage end of its last reading − timestamp of its first. With regular
  5-minute readings, 3 readings = 15 minutes.
- Only durations bridge short gaps; no value is ever created for the unobserved minutes (S1).

## Metrics

### Time in ranges (`RangeDistribution`)

Share of counted readings in each International Consensus bin (Battelino et al., *Diabetes Care*
2019;42:1593, Table 2 "Standardized CGM Metrics for Clinical Care", items 6–10), using
`GlucoseBand`/`GlucoseThresholds` from GlucoseCore:

| Field | Range (mg/dL) | Notes |
|---|---|---|
| `veryLow` | < 54 | includes every LOW flag |
| `low` | 54–69 | |
| `inRange` | 70–180 | TIR, the Trends hero |
| `high` | 181–250 | |
| `veryHigh` | > 250 | includes every HIGH flag |
| `tightRange` | 70–140 | TITR; numeric only, a subset of `inRange` |
| `below70`, `above180` | < 70, > 180 | sums of the two bins each |

`percent = count × 100 / readingCount`; the denominator includes LOW/HIGH. "% of readings", as
HANDOFF §6 specifies (each 5-minute reading stands for 5 minutes). Tests: `RangeDistributionTests`
(every boundary 53/54, 69/70, 140/141, 180/181, 250/251), `test_S4_lowCountsBelow54…`.

### Mean, SD, CV (`MeanAndVariability`)

- Mean = Σx / n over **numeric** readings only (LOW/HIGH excluded, S4).
- **SD is the sample SD, √(Σ(x − mean)² / (n − 1))**, two-pass. Why: a period's readings sample
  a continuous glucose curve; it matches what a reviewer would cross-check with (R `sd()` as used by
  iglu/cgmanalysis, Excel `STDEV.S`); it is undefined for one reading, so a single value never
  produces "CV 0 %". Over 14 days (~4 000 readings) sample and population SD differ by ~0.01 %.
  Test `testStandardDeviationIsSampleNotPopulation`: [100, 200] → 70.71, not 50.
- CV = SD / mean × 100 (%). `nil` when SD is `nil` or mean ≤ 0. Target **≤ 36 %**
  (`coefficientOfVariationTargetPercent`, `isCoefficientOfVariationWithinTarget`). HANDOFF says
  "≤ 36%"; the consensus table reads "<36%"; they differ only at exactly 36.0.

### GMI (`GlucoseManagementIndicator`)

GMI (%) = 3.31 + 0.02392 × mean (mg/dL) (Bergenstal et al., *Diabetes Care* 2018;41:2275).
Mean 150 → 6.898 %. `isMeaningful` = the period touches ≥ 14 local calendar dates
(`CalendarDays.count`); below that `percent` is **nil**, not merely flagged, so a 3-day GMI cannot
be displayed by mistake ("needs 14 days", §7.3). The Trends "14 D" period (14 dates ending now)
qualifies even though fewer than 14 × 24 h have elapsed. All-LOW input → no mean → no GMI.

For the UI: GMI is not suppressed for low data coverage (§7.3 shows it from 14 D on). It sits in
`PeriodStatistics` next to `dataSufficiency`; show the < 70 % warning
(`dataSufficiency.isBelowWarningThreshold`) beside the GMI row, since GMI from sparse data is weak.

`CalendarDays.count` counts **dates** (the day's ordinal in the calendar), not 24-hour steps from the
day's first instant: where DST starts at midnight (America/Santiago, 2026-09-06) a date begins at
01:00 and lasts 23 h, and stepping from 01:00 would miss it (`testDayThatStartsAt0100IsStillOneDay`).

### Data sufficiency (`DataSufficiency`)

- expected = ⌊period length in real seconds / 300⌋; present = counted readings.
- percent = min(present, expected) × 100 / expected, capped at 100; `nil` when expected is 0.
- `isBelowWarningThreshold` = percent < 70 (`warningThresholdPercent`), and also true when percent
  is `nil`. Exactly 70 % is not a warning. Threshold: "Percentage of time CGM is active (recommend
  70% of data from 14 days)" (Battelino 2019, Table 2 item 2). Shown for every period (§7.3).

### AGP percentiles (`AGPProfile`)

96 buckets of 15 minutes of local wall-clock time; each bucket pools every day's readings in that
slot and reports p5, p25, p50, p75, p95 and `readingCount`.

**Percentile method: nearest rank.** With the bucket's n readings in ascending order, the p-th
percentile is the r-th smallest, r = ⌈p × n / 100⌉ (integer arithmetic `(p·n + 99) / 100`).
Ordering puts every LOW below every number and every HIGH above. Consequences, all tested:

- every percentile is a value that was actually read (no interpolation, S1:
  `test_S1_everyAGPPercentileIsAnObservedReading`);
- a percentile can be `.belowRange`/`.aboveRange`, never 40/400 (S4: `test_S4_agpPercentilesKeepTheFlags`);
- with an even n the median is the lower middle value (n = 20 → p50 is the 10th value).

An empty bucket has `nil` percentiles. §7.3: the UI replaces the AGP with real traces for 1 D/3 D.

**Display smoothing (`AGPDisplaySmoothing.smoothedForDisplay`)** is a separate function that
returns chart geometry (`AGPDisplayValue`), not readings: each line is smoothed with 1-2-1 weights
over the bucket and its neighbours (the day wraps). Empty buckets stay empty and LOW/HIGH
percentiles stay flags. A neighbour bucket is used only if all five of its percentiles are numbers;
otherwise it is left out **for all five lines** and the weights renormalised. Because every line of
a bucket then uses the same neighbours and weights, the smoothed lines stay ordered and bands cannot
cross (reviewer probe: `testNeighbourWithAnyFlagIsDroppedForAllLinesSoLinesCannotCross`; property
test on 90 days: `testSmoothedLinesNeverCrossOnNinetyDaysOfData`). It never modifies the profile and
no statistic contains its output (`test_S1_displaySmoothingLeavesTheProfileUntouched`,
`test_S1_statisticsNeverContainDisplaySmoothedValues`, `test_S1_displaySmoothingNeverFillsAnEmptyBucket`,
`test_S4_displaySmoothingNeverTurnsAFlagIntoANumber`).

### Hypo events (`HypoEvents`, `HypoEventSummary`)

Battelino T et al., "Continuous glucose monitoring and metrics for clinical trials: an international
consensus statement", *Lancet Diabetes Endocrinol* 2023;11:42–57, **Table 4 (p. 50)** — Michael's
decision, refining HANDOFF §6 (which ended both levels at ≥ 70):

| | Starts | Ends |
|---|---|---|
| Level 1 | a run of readings < 70 lasting ≥ 15 min | a run ≥ 70 lasting ≥ 15 min |
| Level 2 | a run of readings < 54 lasting ≥ 15 min | a run ≥ 54 lasting ≥ 15 min |

`HypoLevel.entryThresholdMgdl` / `exitThresholdMgdl` hold these per level. Durations use the
Continuity rules. LOW counts as below 54 (and 70); HIGH as at or above both.

- An event starts at the first reading of its qualifying run. A short excursion to or above the exit
  threshold (< 15 min) does not end it.
- `end` = coverage end of the event's last reading below the level's exit threshold (70 or 54);
  `duration` = end − start.
- `endedBy`: `.recovery` (15 min at or above the exit threshold), `.gap` (> 15 min without readings:
  the event is not extended across it and a low after the gap is a new event), or `.noMoreReadings`
  (readings ran out; for "today so far" the low is ongoing).
- One long level 1 low can hold several level 2 events. Reviewer probe, 5-minute readings
  50 ×3 | 60 ×20 | 50 ×3: two level 2 events of 15 min each (the first recovers at ≥ 54 after
  15 min of 60s), one level 1 event of 130 min (`testLongLevel1LowHoldsTwoLevel2Events`).
- Reported per level: `events`, `count`, `meanDuration` (s), `startHourHistogram` (24 local hours).
  `busiestWindow(hourCount:)` gives e.g. "4 of 6 between 2–5 AM": the window with the most event
  starts, considering only windows that start at an hour with an event; ties → earliest.
- Consequence of bridging: two readings < 70 ten minutes apart with one missed reading between them
  qualify (10 + 5 = 15 min). Two 10-minute lows split by a > 15-minute gap do not.

**Period boundaries.** Events are detected over the period plus 24 h of context on each side, and
each event belongs to the period that contains its **start**. A low from 23:50 to 00:10 is therefore
one 20-minute event counted in the day it began and not in the next, instead of two 10-minute
fragments that would both be too short (`testLowCrossingMidnightIsCountedOnceInThePeriodWhereItStarts`).
A low already under way at the period start is not counted again (`testOngoingLowAtPeriodStartIsNotANewEvent`);
a low that starts in the look-ahead is left to the next period (`testEventStartingAfterThePeriodIsNotCounted`).
An event's `end` may lie after the period end. An event older than the 24 h look-back that is still
running at the period start would be seen from the look-back's first reading, which also lies before
the period, so it is still not counted.

Tests: `HypoEventTests` (qualify/not, merge, split, gap exactly 15 min and 15 min + 1 s, level 2 exit
at 54, the probe above, open at period end, sub-5-minute spacing, histogram, wrap past midnight,
fall-back hour, the boundary cases), `test_S1_hypoEventsAreNotJoinedAcrossGaps`,
`test_S4_lowFlagIsALevel2Low`.

**"Today so far → lows"** is `hypoEvents.level1.count`: lows that started today. Every level 2 event
starts or falls inside a level 1 event, so level 1 counts every distinct low episode (a level 2
event today can sit inside a level 1 low that began, and is counted, yesterday).

### Overnight vs day TIR (`OvernightAndDayTimeInRange`)

TIR (70–180) among readings whose local time of day is inside `StatisticsOptions.overnightWindow`
(default 00:00–06:00, `[start, end)`, may wrap past midnight, e.g. 22:00–06:00) vs all other
readings ("day"). `DailyWindow` rejects out-of-range bounds and empty windows.

### Longest in-range streak (`InRangeStreak.longest`)

Longest run of consecutive 70–180 readings inside the period with no gap > 15 min, measured with
the Continuity rules and cut at the period end; ties → earliest. LOW/HIGH break the run. `nil`
without in-range readings.

### Periods and comparison (`CalendarDayPeriod`, `PeriodComparison`)

- Trends choices 1/3/7/14/30/90 D (default 14). Current = `[start of the day N − 1 days before
  today, now)`; preceding = the **N full calendar days immediately before** it. So 1 D = today so
  far vs all of yesterday; 14 D on Sep 23 = Sep 10 – Sep 23 vs Aug 27 – Sep 9.
- Both periods span N calendar days, but the current one ends `now`, so it is shorter in elapsed
  time (at 06:00, "1 D" holds 6 hours against yesterday's 24). That is not a like-for-like
  comparison for everything:
  - **Counts and the longest streak grow with elapsed time.** `level1EventCountDelta`,
    `level2EventCountDelta` and `longestInRangeStreakDeltaSeconds` are `nil` unless both periods
    have the same elapsed length (`periodsHaveEqualLength`). In Trends that is normally false, so
    no spurious "fewer lows" or "shorter streak" appears (`testIdenticalDaysReadAtSixAMShowNoSpuriousChange`:
    two identical days read at 06:00 → these deltas are `nil`; compared as whole days → 0).
    Event-count deltas are also `nil` when either period has no readings.
  - **Percentages, means, SD/CV, GMI and mean event duration** always get a delta, but for a partial
    current period they reflect its time-of-day mix: early in the day "1 D" is mostly overnight
    readings compared with a whole day. The 14–90 D periods are affected by at most one partial day.
  - Data sufficiency is computed against each period's own elapsed time.
- Delta = current − previous, `nil` when either side is `nil`. `previousHasSufficientData` tells the
  UI when the comparison rests on thin data. Day arithmetic uses the calendar (a DST day is 23 or
  25 h; where DST starts at midnight, as in America/Santiago, a day can start at 01:00 —
  `testSantiagoDayThatStartsAt0100`).

### After-exercise TIR (v1.1 stub)

`AfterExerciseTimeInRange` has one case, `.unavailable`; `isImplemented` is `false`; every
`PeriodStatistics` carries `.unavailable`. Nothing is computed (needs HealthKit workouts, §12).

## Safety

| Rule | Where | Tests |
|---|---|---|
| S1 | Metrics read only `CountedReading`s built from real readings; AGP percentiles are observed values (nearest rank); display smoothing is a separate type not stored in any statistic; gaps are never filled | `test_S1_displaySmoothingLeavesTheProfileUntouched`, `…StatisticsNeverContainDisplaySmoothedValues`, `…EveryAGPPercentileIsAnObservedReading`, `…NoMetricFabricatesValuesAcrossGaps`, `…DisplaySmoothingNeverFillsAnEmptyBucket`, `…HypoEventsAreNotJoinedAcrossGaps` |
| S4 | LOW/HIGH excluded from mean/SD/CV/GMI, counted in < 54 / > 250, ordered as extremes in percentiles, kept as flags by smoothing | `test_S4_lowAndHighAreExcludedFromMeanSDAndGMI`, `…LowCountsBelow54AndHighCountsAbove250`, `…AllLowGivesNilMeanAndHundredPercentBelow54`, `…AllHighGivesNilMeanAndHundredPercentAbove250`, `…LowIsNeverTreatedAs40AndHighNeverAs400`, `…AgpPercentilesKeepTheFlags`, `…DisplaySmoothingNeverTurnsAFlagIntoANumber`, `…LowFlagIsALevel2Low` |

## Performance

Requirement (§6): all statistics for 90 days in < 100 ms on device-class hardware. Proxy asserted
in `PerformanceTests`: < 50 ms on the host for 90 days (25 920 readings, New York time zone), and
< 100 ms for the 90 D comparison (two 90-day periods from 51 840 readings).

**What is asserted: thread CPU time** (`clock_gettime(CLOCK_THREAD_CPUTIME_ID)`) of the timed call,
best of 7 runs; wall-clock time is printed alongside. This project runs many builds and test suites
in parallel on one machine, and wall-clock time also counts the time the thread waits for a core:
one early run measured 77–95 ms wall for about 21 ms of work, which made the gate flaky. CPU time
counts only the work. It is not completely immune to load — on Apple Silicon a busy machine can run
the test thread on an efficiency core — so the numbers still vary somewhat (see below).

Measured on the host (Apple M4, Swift 6.2.3), thread CPU time, best / median of 7:

| Build | 90-day `compute` | 90 D `compare` | Load average |
|---|---|---|---|
| Release (`swift test -c release`) | 5.4 / 5.4 ms | 10.8 / 11.3 ms | ~15 |
| Debug + coverage (`scripts/check.sh` gate run) | 21.0 / 21.6 ms | 46.1 / 48.4 ms | ~15 |
| Debug (`swift test`), heaviest load seen | 31.1 / 36.2 ms | 44.9 / 49.8 ms | ~15 |

The app ships the Release build, so on a phone expect roughly 5–15 ms.

Two implementation choices exist only because the gate times the *unoptimised* build, where
generic standard-library code is not specialised. Both remain necessary: without them the 90-day
compute took ~46 ms at `-Onone`, at the edge of the 50 ms budget before any coverage overhead.

- Metrics iterate with `PeriodReadings.forEachReading` / `forEachCountedReading` (a plain index loop)
  instead of `for … in`, about 4× cheaper per element at `-Onone`.
- AGP buckets are sorted with `OrderedValues.sortedAscending`, a counting sort (tally each mg/dL,
  write the values back in order) that returns exactly `sorted()` (`testTallySortEqualsStandardSort`,
  2 000 random arrays). Spreads over 4 096 mg/dL, only possible in corrupt imported data, fall back
  to `sorted()`. The generic `sorted()` alone took ~20 ms for the 96 buckets at `-Onone`.

## Open points

- The "equal-length" previous period is equal in calendar days, not seconds (see Periods above);
  count and streak deltas are therefore withheld unless the periods are equally long.
- The Table 4 citation (Battelino 2023, p. 50) is as given in the owner's decision; I have not read
  the page myself.
- Table numbers for Battelino 2019 are from the ADA-endorsed author manuscript
  (eprints.whiterose.ac.uk/149168).
