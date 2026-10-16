# Safety review — Phase 3 full audit

| | |
|---|---|
| Scope | The whole repository against HANDOFF §2 (S1–S8), §5, §9 Phase 3, §10, §11; PROGRESS D1–D43, "Phase 2 must-dos", Phase 3 carry-overs, §11 additions |
| Code audited | branch `p3-audit` @ `110116f` (tree = `main` `4cce67f` + PROGRESS.md) |
| Reviewer | independent `safety-reviewer`, Phase 3 (no workstream approves its own work) |
| Date | 2026-10-06 |
| Verdict | **PASS — no blockers.** 0 BLOCKER, 0 MAJOR, 18 MINOR (§7). All §10 gates 1–4 pass on this commit. |

How this was checked: every path below was read in code, not in docs or test names. Every test cited
was run in this audit: the full `scripts/check.sh` on a dedicated simulator (`Sensor-P3-Audit`,
iPhone 17, iOS 26.2), plus the S2/S6 suites of AlertEngine, GlucoseCore, TrioBridge and
NightscoutKit again in **release** configuration (`swift test -c release -Xswiftc -enable-testing`),
plus `nm`/`strings` on the Release app binary. "Not proven" means no test exercises that hop; it
does not mean the code is wrong. File references are `path:line` at `110116f`.

---

## 0. Gate results (this audit's run)

`KEEP_BUILD_DIRS=1 SIM_DEST="platform=iOS Simulator,id=<Sensor-P3-Audit>" scripts/check.sh`,
logs in `.build-logs/20261006-112725/`.

| Gate | Result |
|---|---|
| 1 Build | plist/entitlement lint PASS; Debug and Release `generic/platform=iOS` from fresh derived data, **zero warnings**, Swift 6 strict concurrency |
| 2 Unit tests | GlucoseCore 28, G7Kit 164, GlucoseStore 92, GlucoseStats 150, AlertEngine 288, TrioBridge 63, NightscoutKit 111, ReplayKit 40, WidgetCore 71, app (hosted, signed ad hoc) 186 — **1193 passed, 0 failed, 0 skipped**. Coverage: G7Kit Messages 99.04 % (min 90), GlucoseStats 99.88 % (95), AlertEngine 99.06 % (90), TrioBridge 97.75 % (90); report-only: GlucoseCore 95.07, GlucoseStore 98.18, NightscoutKit 91.82, ReplayKit 97.28, WidgetCore 35.10 |
| 3 Safety | S1 48, S2 76, S3 67, S4 49, S5 130, S6 38, S7 28, S8 2 passing; none failing or skipped; no XCTSkip/XCTExpectFailure in safety files; S6 compile-out (ReplayKit, `validateAllowingReplay`, GlucoseStore replay role) PASS with Debug positive controls; `validateAllowingReplay` caller lint, D21 sentinel lint, `.replay/.mock` construction lint PASS |
| 4 Replay | PASS — `SensorTests/ReplayScenarioTests` 6 tests (steady, slow fall to urgent low, compression low, signal gap with backfill, sensor expiry: alerts asserted to fire when and only when expected; plus `test_S6_replayNeverReachesTrioOrUploads`) and `SensorUITests` 12 tests (app launched on every scenario, all with DEBUG `-silenceAlertAudio`). `check.sh` exit 0, "All requested gates passed." |
| Extra: release configuration | AlertEngine 7, GlucoseCore 14, TrioBridge 22, NightscoutKit 15 S2/S6 tests, 0 failures — including `test_S6_releaseBuildRefusesReplayReadings`, which only compiles without `DEBUG` and which `check.sh` never runs (finding m3) |
| Extra: Release binary | see §2.2 |

429 distinct `test_S<n>_` names exist in the repo; 427 ran in gates 2–3. The other two are
`test_S6_releaseBuildRefusesReplayReadings` (release-only, run separately above, passed) and
`test_S6_replayNeverReachesTrioOrUploads` (gate 4 suite, passed).

---

## 1. Rules S1–S8, end to end

The data path for a live reading:

```
G7 BLE ─ G7ConnectionCycle (auth) ─ G7ReadingPipeline (status, value, S3 dating, gate) ─ G7CGMSource.readings
   └─ ReadingPipeline.arrived: LiveReadingGate.validate (before store, D38)
        ├─ GlucoseStore.insert (role, range, finite rate, future date; dedupe) ─ returned rows only
        │     ├─ TrioCoordinator → TrioBridge.decide: gate again, D21 sentinels, re-gate whole window per write
        │     ├─ AlertService → AlertEngine.handle: gate again; only newest live non-backfill ≤ 6 min evaluated
        │     ├─ ReadingUploader.submit ×2 (Nightscout, Share): gate again, canRepresent (S4)
        │     └─ latestLiveReading (never imported) → Now UI, widget snapshot
        └─ store closed/failing (D42): Trio + alerts at once, held for store, uploads after storage
Imported history: importer → GlucoseStore only (charts, stats). Replay (DEBUG): separate store,
replay-accepting gate for alerts only; Trio/uploads keep the sensor-only gate.
```

### S1 — never fabricate a reading

Only four non-DEBUG places construct a `GlucoseReading`: G7 (`G7ReadingPipeline.swift:425-435`),
Nightscout import (`NightscoutEntry.swift:94`), Clarity import (`ClarityExportParser.swift:192`), and
the store's row decode (`ReadingRow.swift:103`). Every other construction (ReplayKit, `Fixtures.swift`,
`WidgetSamples.swift`, previews) is inside `#if DEBUG` (confirmed absent from Release, §2.2). Every
`ChartPoint`, `LatestReading`, plotted point and delta is built from a stored reading.

| Path | Enforced at | Proven by (all run, passed) |
|---|---|---|
| G7: a calibration echo (display-only) is never a reading | `G7ReadingPipeline.swift:374-377` (live), `:413-416` (backfill), flag from either reference `G7BackfillMessage.swift:49-50` | `test_S1_displayOnlyCalibrationValueIsNotEmitted`, `test_S1_calibrationIsNeverEmittedAsReading` |
| Calibration (D16) is a chart marker only; no app-side calibration math | `ChartScale.swift:43` (`FingerstickMarker`), `ViewStateMapping.swift:80-86`; `G7CalibrationQueue.swift:12-15` emits only `CalibrationUpdate` | `test_S1_calibrationNotShownAsReading`, `test_S1_calibrationsAreMarkersAndTheFlowShowsTheOutcome` |
| Store: no number outside 40…400 (parse-fault values) | `ReadingInsertion.swift:37-39` + schema CHECK | `test_S1_storeRefusesNumericValueOutsideSensorRange`, `test_S1_schemaRejectsNumericValueOutsideSensorRange` |
| Alerts: only the newest live, non-backfill reading, current ≤ 6 min; never carried forward; urgent-low-soon uses only the reported rate, projection never shown | `AlertEngine.swift:74-78, 145-159`; `AlertConditions.swift:78-92`; text always carries the measurement time `AlertText.swift:168-171` | `test_S1_aValueIsNeverCarriedForward`, `test_S1_staleBackfillDoesNotFireGlucoseAlert`, `test_S1_backfillNeverClearsAFiringUrgentLow`, `test_S1_noExtrapolationWhenRateIsMissing`, `test_S1_urgentLowSoonUsesOnlyTheReportedRate`, `test_S1_everyValueCarriesItsMeasurementTime`, `test_S1_snoozeExpiryNeverRefiresOnAStaleValue` |
| Trio / uploads: only readings the source delivered (no smoothing, no fill) | `TrioBridge.swift:132-139` (window = delivered readings only); `ReadingUploader.swift:155` | covered by the S2/S3 payload tests (`test_S3_payloadIsNewestFirstWithStrictlyDecreasingTimestamps`, `test_S3_backfillUploadKeepsOriginalTimestamp`) |
| Now hero / widget: a stale value is never shown as current; future-dated = clock mismatch | `GlucoseDisplayState.swift:50-83`, `NowFormatting.swift:42-56`, `WidgetTimeline.swift:101-133`; app latch `ClockMismatchMonitor.swift:43-76` | `test_S5_heroReplacedByMessageWhenStaleOrInvalid`, `test_S5_staleAt10MinutesAndNoDataAt20Minutes`, `test_S5_oldReadingIsShownOnlyMutedWithItsAgeAndNeverAsCurrent`, `test_S1_futureDatedNewestReadingIsNotCurrent`, `test_S1_nowNeverShowsAFutureDatedReadingAsCurrent`, `test_S1_clockChangeBetweenWakesLatchesTheLatestReading`, `test_S1_clockMismatchLatchSurvivesBootstrap` |
| Widget computes nothing (placeholder carries no value; snapshot only selects) | `SensorWidgets.swift:45-52`, `WidgetSnapshot.swift:53-78` | `test_S1_widgetTimelineNeverSynthesizesAValue`, `test_S1_makeSelectsRealReadingsOnly` |
| Charts: lines only between real points; a gap > 15 min or a flag breaks the line; scrub snaps to a real reading, "No data" in gaps (D23) | `ChartSeries.swift:58-118`, `GlucoseTraceChart.swift:185-201`, `ChartScrub.swift:62-92` | `test_S1_chartSegmentationNeverBridgesGapsOver15Min`, `test_S1_exactly15MinutesJoinsAndOneSecondMoreBreaks`, `test_S1_scrubSnapsToRealReadingsAndNeverInterpolates`, `test_S1_scrubInGapShowsNoData`, `test_S1_dailyTracesAreExactlyTheStoredReadings` |
| AGP: percentiles are nearest-rank (an observed reading); display smoothing returns its own type, used only by the chart | `AGPProfile.swift:109-117`, `AGPDisplaySmoothing.swift` (sole caller `TrendsMapping.swift:101`) | `test_S1_everyAGPPercentileIsAnObservedReading`, `test_S1_statisticsNeverContainDisplaySmoothedValues`, `test_S1_displaySmoothingLeavesTheProfileUntouched`, `test_S1_displaySmoothingNeverFillsAnEmptyBucket` |
| Delta: two real numeric readings ≤ 15 min apart, none across a flag | `LatestReading.swift:59-68` | `test_S4_noDeltaIsComputedAcrossAFlag`; the 15-min cap by `test_deltaUsesTheRealIntervalAndRefusesGaps` (not S-named) |
| Replay (DEBUG): emits exactly the scripted/exported values | ReplayKit | `test_S1_sourceEmitsExactlyTheScriptedReadings`, `test_S1_replayEmitsOnlyExportedReadingsAndGapsStayGaps` |

### S2 — only authenticated, valid readings reach storage / Trio / alerts

| Path | Enforced at | Proven by (all run, passed) |
|---|---|---|
| BLE → G7Kit: nothing from Write_Control or Backfill before authentication, nor after a `05` rejection | `G7ConnectionCycle.swift:112-122`; auth session `G7AuthSession` (solicited status only) | `test_S2_unauthenticatedSessionEmitsNothing`, `test_S2_unsolicitedAuthStatusDoesNotAuthenticate`, `test_S2_onlyTheSolicitedStatusCountsAndLaterRejectionIsSurfaced`, `test_S2_spoofedStatusBeforeTheRealRejectionDoesNotStayAuthenticated`, `test_S2_nothingIsPublishedAfterARejectionBeforeTheDisconnect`, `test_S2_spoofedStatusBeforeTheRealRejectionPublishesNothing`, `test_S2_unsolicitedAuthStatusDuringNewPairingPublishesNothing`; residual race pinned by `test_S2_residualP1cRaceIsBoundedToOneLiveReading` (D35) |
| G7Kit: sensor status valid (session length known and 10-day, response status 0, algorithm state OK, a value, not display-only, sensor clock agrees, newer than published) | `G7ReadingPipeline.swift:172-176, 182-189, 191-194, 362-365, 367-373, 374-377, 382-389`; backfill `:399-423` | `test_S2_warmUpReadingsAreNotEmitted`, `test_S2_invalidAlgorithmStatesAreNotEmitted`, `test_S2_expiredReadingsAreNotEmitted`, `test_S2_statusReplyWithCachedValueIsNotEmitted`, `test_S2_implausibleTimesAndMissingValuesAreNotEmitted`, `test_S2_nothingPublishedBeforeTheSessionLengthIsReported`, `test_S2_unsupportedSensorEmitsNothing`, `test_S2_warmUpAfterPairingPublishesNothing`, `test_S2_singleGarbledSensorClockDoesNotEndOrMoveTheSession`, `test_S2_sessionLengthIsRequestedBeforeGetData` |
| G7Kit: every emitted reading passes the shared gate (defence in depth) | `G7ReadingPipeline.swift:395, 420, 438-446` | `test_S2_everyEmittedReadingPassesLiveReadingGate` |
| G7Kit: `currentSession` lifetime (D28) | `G7Controller.swift:143-150` | `test_S2_currentSessionSurvivesDisconnectAndRelaunch`, `test_S2_currentSessionEndsOnFailureAndAfterGrace`, `test_S2_currentSessionNilForUnsupportedRejectedAndForgotten` |
| The gate itself (source, session, serial, start, warm-up, grace end, future, 40…400, finite rate, well-formed session) | `LiveReadingGate.swift:48-51, 66-80` | `LiveReadingGateTests`: `test_S2_refusesWithoutSession`, `…SerialMismatch`, `…ReadingBeforeSessionStart`, `…WarmUpReading`, `test_S2_acceptsGracePeriodRefusesAfterIt`, `…FutureReadingBeyondTolerance`, `…NumericValuesOutsideTheSensorRange`, `…NonFiniteTrendRate`, `…MalformedSession`, `test_S2_exactBoundariesAreInclusive`, `test_S2_sensorReadingWithEmptySerialNeverMatches` |
| App pipeline: gate on arrival, before the store and every consumer (D38); refused = never stored, never current | `ReadingPipeline.swift:226-236, 256-269`; consumers act on `insert`'s return `:340-345` | `test_S2_pipelineGatesEveryNewReadingBeforeConsumers` (also asserts consumers' own refusal counters stay 0), `test_S2_gateRefusedReadingIsNeverStored`, `test_S2_refusalInABatchKeepsTheValidReadings` |
| → store (range, finite rate, future-dated; whole batch) | `ReadingInsertion.swift:32-47` | `test_S2_nonFiniteTrendRateRejectsWholeBatch`, `test_S2_insertReturnsReadingsExactlyAsPassed`, `test_S2_storeRefusalInABatchKeepsTheValidReadings` (app) |
| → alerts | `AlertEngine.swift:91-96, 126-143` (refused reading changes nothing, not even the missed-readings clock) | `test_S2_implausibleReadingsNeitherFireNorClear` |
| → Trio (each write re-gates the whole window against the current session and clock; ended session never written) | `TrioBridge.swift:104-118, 132-139, 312-325` | `TrioBridgeSafetyTests`: `test_S2_refusesReadingWithoutSession` and the other 8 `test_S2_refuses…` tests, `test_S2_everyPayloadReadingIsRecheckedBeforeEachWrite`, `test_S2_newSessionWithoutReadingsRemovesPreviousSessionPayload`, `test_S2_gracePeriodEndRemovesPayloadEvenWithNilSession`, `test_S2_nilSessionBetweenReadingsLeavesPayloadAndWindowUntouched` (D28) |
| → Nightscout and Dexcom Share | `ReadingUploader.swift:137-147` | `UploadSafetyTests`: `test_S2_uploadersRefuse{WarmUpReading, ExpiredSessionReading, FutureReading, ImplausibleValue, MalformedSession, NonFiniteTrendRate, ReadingBeforeSessionStart, ReadingFromAnotherSensor, ReadingWithoutSession}` |
| → Trio re-seed after relaunch / switch-on (stored rows, 5 h) | `LiveAppServices+Sharing.swift:32-41`, `TrioCoordinator.swift:152-157` (`.sensor` only, then bridge gate) | `test_S5_launchFeedsAlertsAndTrioBeforeTheStoreOpensThenReseeds`, `test_trioReseedReleasesHeldReadingsWithTheStoredOnes` |
| → widget, Now UI | Only the pipeline's `latestLiveReading` (gate-passed, stored or held) `ReadingPipeline.swift:499-547`; widget re-filters imported `WidgetSnapshot.swift:61` | indirectly: `test_S2_gateRefusedReadingIsNeverStored` asserts a refused reading never becomes `latestLiveReading`. No widget-specific S2 test (none needed: the widget receives nothing else) |

S2 note: `LiveReadingGate` cannot see the sensor's algorithm state; "status says valid" is enforced
only in G7Kit (`G7ReadingPipeline.swift:362`). That is by design (contract comment
`LiveReadingGate.swift:5-6`) and well tested, but it is a single line of defence for that one
criterion.

### S3 — timestamps derived, monotonic, deduplicated; backfill keeps its time

| Path | Enforced at | Proven by (all run, passed) |
|---|---|---|
| G7 derivation: session start = receipt − sensor clock; reading time = sensor clock − age; date = start + sensor time | `G7SessionClock.swift:30-32` (receipt `G7Controller.swift:555`), `G7GlucoseMessage.swift:84-87`, `G7ReadingPipeline.swift:425-435` | `test_S3_timestampsAreDerivedFromTheSensorClock`, `test_S3_liveAndBackfillCopiesShareIdAndDate` |
| Session start fixed per serial and persisted; moves only after two agreeing anchors > 30 s off; disagreeing anchor withholds and surfaces | `G7ReadingPipeline.swift:191-194, 293-314`; `G7Controller.swift:672-684` | `test_S3_sessionStartIsStableAcrossLatencyJitter`, `test_S3_phoneClockSetBackWithholdsAndSurfaces`, `test_S2_singleGarbledSensorClockDoesNotEndOrMoveTheSession` |
| Dedupe key `serial:sensorTimestamp` | `GlucoseReading.swift:47-49`; G7 `G7ReadingPipeline.swift:382-389, 418`; store keeps the first row `ReadingInsertion.swift:94-103`; pipeline acts only on `insert`'s return `ReadingPipeline.swift:340-344`; held readings deduped `:377-395`; Trio skips known ids `TrioBridge.swift:104-110`; upload queue `PersistentReadingQueue.swift:77-78` | `test_S3_duplicateSensorTimestampsCollapseToOneID`, `test_S3_insertingTheSameReadingsTwiceChangesNothing`, `test_S3_sameIDWithDifferentContentKeepsTheStoredRowAndRecordsDiagnostic`, `test_S3_duplicateIDKeepsTheCopyAlreadyWritten`, `test_S3_redeliveredReadingIsPublishedOnce`, `test_S3_redeliveryWhileStoreFailingIsHeldOnce` |
| Monotonic: a live reading must be newer than everything published; dates keep sensor-time order; newest mark persisted | `G7ReadingPipeline.swift:386-393, 464-469`; `G7Controller.swift:682`; `insert` returns ascending `ReadingInsertion.swift:88-90` | `test_S3_liveReadingsAreMonotonic`, `test_S3_dateOrderHoldsAcrossRelaunch`, `test_S3_backfillDuringClockMismatchKeepsSensorTimeOrder`, `test_S3_insertReturnsOnlyNewReadingsAscendingByDate`. Across a relaunch the order is checked only against the persisted newest mark (finding m15) |
| Backfill keeps its own timestamp, flagged `isBackfill`; records wait for this connection's verified clock, discarded without one | `G7ReadingPipeline.swift:227-233, 261-264, 419` | `test_S3_backfillKeepsOriginalTimestampsAndFlagInOrder`, `test_S3_backfillWaitsForTheConnectionsSensorClock`, `test_S3_backfillAfterGapIsPublishedFlaggedAndOrdered`, `test_S3_backfillFlagAndOriginalTimestampAreKept` |
| Plausibility: start ≤ date ≤ now + 60 s (gate, store, importers) | `LiveReadingGate.swift:76-79`, `ReadingInsertion.swift:44-47`, `NightscoutEntry.swift:93`, `ClarityExportParser.swift:177` | `test_S2_refusesReadingBeforeSessionStart`, `test_S2_refusesFutureReadingBeyondTolerance`, `test_S3_futureDatedImportRowsAreSkippedNotStalling` |
| Imported times: Nightscout `date` unchanged; Clarity local time resolved with an explicit zone (spring-forward rejected, fall-back placed by transmitter time) | `NightscoutEntry.swift:92`, `LocalTimeResolver.swift:70-101`, `FallBackHourResolver.swift:60-102`, zone picker `OnboardingFlowView.swift:157, 210` | `test_S3_claritySpringForwardNonexistentTimeRejected`, `test_S3_clarityFallBackHourKeepsBothReadings`, `test_S3_clarityInterleavedFallBackPassesArePlacedByTransmitterTime`, `test_S3_clarityAmbiguousRowWithoutTransmitterTimeIsRejected`, `test_S3_clarityDSTInAnotherTimeZone` |
| Outbound dates: Nightscout `date`/`dateString` (ms), Share (s), Trio `/Date(ms)/`, widget snapshot (ms), CSV (UTC ms) — all the reading's own date | `NightscoutUploadDestination.swift:40-45`, `DexcomShareEGV.swift:89-93`, `TrioSharedReading.swift:57-59`, `WidgetSnapshotStore.swift:88, 95`, `CSVExport.swift:51-58` | `test_S3_backfillUploadKeepsOriginalTimestamp`, `test_S3_nightscoutRetryDoesNotDuplicateEntries`, `test_S3_dexcomShareBackfillKeepsOriginalTimestampAndNewestFirst`, `test_S3_timestampsAreWrittenToTheMillisecond`, `test_S3_payloadIsNewestFirstWithStrictlyDecreasingTimestamps`, `test_S3_datesRoundTripBitExact` |
| Calibration time converted with this connection's own anchor; refused during a clock mismatch | `G7CalibrationQueue.swift:92-99, 124` | `test_S3_calibrationTimeConvertedToTransmitterTime`, `test_S3_calibrationRefusedDuringClockMismatch` |

### S4 — LOW/HIGH stay flags

| Path | Enforced at | Proven by (all run, passed) |
|---|---|---|
| G7 raw field: < 40 → LOW, > 400 → HIGH; 0, 0x0FFF, 0xFFFE, 0xFFFF → "no value" (withheld, surfaced, never a flag, D31) | `G7GlucoseRange.swift:26-34` | `test_S4_lowAndHighFlagsArePreserved`, `test_S4_noValueRawsAreWithheldNotFlags`, `test_S4_lowAndHighAreFlagsNeverClampedNumbers` |
| Gate accepts flags; store writes them with `mgdl` NULL (CHECK) | `LiveReadingGate.swift:67` (numbers only), `ReadingRow.swift:27-37, 81-88` | `test_S4_acceptsLowAndHighFlags`, `test_S4_flagsAreStoredWithNoNumber`, `test_S4_schemaRejectsAFlagWithANumber`, `test_S4_lowAndHighRoundTripAsFlags` |
| → Trio: 39/401 only via the D21 policy; package default withholds; set explicitly in app wiring citing D21 | `TrioBridge.swift:326-340`, `OutOfRangePolicy.swift:36`, `TrioCoordinator.swift:49-50`, constants `TrioAppGroupContract.swift:41, 46`; `check.sh` lint | `test_S4_sentinelPolicyWrites39ForLowAnd401ForHigh`, `test_S4_flagsAreNeverWrittenAs40Or400`, `test_S4_defaultPolicyWritesNeitherLowNorHigh`, `test_S4_realFortyAndFourHundredPassUnchanged`, `test_S4_withheldLowIsVisibleInStatusAndDiagnostics`. **The app wiring itself is not proven by a test** (m5) |
| → Nightscout: LOW 39 / HIGH 401 (D29); a number outside 40…400 refused, never re-encoded | `NightscoutGlucoseEncoding.swift:65-71` | `test_S4_nightscoutUploadEncodesFlagsAs39And401NotClamped`, `test_S4_uploadEncodingIsTheFlagNotAClamp` |
| → Dexcom Share: 39/401 (D30, unverified until §11 4a) | `DexcomShareEGV.swift:63-69` | `test_S4_dexcomShareEncodesFlagsAs39And401NotClamped` |
| → Alerts: LOW meets every at-or-below condition, HIGH every at-or-above, with no number; urgent-low-soon does not project from a flag; text says LOW/HIGH | `AlertConditions.swift:42-65, 81-84`, `AlertText.swift:173-179` | `test_S4_lowFlagFiresUrgentLowWithoutBecomingANumber`, `test_S4_highFlagFiresHighWithoutBecomingANumber`, `test_S4_flagsCountAsBeyondEveryThresholdWithoutBecomingNumbers`, `test_S4_flagsAreWrittenAsFlags` |
| → Stats: LOW in < 54, HIGH in > 250; excluded from mean/SD/GMI; AGP keeps flags in rank order; smoothing keeps them | `GlucoseValue.swift:29-35`, `MeanAndVariability.swift:36-39`, `AGPProfile.swift:101-117`, `AGPDisplaySmoothing.swift:70-75` | `test_S4_lowAndHighAreExcludedFromMeanSDAndGMI`, `test_S4_lowCountsBelow54AndHighCountsAbove250`, `test_S4_agpPercentilesKeepTheFlags`, `test_S4_displaySmoothingNeverTurnsAFlagIntoANumber`, `test_S4_lowIsNeverTreatedAs40AndHighNeverAs400`, `test_S4_lowFlagIsALevel2Low`, `test_S4_trendsNeverTurnFlagsIntoNumbers` |
| → UI and widget: words, never 40/400; trace charts draw flags as labelled edge markers (the 40 floor is an axis domain); scrub shows the word; no delta across a flag | `GlucoseText.swift:11-17, 156-160`, `GlucoseTraceChart.swift:266-293`, `ChartScale.swift:9`, `LatestReading.swift:63` | `test_S4_lowHighFormatAsWordsNeverAsNumbers`, `test_S4_lowHighHeroAndStateLineNeverShow40Or400`, `test_S4_flagsBecomeEdgeMarkersNeverPlottedValues`, `test_S4_scrubShowsLowHighAsText`, `test_S4_flagsSurviveEncoding`, `test_S4_lowHighHeroVisibleAtAccessibilitySizes`, `test_S4_noDeltaIsComputedAcrossAFlag` |
| → AGP chart: a flag percentile is drawn at the floor/ceiling (`AGPLineValue.chartY`), never as a number; VoiceOver says LOW/HIGH | `TrendsCharts.swift:47-111`, `TrendsFormatting.swift:168-173` | `test_S4_agpHighPercentileIsDrawnAboveEveryNumber`. Visually unlabelled at the edge (m16, carry-over) |
| → CSV export: LOW/HIGH as text | `CSVExport.swift:21-26` | `test_exportMatchesGoldenFile` (golden rows; not S4-named) |
| → Calibration screen: a flag is never compared with a fingerstick | `CalibrationRules.swift:141` | `test_differenceCheck` |
| Import: Clarity "Low"/"High" → flags, 39/401/other out-of-range numbers rejected; Nightscout 39 ≤ sgv < 40 → LOW, > 400 → HIGH, < 39 skipped as error code | `ClarityExportParser.swift:211-218`, `NightscoutGlucoseEncoding.swift:53-59` | `test_S4_clarityLowHighMapToFlags`, `test_S4_clarityNumbersOutsideSensorRangeAreRejectedNotClamped`, `test_S4_nightscoutImportLowHighMapToFlags`, `test_S4_nightscoutImportClassifiesLikeNightscoutDisplay` |

Known, documented limitation (not this app's clamp): Nightscout history written by Trio's own G7
path holds LOW/HIGH as 40/400 (D21 evidence), so it imports as those numbers
(`docs/import.md:71-75`). It feeds charts and stats only; TIR bins are unaffected (40 < 54,
400 > 250), mean/SD slightly so.

### S5 — fail loud

| Condition | UI surface | Alert (§5) | Proven by |
|---|---|---|---|
| No reading for 15 min | Banner `AppBanner.swift:297-334` (incl. "No readings yet" and clock mismatch); Now hero replaced at 10/20 min `GlucoseDisplayState.swift:75-82`, `NowFormatting.swift:35-60`; widget dims at 10, muted last reading with its time from 20 (D61) `WidgetTimeline.swift`, `WidgetReading.swift`, transition dates `GlucoseDisplayState.swift:102-103` | Missed readings, pre-scheduled so it fires while suspended `AlertEngine+MissedReadings.swift:19-71`; suppressed only on a confirmed end with its sensor alert on (D39/D41) | `test_S5_missedReadingsBannerAt15Minutes`, `test_S5_heroReplacedByMessageWhenStaleOrInvalid`, `test_S5_heroGoesStaleOnTheClockWithoutANewState`, `test_S5_staleAt10MinutesAndNoDataAt20Minutes`, `test_S5_oldReadingIsShownOnlyMutedWithItsAgeAndNeverAsCurrent`, `test_S5_missedReadingsAfter15MinutesWithoutAValidReading`, `test_S5_missedReadingsFiresEvenIfNoReadingEverArrived`, `test_S5_missedReadingsFiresAfterWarmUpEndsWithoutReadings`, `test_S5_transientFailureAfterWarmUpIsNotSilent`, `test_S5_missedReadingsSuppressedAfterConfirmedEndButSensorAlertStays`, `test_S5_disabledSensorAlertNeverSuppressesMissedReadings`, `test_S5_briefExpiryDoesNotPostponeMissedReadings`, `test_S5_missedReadingsSurvivesClockRollback` |
| BLE off / unauthorized / unsupported | `CBManagerState` → `.bluetoothUnavailable` `G7SensorStatus.swift:22-25`; banners `AppBanner.swift:345-368`, permission banner `:219-228` | `bluetoothUnavailable` `AlertEngine.swift:182`, `AlertConditions.swift:190` | `test_S5_managerStatesMapToBluetoothPower`, `test_S5_bluetoothStatesAreSurfaced`, `test_S5_bluetoothUnavailableSurfacesAndRecovers`, `test_S5_bluetoothUnavailableAlertsAndClears`, `test_S5_eachConditionMapsToAVisibleBanner` |
| Sensor error / failed / needs pairing / calibration | Banners `AppBanner.swift:369-423`; hero `test_S5_failureHeroUsesTheSourceMessage` | `sensorFailed`/`sensorError`/`calibrationNeeded` `AlertEngine.swift:178-180` (D36/D37) | `test_S5_sensorErrorAlertsAndTheConnectionCycleDoesNotClearIt`, `test_S5_sensorFailedAlerts`, `test_S5_endedSensorAndLostPairingRaiseTheSensorAlert`, `test_S5_transientSensorFailuresDoNotRaiseTheSensorAlert`, `test_S5_endedSensorOrLostPairingIsCritical`, `test_S5_unclassifiedFailureIsCritical`, `test_S5_calibrationNeededReplacesTheHero` |
| Sensor expiring / grace / expired | Banners `AppBanner.swift:424-449`; grace countdown (D43) | D43 reminders 24 h (silent), 12 h, 2 h, grace start, expired — pending notifications `AlertEngine+ExpiryReminders.swift` | `test_S5_expiryRemindersFireWhileTheAppIsSuspended`, `test_S5_sensorExpiredAlertsUntilANewSensor`, `test_S5_aMissingSensorExpiredIsPostedWhenTheEndIsDetected`, `test_S5_sensorExpiredRefusedByTheSystemIsPostedWhenTheEndIsDetected`, `test_S5_unconfirmedExpiryIsNotExpired`, `test_S5_endReportedOnTwoConnectionsEndsTheSessionVisibly` |
| Trio bridge write failure / starvation / no App Group | Banner `AppBanner.swift:118-127` via `ServiceHealthMapping.swift:38-58` | `trioBridge` `AlertEngine.swift:183`; input `TrioAlertInput.swift:13-28`, forwarded by `LiveAppServices+Alerts.swift:97-108` | Bridge: `test_S5_failingWriteSurfacesInStatusAndRecovers`, `test_S5_missingAppGroupAccessIsAWriteFailure`, `test_S5_starvingWhenGateRefusesLiveReadingsFor15Minutes`, `test_S5_starvingWhenWritesFailAndRecoversOnWrite`; engine: `test_S5_trioBridgeWriteFailureAlerts`; app: `test_S5_trioBridgeOnWithoutAnAppGroupIsFailing`, `test_S5_aLongHoldCountsAsStarvingTrio`, `test_S5_everyServiceHealthProblemBecomesABanner`. **Not proven end to end:** a real bridge write failure → `TrioBridgeSummary.isFailing` → `alertInput` → alert service (the app's `RecordingTrioStore.checkAccess` never throws; finding m4) |
| Storage closed / failing (D42) | Banner `AppBanner.swift:201-217` | `storageFailing` after 5 min `AlertEngine.swift:184`; alerts and Trio still fed | `test_S5_failingStoreStillAlarmsUrgentLowAndFeedsTrio`, `test_S5_storeClosedStillTicksAlerts`, `test_S5_storeClosedBeforeFirstUnlockSurfacesAndRecovers`, `test_S5_failedStoreOpenRaisesTheStorageAlertAndKeepsThePersistedLatch`, `test_S5_storageFailingAlertsAfterFiveMinutesAndClearsOnRecovery` |
| Uploads failing / not set up | Banners `AppBanner.swift:164-177, 238-251` | none (§5 lists none; correct) | `test_S5_nightscoutFailureSurfacesInStatus`, `test_S5_dexcomShareFailureSurfacesInStatus`, `test_S5_refusalsSurfaceUntilAnUploadSucceeds`, `test_S5_failureAndBackoffSurviveRelaunch`, `test_S5_unreadableQueueFileSurfacesInStatus`, `test_S5_replacingAnUploaderReleasesTheQueueFileFirst` |
| Alert delivery impaired (notifications denied/quiet, volume low, AlarmKit denied/failed, repeats short) | Banners `AppBanner.swift:129-162, 253-291` | — | `test_S5_notificationsDeniedIsSurfaced`, `test_S5_partialPermissionsAreSurfaced`, `test_S5_mutedOrLowAlarmVolumeIsSurfaced`, `test_S5_alarmSchedulingFailureFallsBackAndSurfaces`, `test_S5_aPartialRepeatFailureIsSurfaced`, `test_S5_shortfallIsLoggedAndSurfacedThenClears` |
| Force-quit gap (HANDOFF §4.6) | Banner `AppBanner.swift:179-185` | — | `test_S5_forceQuitGapIsReportedOnlyForASilenceWithAnActiveSensor` |

### S6 — only live sensor data reaches Trio, alerts, uploads

| Path | Enforced at | Proven by |
|---|---|---|
| Importers produce only `.imported` and write to the store only, never the pipeline | `ClarityExportParser.swift:200`, `NightscoutEntry.swift:100`; `LiveAppServices+Sharing.swift:183-204` (production store only) | `test_S6_nightscoutImporterProducesOnlyImportedReadings`, `test_S6_clarityImporterProducesOnlyImportedReadings`, `test_S6_importedReadingsNeverReachConsumers` (app: stored history plus an imported reading delivered through a source by mistake — refused by the pipeline gate, nothing reaches Trio, uploads, alerts or the current value) |
| Pipeline gate refuses non-sensor (replay only in a DEBUG replay pipeline) | `ReadingPipeline.swift:256-269`; the G7 pipeline is built with the sensor `init` (`LiveAppServices.swift:145`) | `test_S6_importedReadingsNeverReachConsumers` |
| → Trio | `TrioBridge.swift:316-320` (`validate`, never the replay variant); replay pipeline passes a nil session `ReadingPipeline.swift:475-480`; re-seed filters `.sensor` `TrioCoordinator.swift:154` | `test_S6_bridgeRefusesImportedReplayAndMockReadings`, `test_S6_mixedBatchWritesOnlySensorReadings`, `test_S6_replayNeverReachesTrioOrUploads` (gate 4, app wiring with the D20 switch on); release config re-run passed |
| → alerts | `AlertEngine.swift:126-143` (Release: `validate` only) | `test_S6_importedReadingNeverFiresAnAlert`, `test_S6_mockReadingNeverFiresAnAlert`, `test_S6_nonSensorReadingsNeverClearAnAlert`, `test_S6_replayRefusedUnlessReplayModeIsOn`, `test_S6_importedReadingDoesNotResetMissedReadings`, `test_S6_serviceRefusesAnImportedReadingAndSaysSo`; **`test_S6_releaseBuildRefusesReplayReadings` (release config, run by me)** |
| → Nightscout, Share (incl. a tampered queue file) | `ReadingUploader.swift:140`, flush-time discard `:242-257` | `test_S6_nightscoutUploaderRefusesImportedReplayAndMock`, `test_S6_dexcomShareUploaderRefusesImportedReplayAndMock`, `test_S6_queuedNonSensorReadingIsDiscardedNotUploaded`, `test_S6_liveSensorReadingIsAcceptedByBoth`; release config re-run passed |
| Production store refuses replay/mock, purges them on open (D20) | `StoreRole.swift:20,44`, `ReadingInsertion.swift:34`, `GlucoseStore.swift:74` | `test_S6_productionStoreRefusesReplayAndMock`, `test_S6_mixedBatchIsRejectedWhole`, `test_S6_productionStorePurgesReplayRowsOnOpen`, `test_S6_replayStoreRefusesSensorAndImported` |
| Current value (Now, widget, delta, missed-readings, alerts) never imported | `GlucoseStore.latestLiveReading` `GlucoseStore.swift:152`; pipeline filter `ReadingPipeline.swift:514, 523-529`; widget `WidgetSnapshot.swift:61-63` | `test_S6_latestLiveReadingIgnoresImported`, `test_S6_latestLiveReadingIsSensorOnlyInProduction`, `test_S6_makeNeverUsesImportedHistoryAsTheCurrentValue`, `test_S6_importedHistoryNeverBecomesTheCurrentValue` |
| DEBUG builds: Trio and uploads off unless the developer switch (D20) | `LiveAppServices.swift:228-234`; `TrioCoordinator.swift:88-90`; `UploadCoordinator.swift:101,126` | `test_S6_trioBridgeIsNotAttachedWithoutLiveOutputsAllowed`, `test_S6_uploadersAreNotCreatedWithoutLiveOutputsAllowed` |
| Replay/mock compiled only in DEBUG | ReplayKit sources wrapped in `#if DEBUG`; `LiveReadingGate.swift:53-64`; `ReplayRun.swift`, `LiveAppServices+Replay.swift`, `AppEnvironment.swift:113-127` | `test_S6_everyReplayKitSourceFileIsWrappedInIfDebug`; `check.sh` object-file checks; **`nm` on the Release app binary (§2.2)** |

### S7 — urgent low cannot be disabled; snooze ≤ 30 min

| Path | Enforced at | Proven by |
|---|---|---|
| Settings model: no `isEnabled`, `isEnabled(.urgentLow)` constant true, `setEnabled` refuses | `AlertRuleSettings.swift:11-39`, `AlertSettings.swift:61, 177-179` | `test_S7_urgentLowCannotBeDisabledThroughTheSettingsAPI` |
| Persisted settings (tampered `isEnabled:false`, out-of-range numbers) | `AlertSettings.swift:296+` (types are `Encodable` only; decoding rebuilds through clamping inits) | `test_S7_decodedDisabledUrgentLowStaysEnabledAndClamped`, `test_S7_urgentLowFiresWithStoredSettingsThatTryToDisableIt` |
| Snooze 1–30 / repeat 2–5 clamped on every assignment | `AlertRuleSettings.swift:16-27`, `AlertLimits.swift:12-21` | `test_S7_urgentLowSnoozeAndRepeatAreClampedOnEveryAssignment` |
| Snooze requests (in-app, lock-screen action, AlarmKit Stop) clamped in the engine; no pre-emptive snooze | `AlertEngine+User.swift:16-22, 34-40`; AlarmKit Stop via `AlarmIntentRouting` `LiveAppServices+Alerts.swift:113-119` | `test_S7_snoozeLongerThan30MinutesIsClampedTo30`, `test_S7_resnoozingCannotExtendPast30MinutesFromNow`, `test_S7_lockScreenSnoozeOf600MinutesIsClampedTo30`, `test_S7_alarmStopCannotSnoozePast30Minutes`, `test_S7_urgentLowCannotBeSnoozedBeforeItFires`, app `test_S7_alarmStopIntentAcknowledgesUrgentLowForAtMost30Minutes` |
| Restored snapshot, clock rollback | `AlertEngine.swift:40-52`, `AlertEngine+Clock.swift:103-128` | `test_S7_restoredUrgentLowSnoozeIsClampedTo30Minutes`, `test_S7_restoredSnoozeFromATamperedFileIsClamped`, `test_S7_clockMovedBackCannotExtendUrgentLowSnooze`, `test_S7_partialRollbackDuringSnoozeEndsIt`, `test_S7_partialRollbackWithNoInputInBetweenEndsTheSnooze`, `test_S7_restoredSnapshotCarriesNoStretchedSnoozeAcrossRelaunch` |
| Quiet hours, sound, delivery path | `AlertEngine.swift:313, 338` (never silenced, always plays), `DeliveryPolicy` | `test_S7_urgentLowSoundsDuringQuietHours`, `test_S7_urgentLowAlwaysGetsTheLoudestAvailablePath`, `test_S7_urgentLowCannotBeSilencedAndSoundsWhenEveryOtherAlertIsSilent`, `test_S7_urgentLowFiresWithEveryOtherAlertOff` |
| Repeats never cancelled by the app itself while due/ringing | `AlertEngine+Series.swift`, `AlertDeliveryExecutor` | `test_S7_wakeNearARepeatNeverCancelsTheDueAlarm`, `test_S7_ringingRepeatIsNeverStoppedByReschedule`, `test_S7_dueRepeatWhoseAlarmVanishedPlaysTheInAppSound`, `test_S7_idReuseNeverTouchesALivePendingRepeat` |
| UI (Alerts screen, AppModel edits) | `AlertsMapping.swift:57-71` (ranges from `AlertLimits`), writes through the settings types | `test_S7_urgentLowCannotBeDisabledOrSnoozedPast30Minutes`, `test_S7_editsKeepUrgentLowOnAndSnoozeCapped`, `test_S7_thresholdsUseAlertLimits`, `test_S7_alertEditsCannotDisableUrgentLowOrExceed30MinSnooze` |
| End to end on a scenario | replay wiring | `ReplayScenarioTests.test_slowFallToUrgentLow_…` (gate 4) |

One S7 behaviour worth Michael's explicit sign-off (finding m2): the snooze **end** is not
pre-scheduled. When an acknowledged urgent low's 30 minutes are up, it sounds again only when a
*current* (≤ 6 min) reading ≤ threshold arrives (`AlertEngine.swift:220-221`; documented in
`docs/alerts.md` "Snooze expiry"). With the sensor in range that is the next G7 wake, so ≤ ~35 min.

### S8 — auditable

Small modules with headers stating order and rules; every non-obvious protocol byte cited (§5).
Tests: `test_S8_everyPortedFileCarriesAttribution`, `test_S8_vendoredMicroECCKeepsItsLicense` (G7Kit
only — the four NightscoutKit Share ports have no equivalent test, finding m11). Details in §5.

---

## 2. Bypass hunt

### 2.1 Consumers that read readings without the gate

Every call that hands a reading to a consumer, found by grep over `App/Sources` and checked by reading:

- `ReadingPipeline.swift:444` (Trio), `:451` (alerts), `:464` (uploads) — all after the arrival gate;
  each consumer gates again.
- `TrioCoordinator.swift:118, 127, 155` — all into `TrioBridge.publish`, which gates every reading
  before every write.
- `ReadingPipeline.swift:545` (widget) — only `latestLiveReading`/`previousLiveReading` (gate-passed)
  plus a chart window that may include imported history (allowed: charts).
- Readers of the store (`AppModel.swift:402, 589`, `LiveAppServices.swift:241-244`) feed charts and
  stats only; `LiveAppServices+Sharing.swift:36` is the Trio re-seed (filtered to `.sensor`, then gated).

No bypass found.

### 2.2 Replay / mock / imported in Release

`nm -U` on `Build/Products/Release-iphoneos/Sensor.app/Sensor` (55 159 defined symbols): **0**
matches for `$s9ReplayKit`, `validateAllowingReplay`, `12GlucoseStoreAAC6replay` (replay store role),
`acceptsReplayReadings`, `ReplayRun`, `NightscoutReplaySource`, `makeReplayService`, `startReplay`,
`SilentAlert` (the `-silenceAlertAudio` ports). Positive control,
`Debug-iphoneos/Sensor.app/Sensor.debug.dylib`: 967, 1, 4, 10, 68, 3, 1, 57, 46 respectively.
`strings` on the Release binary: 0 for the scenario names, "Replayed data", "DEBUG BUILD",
`acceptsReplayReadings`. The widget extension's Release binary: 0 replay symbols. Remaining
DEBUG-flavoured strings in Release are inert: the preference key `sensor.debug.developerLiveOutputs`
(read only by `#if DEBUG` code; `liveOutputsAllowed` is constant `true` in Release,
`LiveAppServices.swift:228-234`) and Settings copy. `.imported` cannot reach a consumer in any
build (S6 table).

DEBUG-only observation (m9): a replay run writes the widget snapshot (`LiveAppServices+Replay.swift:53`),
and the snapshot has no replay marker, so the Home Screen widget shows replayed values unlabelled
during §11 step 1.

### 2.3 LOW/HIGH turned into a number

Grepped for `numericMgdl ??`, `?? 40`, `?? 400`, and every `case .belowRange`/`.aboveRange` that
returns a number; each hit was read. The only conversions are the three documented sentinels: Trio
D21 (`TrioBridge.swift:333, 338`), Nightscout D29 (`NightscoutGlucoseEncoding.swift:65-71`), Dexcom
Share D30 (`DexcomShareEGV.swift:63-69`). Chart edge positions (`GlucoseTraceChart.swift:266-293`,
`AGPLineValue.chartY`) are drawing coordinates for a labelled marker or an AGP line, not values; the
AGP one lacks a visual label (m16). None found that violates S4.

### 2.4 Timestamps assumed rather than derived

Every `Date()` in non-test sources (`Packages/*/Sources`, `App/Sources`, `Widgets/Sources`) was
read: all are injectable clock defaults, the alert wall clock, audio loop timing, the widget's
"now", diagnostic/import-progress metadata or status times — none dates a reading. Reading dates come only from the sensor clock (`G7ReadingPipeline.swift:428`), Nightscout's
`date`, or a Clarity local time with an explicit zone. Two display-level caveats: Trends 1 D/3 D
plot elapsed hours since local midnight, so on a DST day the overlay is an hour off its axis labels
(`TrendsCharts.swift:12-17`, m17); and the G7 sensor-time order check after a relaunch sees only
the persisted newest mark (m15). Nit: `TrioCoordinator.swift:65` refreshes starvation with `Date()`
rather than its injected clock (tests only).

### 2.5 Alerts that could be disabled in violation of S7

None. Checked: settings API, persisted settings, every snooze entry point (in-app, notification
action, AlarmKit Stop, restore, clock rollback), quiet hours, per-alert sound and `playsSound`
(urgent low always plays, `AlertEngine.swift:338`; no "none" sound exists, `AlertSound.swift:6-15`),
D20/`-silenceAlertAudio` (DEBUG only; absent from Release, §2.2). Notification or alarm permission
denied cannot be prevented by an app; both surface as critical banners (S5 table).

### 2.6 Silent failures

Every `try?` in non-test sources was checked. None swallows a failure on a reading path. The
relevant ones degrade loudly: `AppPreferences.swift:140,148` (snapshot/settings encode → nil →
defaults next launch: snoozes end, i.e. errs loud), `PersistentReadingQueue.swift:61` (unreadable
queue moved aside, surfaced as `queueLoadProblem`). Silent paths found:

- Readings held for a failing store are lost from history **and from uploads** if iOS terminates
  the app first (G7Kit has already persisted its newest-published mark, `G7Controller.swift:662-683`,
  so it will not re-request them). Alerts and Trio had them and the storage alert fired. (m1, must-do 7b.)
- The pipeline's held-event caps drop the oldest beyond 10 000 with a diagnostic only
  (`ReadingPipeline.swift:245-249, 385-389`) — five weeks of readings; not reachable in practice.
- A reading the gate passed but the store refuses (store clock behind the pipeline's) is logged and
  reaches no consumer (`ReadingPipeline.swift:416-418`). Both use the same phone clock in the app, so
  this needs a bug to happen; it errs on the side of not publishing.

---

## 3. Phase 2 must-dos

| Must-do | Status | Where | Test |
|---|---|---|---|
| Trio heartbeat keys | done | `G7HeartbeatTarget.swift:19-31`; `TrioCoordinator.swift:209-245`; re-evaluated after pair/forget/every state `LiveAppServices.swift:158-163`, foreground and 60 s ticker | `test_heartbeatIsPublishedOnlyWithAPairingAndTheBridgeOn`, `test_heartbeatKeysWrittenLaterByAnotherAppAreReplaced`, `test_heartbeatWritesUUIDsBeforeAddressAndRemovesAddressFirst`. Trio actually waking: device (§6) |
| D21 policy in wiring + lint | done | `TrioCoordinator.swift:49-50`; `check.sh` lint | package `test_S4_sentinelPolicyWrites39ForLowAnd401ForHigh`. **No app-level test** that the coordinator's bridge carries the D21 policy (m5) |
| `publish([])` on foreground and timer; re-seed ~5 h | done | `LiveAppServices.swift:654, 684`; `LiveAppServices+Sharing.swift:32-41` | re-seed: `test_S5_launchFeedsAlertsAndTrioBeforeTheStoreOpensThenReseeds`. Foreground/timer retry: not proven |
| DEBUG: Trio and uploaders off without the developer switch | done | `LiveAppServices.swift:228-234` | `test_S6_trioBridgeIsNotAttachedWithoutLiveOutputsAllowed`, `test_S6_uploadersAreNotCreatedWithoutLiveOutputsAllowed` |
| Uploader flush/credentials wiring; queue in App Group; Keychain; checkpoint store; `deviceName` | done, **one divergence**: queues live in `Application Support/Uploads` (`AppEnvironment.swift:69`), not the App Group. Better for the same reason as D25 (0xDEAD10CC), documented in `architecture.md`, but no D-entry (m10) | `ReadingPipeline.swift:470`, `UploadCoordinator.swift:251-261` | `test_S5_pipelineUploadsThroughAReplacedUploader`. Credential-change flush, `.alreadyFlushing` repeat, `deviceName`: not proven |
| NOTICE.md entries | done; gaps in §5.6 | `NOTICE.md` | `test_everyNoticeProjectIsCreditedInTheApp`, `test_licencesMatchNotice` |
| Store before first unlock: retry, surface, hold | done | `LiveAppServices.swift:174-180, 437-462`; `AppBanner.swift:202` | `test_S5_storeClosedBeforeFirstUnlockSurfacesAndRecovers` |
| Base backfill on the latest *stored* reading | **missing**, no deferring decision; acknowledged only in `architecture.md:201-205` (m1) | — | — |
| DEBUG accelerated replay uses replay time | **partial**: gate, store, alerts use replay time (`ReplayRun.swift:39-42`); the UI's clock is `Date()` (`AppModel.swift:157`), so at the Developer default of 60× Now/widget show "no current reading"/clock mismatch (m8, DEBUG only) | — | none |
| Contract additions (`calibrationNeeded/Error`, `invalidTime`) | done (D36) | `SensorState.swift:22-24` | `test_S5_calibrationNeededReplacesTheHero`, … |
| Signal loss from reading age | done | `AlertEngine+MissedReadings.swift`, `AppBanner.swift:297-334` | `test_S5_missedReadingsBannerAt15Minutes`, `MissedReadingsTests` |
| Hosted Keychain tests | done | — | `test_g7PairingRecordRoundTripsAfterFirstUnlockAndNotSynchronizable`, `test_nightscoutAndShareCredentialsRoundTripAfterFirstUnlockAndNotSynchronizable` |
| TrioBridge doc note + early-stop test | done | `docs/trio-bridge.md` | `test_S2_sensorStoppedEarlyPayloadStaysUntilNextSensorGraceEndOrClear` |
| NightscoutKit wiring (`try` factories, credentials→flush, `.alreadyFlushing`, future-dated counts in progress) | done | `UploadCoordinator.swift`, `HistoryImportCoordinator.swift:76,130` | partly; display of `rejectedFutureDated` not proven |
| Stats wiring | done | `ViewStateMapping.swift:75` | `test_fetchIntervalCoversThePreviousPeriodAndA24HourMargin`, `test_todaySoFarCountsALowThatBeganBeforeMidnight`, `test_dataSufficiencyWarningUnder70PercentIncludingNextToGMI` |
| AlertEngine wiring (intent, AlarmKit, delegate, ticks, replay service) | done | `AppEnvironment.swift:90-110`, `LiveAppServices.swift:478-487`, `ReadingPipeline.swift:313-316` | `test_S7_alarmStopIntentAcknowledgesUrgentLowForAtMost30Minutes`, `test_S5_storeClosedStillTicksAlerts` |
| `StoreSchema` rowid comment + "never VACUUM" | **partial**: rowid ordering documented (`StoreSchema.swift:83-89`), no VACUUM warning (m12) | | n/a |
| Release old uploader; `QueueFileInUse` as S5 | done | `UploadCoordinator.swift:184-228` | `test_S5_replacingAnUploaderReleasesTheQueueFileFirst` |
| Alert ranges from `AlertLimits` | done | `AlertsMapping.swift:57-71` | `test_S7_thresholdsUseAlertLimits` |
| Persist/mirror the clock-mismatch latch | done | `LiveAppServices.swift:257-281`, `AppModel.swift:383-390` | `test_S1_clockLatchAndWidgetSurviveTheLaunch`, `test_S1_clockMismatchLatchSurvivesBootstrap` |
| Map G7 failure reasons | done | `SensorState.swift:64-84` | `test_S5_transientFailureIsAWarningNotCritical`, `test_S5_endedSensorOrLostPairingIsCritical` |
| Memoryless clock check; future-dated newest is stale | done | `ClockMismatchMonitor.swift:43-76`, `AlertEngine+Clock.swift:56-66` | `test_S1_clockChangeBetweenWakesLatchesTheLatestReading`, `test_S1_futureDatedNewestReadingIsNotCurrent` |
| Flag other G7 apps (D35) | done | `OnboardingState.swift:123`, `otherAppRejected` banner | banner tests; onboarding copy not proven |
| actool retry | deferred by its own "if it recurs" condition | — | — |

Phase 3 carry-overs still open in code: AGP HIGH/LOW percentile drawn at 400/40 with no visual label
(`TrendsCharts.swift:47-111`; VoiceOver says it); `currentSession` grace-end judged on the phone
clock (`G7Controller.swift:149`, accepted under D28); Trio App Group newest moving backwards after the
2-minute hold (`TrioCoordinator.swift:98-101, 122-128`, pinned by `test_S5_trioLaunchHoldIsReleasedAfterTwoMinutes`;
Trio dedupes by timestamp, low impact); `AlertEngine.sanitized` not checking `knownSession.isWellFormed`
(reminder dates only); latch compound case (`ClockMismatchMonitor.swift:53-75`); held-back count not
shown in Settings (starvation alert is the backstop). Fixed: onboarding pairing spinner
(`AppModel.swift:428`).

---

## 4. Decisions D1–D43

All checked decisions are implemented as written. Divergences:

- **D25 — stale comments**: `Config/Base.xcconfig:10` and `Config/Signing.example.xcconfig:10` still say
  the SQLite database lives in the App Group; the code puts it in Application Support
  (`AppEnvironment.swift:82`). Comment only, but it misleads an S8 audit (m13).
- **Must-do "queue in App Group"** (not a D-entry): see §3 (m10).

Not verifiable without a device: D2 (entitlements, same Team ID, Trio reading our writes); D4
(Critical Alerts); D17 (`.playback` audible on silent during a BLE wake; Time Sensitive vibrate-only
when suspended); D21/D22 (Trio consuming the payload, oref on 39/401, Trio's upload switches); D25
(writes while locked for hours, no 0xDEAD10CC); D26/D34 (AlarmKit on silent/Focus while suspended,
repeats, Stop, 31 alarms at the 2-min floor, permission revoked with repeats pending); D28
(`currentSession` across real disconnects and state-restoration relaunches); D29 (Nightscout "LOW",
LoopFollow alarms on 39); D30 (Dexcom Follow shows LOW/HIGH from 39/401 — revert to withholding if
not); D31 (a captured real LOW/HIGH packet); D35 (`otherAppRejected` and the spoof race); D36/D37/D41
(real algorithm states → kinds; `pairAgain` after a real bond removal; the two-report end latch on a
real expiring sensor); D43 (reminders on time while suspended, 24 h silent); D5 (both apps on one
phone); D23/D32 (haptics, dark tokens tuned on device).

---

## 5. Code hygiene (S8)

### 5.1 `@unchecked Sendable`, `nonisolated(unsafe)`, `assumeIsolated`

No `nonisolated(unsafe)`, `unsafeBitCast` or `Unmanaged` in non-test sources.

| Site | Justification | Verdict |
|---|---|---|
| `G7CGMSource.swift:18` | `:19-22` all stored properties `let`; controller/central used only on `queue` | holds — every access through `onQueue`/`queue.sync` (`:79, 84, 182-190`) |
| `G7CoreBluetoothCentral.swift:263` `QueueBoundAction` | created and run on `queue` | holds — callers `G7Controller.swift:196,350`, `G7AuthSession.swift:499,504`, all on the BLE queue |
| `PlaybackAlertAudioPlayer.swift:180` `ObserverToken` | immutable; `removeObserver` thread-safe | holds |
| `NightscoutKit/Support/CredentialStore.swift:37` `InMemoryCredentialStore` | `values` under `lock` | holds (tests/previews only) |
| `ReadingUploader.swift:40` `QueueFileRegistry` | `claimed` under `lock` | holds |
| `RingBufferDiagnosticLog.swift:11` | `events`, `unsavedCount` under `lock` | holds; comment omits `hasLoadedSaved` (also locked); two concurrent `save()` can persist an older snapshot last — diagnostics only (m14) |
| `LiveAppServices.swift:177` `MainActor.assumeIsolated` | **none** | sound (observer registered with `queue: .main`, `:175`); add the one-line reason (m14) |

### 5.2 Force unwraps / `try!` on external data

No `try!`, `as!`, `fatalError` or IUO declarations in non-test sources; no force unwrap touches BLE,
JSON, CSV, Keychain, UserDefaults or App Group data. Every G7 parser checks length before indexing
(`G7GlucoseMessage.swift:68`, `G7BackfillMessage.swift:44`, `G7ExtendedVersionMessage.swift:35`, …);
unsigned subtractions are guarded (`G7GlucoseMessage.swift:86`, `G7ReadingPipeline.swift:341,350`).
11 Release force unwraps are on constants (UUID/URL literals, `TimeZone("UTC")`, the P-256
generator, fixed 32-byte `G7Scalar`s at `G7ECCMath.swift:90,96,104,111` — safe, uncommented).
One trap on external data found outside the force-unwrap grep: `NightscoutHistoryImporter.swift:242`
`Int64(oldest.rounded(.down))` (m6).

### 5.3 Ported files keep headers and name their source

24 G7Kit files and 4 NightscoutKit DexcomShare files are marked ported, each naming the xDrip4iOS
file and `@ 7.1.0 (0370937)`; original copyright headers are kept verbatim where upstream has one
(Racklyeft, LoopKit Authors, Degraeve, Plant), and every "carries no copyright header" claim matches
`vendor-ref/xdripswift` @ 7.1.0. micro-ecc (9 files + LICENSE) is byte-identical to xDrip4iOS's copy,
pinned at 541b3a7. A 3/4-line block comparison against xDrip4iOS, Trio (incl. G7SensorKit,
CGMBLEKit), Loop, dexcom-share-client-swift, LoopFollow and nightguard found no unattributed port.

### 5.4 Protocol bytes carry their source

G7Kit opcodes (`G7Opcode.swift:13-56`), characteristic UUIDs, slot bytes, timing and session
constants, Dexcom Share (`DexcomShareServer.swift:26-73`, `DexcomShareEGV.swift:43-100`), Nightscout
39/401 (`NightscoutGlucoseEncoding.swift:35-37`) and the Trio contract
(`TrioAppGroupContract.swift:11-46`, `TrioSharedReading.swift:20-39`) are all cited to file:line.
Only two bytes are uncited and both are explicitly not decoded (`G7BackfillMessage.swift:12`,
`G7ExtendedVersionMessage.swift:13`).

### 5.5 No Trio (AGPL) code copied

None. Block and long-line matching of TrioBridge, App, AlertEngine, NightscoutKit, G7Kit, WidgetCore
against `vendor-ref/Trio`: the only non-boilerplate match is `G7CRC16.swift:18-22` vs
`Trio/CGMBLEKit/NSData+CRC.swift`, which is LoopKit's MIT CGMBLEKit (a Trio submodule, not Trio's
AGPL code), reached here through the attributed xDrip4iOS port. No cgm-remote-monitor (AGPL) text in
NightscoutKit; LoopFollow/nightguard (AGPL) matches are generic one-liners.

### 5.6 NOTICE.md

Complete for code included (xDrip4iOS GPL-3.0, micro-ecc BSD-2-Clause, GRDB MIT), fonts (OFL with
licences in `Resources/Fonts/licenses/`), original sounds, and references (G7SensorKit, Juggluco,
xDrip+, Mbed TLS vectors, Loop, cgm-remote-monitor AGPL, share2nightscout-bridge GPL-3.0-only,
dexcom-share-client-swift, Trio AGPL). DiaBLE correctly absent (unused). Gaps (m7):
`NOTICE.md:22` lists CGMBLEKit/xDripG5 as "References (no code included)", but seven ported files
(`G7Opcode`, `G7AuthStatusMessage`, `G7AuthChallengeMessages`, `G7ChallengeHash`, `G7CRC16`,
`G7OwnershipMessages`, `G7AuthenticationSlot`) carry Racklyeft/LoopKit code that reached xDrip4iOS
from it — MIT requires its permission notice to ship; LoopFollow (AGPL-3.0), nightguard (AGPL-3.0) and
trio-oref are cited in comments (`NightscoutGlucoseEncoding.swift:26,29`, `TrioAppGroupContract.swift:40`)
but not listed.

---

## 6. What only the device can prove

Mapped to HANDOFF §11 steps (S = step) and the PROGRESS "§11 additions" (A = addition). These go
into `docs/setup.md`.

| Item | Why the gates cannot prove it | §11 |
|---|---|---|
| Replay on device: alerts audible with ringer off; Trio bridge and uploaders inert for replay (also: widget shows replayed values unlabelled, m9; accelerated replay UI reads "no current reading", m8) | audio routing, real notifications | S1 |
| Import spot-check vs Nightscout and Clarity, incl. history Trio uploaded with LOW/HIGH flattened to 40/400 (see S4) | real data | S1a |
| J-PAKE + certificates accepted by a real G7; iOS pairing prompt accept/cancel/timeout codes; warm-up length from `0x52`; first reading; 5-min cadence | live sensor | S2, A |
| Reading times match the receiver within seconds (S3 anchor), backfill after a 30+ min gap lands on the same ids; state-restoration relaunch reconnects; survives reboot (no glucose alerts before first unlock — `architecture.md:196-200`; notifications scheduled before the reboot still fire); force-quit banner | real BLE lifecycle | S3, A |
| Capture raw G7 LOW and HIGH packets (D31) before relying on HIGH → 401 in closed loop | no reference capture exists | S2–S5, A |
| Receiver slot 1 + app slot 2 side by side 24 h | slot semantics | S2/S3, A |
| Trio: values and timestamps in Trio (open loop, then closed); 39/401 handling; heartbeat keeps Trio looping locked 30+ min (DASH/Dana/Medtrum); Trio's "Upload Glucose" off (D22) | Trio is another process; same Team ID | S4, A |
| Widget lag measured and recorded in `docs/widgets.md`; stale/no-data transitions; DB writes while locked for hours (file protection, D25); WidgetKit with the clock set back 1 h | WidgetKit budget, data protection | S3a, A |
| Followers: each reading once in Nightscout within a minute; Nightscout "LOW" and LoopFollow alarming on 39 (D29); Dexcom Follow shows LOW/HIGH from 39/401 and alarms (D30) | servers we must not contact in tests | S4a, A |
| Urgent low as an AlarmKit alarm on silent and in Focus while suspended; repeats; Stop → acknowledge ≤ 30 min; 31 alarms at the 2-min floor; wake 30 s before / 3 s after a repeat; revoke alarm permission with repeats pending (D26/D34) | AlarmKit, system audio | S5, A |
| Urgent-low snooze end with the sensor out of range and quiet hours on (m2) — confirm the behaviour is what Michael wants | wake timing | S5 |
| Phone time changed manually during an urgent-low snooze (rollback detection, monotonic clock); time zone change; DST | real clocks | S5, A |
| Calibration round trip (`0x34`/`0x32`), display-only echo never shown as a reading; 15-day sensor refused; expired sensor keeps advertising | live sensor | S5, A |
| Another G7 app installed: unsolicited auth status not taken as ours; `otherAppRejected` surfaces; residual P1c (D35) | second app | S2, A |
| Full 10-day session + grace: missed readings/day, alert correctness, battery; expiry reminders on time while suspended, 24 h silent (D43); confirmed-end latch on the real end | time | S5 |
| Diagnostics export contains BLE transitions and bridge writes, nothing personal beyond readings | — | S6 |

---

## 7. Findings

### BLOCKER

None. No path lets a non-sensor, unauthenticated, invalid, fabricated or re-dated reading reach
storage, Trio, alerts or an uploader; no LOW/HIGH becomes a number outside D21/D29/D30; urgent low
cannot be disabled or snoozed past 30 minutes; every §2 S5 condition surfaces in the UI and, where
§5 lists one, as an alert.

### MAJOR

None.

### MINOR

Ordered by how much they matter. The first five should be closed (or decided) before the Phase 4
device build; m1 and m2 need a decision from Michael.

- **m1 — Readings held for a failing store are lost from history and uploads if the app is
  terminated; Phase 2 must-do "base backfill on the latest stored reading" is missing with no
  deferring decision.** `ReadingPipeline.swift:377-395` (in-memory `unstored`), G7Kit persists its
  newest-published mark as it yields (`G7Controller.swift:662-683`), acknowledged only in
  `architecture.md:201-205`. Scenario: disk full → D42 delivers readings to Trio and alerts and holds
  them in memory → iOS terminates the backgrounded app → those readings are never stored and never
  uploaded (uploads follow storage), and G7Kit will not re-request them. Followers see a permanent
  Nightscout/Share gap; the storage alert did fire. Record a D-entry accepting it, or persist the
  held readings / give G7Kit a backfill floor from the store.
- **m2 — An acknowledged urgent low re-sounds only on a fresh reading; its snooze end is not
  pre-scheduled.** `AlertEngine.swift:220-223`; `AlertEngine+User.swift:34-40` cancels every pending
  urgent-low notification/alarm on snooze. Scenario: 02:00 urgent low (50) acknowledged; from 02:05
  the phone is out of range; quiet hours on (D27 silences missed readings) or missed readings turned
  off. At 02:30 nothing sounds; urgent low returns only when a reading arrives. In range the delay is
  ≤ one G7 cadence (≤ ~35 min). Consistent with the documented rule ("snooze expiry re-fires only on
  a current reading", `docs/alerts.md`) and S1, but it differs from the firing case, where repeats
  continue on a stale value. Michael should confirm; the alternative is one pending urgent-low
  notification/alarm at snooze end, removed by a clearing reading.
- **m3 — `check.sh` never runs the Release-only S6 test.** `GlucoseAlertTests.swift:363-368`
  (`#else`): `test_S6_releaseBuildRefusesReplayReadings` compiles only without `DEBUG`; gate 2 runs
  `swift test` in debug. I ran it (release, passed). Scenario: an edit to `AlertEngine.rejection`'s
  `#else` branch (`AlertEngine.swift:136-138`) passes every gate; only the `nm` check on
  `validateAllowingReplay` would catch the specific case of calling the replay variant. Add
  `swift test -c release -Xswiftc -enable-testing --filter 'test_S[26]_'` for AlertEngine,
  GlucoseCore, TrioBridge and NightscoutKit to gate 3.
- **m4 — "Trio bridge write failure → alert" is not proven end to end in the app.** Each hop is
  tested (bridge status, `alertInput` for the no-App-Group case, engine `.writeFailing`), but the app's
  test store never fails (`AppTests/PipelineTestSupport.swift:138`, `checkAccess() {}`), so nothing
  drives a real write failure through `TrioCoordinator.start` (`TrioCoordinator.swift:60-69`) →
  `trioSummaryChanged` → `sendTrioAlertInput` (`LiveAppServices+Alerts.swift:97-108`) → alert.
  Scenario: a refactor drops the forwarding; Trio stops getting readings, a banner may show, no
  alarm; all gates pass. Add a failing `TrioSharedStore` and one pipeline-level test.
- **m5 — The D21 wiring has no behavioural test.** `TrioCoordinator.swift:50` sets `.writeSentinel`
  for both flags; no app test sends a LOW/HIGH through the pipeline and checks 39/401 in the
  payload, and the lint only checks that lines *containing* `.writeSentinel` cite D21. Scenario: the
  line is changed to `.doNotWrite` (or deleted, falling back to the package default) — lint and every
  test pass; during a long LOW Trio gets nothing, stops looping after 12 min and scheduled basal
  resumes, the very trade-off D21 chose against (the starvation alert fires at 15 min; S4 itself
  still holds).
- **m6 — The Nightscout importer can trap on a malformed page.** `NightscoutHistoryImporter.swift:242`
  `Int64(oldest.rounded(.down))` on a finite but out-of-range `date` (e.g. `-1e300`) in a full page
  crashes the app mid-import. Import only, never the live path. Bound it as `NightscoutEntry.swift:83-92`
  does, or `Int64(exactly:)` → `malformedResponse`.
- **m7 — NOTICE.md gaps.** `NOTICE.md:22` lists CGMBLEKit/xDripG5 as "no code included", but seven
  ported files carry Racklyeft/LoopKit code that came through it (`G7Opcode`, `G7AuthStatusMessage`,
  `G7AuthChallengeMessages`, `G7ChallengeHash`, `G7CRC16`, `G7OwnershipMessages`,
  `G7AuthenticationSlot`); its MIT notice must ship. LoopFollow (AGPL-3.0), nightguard (AGPL-3.0)
  and trio-oref are cited (`NightscoutGlucoseEncoding.swift:26, 29`, `TrioAppGroupContract.swift:40`)
  but not listed.
- **m8 — DEBUG accelerated replay: the UI judges replay readings on the phone clock** (must-do
  partial). `AppModel.swift:157` (`Date()`), Developer default 60× (`DeveloperSettingsView.swift:12`).
  Scenario (§11 step 1 on device): at 60× replay readings are minutes ahead of the phone within
  seconds; Now and the widget show "no current reading"/clock mismatch instead of the scenario.
  Fails loud, DEBUG only, but it defeats the UI check. Gate, store and alerts do use replay time.
- **m9 — DEBUG replay writes the widget snapshot with no replay marker.**
  `LiveAppServices+Replay.swift:53`; `WidgetSnapshot` has no source field. Scenario: during §11 step 1
  the Home Screen widget (at 1×; see m8 for faster runs) shows a replayed "48 ↓" indistinguishable
  from a real reading (the app shows the DEBUG banner; the widget does not).
- **m10 — Upload queues live in `Application Support/Uploads` (`AppEnvironment.swift:69`), not the App
  Group the must-do names.** Sound for the D25 reason, documented in `architecture.md`, but no
  D-entry.
- **m11 — The S8 attribution test covers G7Kit only.** `G7AttributionTests.swift:71`; the four
  NightscoutKit DexcomShare ports have no equivalent, so a lost header there would not be caught.
- **m12 — `StoreSchema` lacks the "never VACUUM" warning** the must-do asked for
  (`StoreSchema.swift:83-89` documents rowid ordering only; the table has no INTEGER PRIMARY KEY, so
  VACUUM may renumber rowids and change equal-date order).
- **m13 — Stale comments contradict D25.** `Config/Base.xcconfig:10` and
  `Config/Signing.example.xcconfig:10` say the SQLite database lives in the App Group; it is in
  Application Support. Misleads an S8 audit.
- **m14 — Hygiene nits.** `LiveAppServices.swift:177` `MainActor.assumeIsolated` has no justification
  comment (sound: `queue: .main` at `:175`); `RingBufferDiagnosticLog.swift:12` comment omits
  `hasLoadedSaved`, and two concurrent `save()` calls can persist an older snapshot last (diagnostics
  only); `G7ECCMath.swift:90, 96, 104, 111` force unwraps on fixed 32-byte buffers are safe but
  uncommented; `TrioCoordinator.swift:65` uses `Date()` instead of its injected clock.
- **m15 — G7 sensor-time order across a relaunch is checked only against the persisted newest
  mark.** `G7ReadingPipeline.swift:127` seeds `published` with one mark; the type comment
  (`:33-34`) claims the rule "also holds across relaunches". Scenario: the phone clock changes, the
  new process re-anchors after two agreeing anchors, then a backfill record for a never-published
  sensor time before the persisted newest arrives; it is dated with the new anchor and can be stored
  (and offered to Trio) about the clock change away from its stored neighbours. Ids still dedupe and
  alerts never evaluate backfill. Fix the comment or persist the mark per anchor.
- **m16 — AGP: a LOW/HIGH percentile is drawn at the chart floor/ceiling with no visual label**
  (`TrendsCharts.swift:47-111`; carry-over). A p95 line along the top edge reads as a measured 400.
  VoiceOver says HIGH correctly; S4 holds in data (`test_S4_agpHighPercentileIsDrawnAboveEveryNumber`).
- **m17 — Trends 1 D/3 D overlays are an hour off their axis labels on DST days.**
  `TrendsCharts.swift:12-17` plots elapsed hours since local midnight; on a fall-back day readings
  after 01:00 sit one hour right of their clock time, and the 3 D overlay compares days an hour
  apart. Display only; stored timestamps are correct; the caveat is in a code comment, not the UI.
- **m18 — Untested wiring and open carry-overs.** Not proven by any test: the foreground/60 s Trio
  retry (`LiveAppServices.swift:654, 684`), credentials → flush and the `.alreadyFlushing` repeat
  (`UploadCoordinator.swift:251-262`), the `rejectedFutureDated` display, the uploader `deviceName`.
  `test_S5_trioLaunchHoldIsReleasedAfterTwoMinutes` asserts only `.contains(118)`, so it would not
  notice the payload's newest going backwards (the carry-over at `TrioCoordinator.swift:98-101, 122-128`;
  Trio dedupes by timestamp, low impact). Still open: `AlertEngine.sanitized` does not check
  `knownSession.isWellFormed` (`AlertEngine.swift:40-52`, reminder dates only); the latch compound
  case (`ClockMismatchMonitor.swift:53-75`); held-back count not shown in Settings.

## 8. Resolution of the findings (Phase 3 follow-up)

Orchestrator's record of what happened to each finding above. Each fix was reviewed again before it
was merged (PROGRESS.md phase log); commit hashes are on the Phase 3 branches merged in `p3-stage`.

| Finding | Resolution |
|---|---|
| m1 held readings lost on termination | G7Kit publication floor from the latest stored reading (`G7CGMSource.setLatestStoredReading`, 07853e6), wired from the production store (0640500). The G7 has no backfill request; recovery covers records the sensor resends (device check). |
| m2 acknowledged urgent low silent after snooze | D44: the snooze-end alarm and its repeats are pre-scheduled (fb3863c); D51: a 56–60 reading at snooze end hands over to Low (638db66). |
| m3 Release-only S6 test never ran | `check.sh` gate 3 runs the S2/S6 suites in Release and requires `test_S6_releaseBuildRefusesReplayReadings` (23efa63); `check-selftest.sh` plants a Release-only failure (59c0266). |
| m4 Trio write failure not proven end to end | Hosted test with a failing App Group (ea5c2b9). |
| m5 D21 wiring untested | `test_S4_lowAndHighReachTrioAs39And401` through `TrioCoordinator` (ea5c2b9). |
| m6 importer `Int64` trap | Fail closed on malformed pages; upload-queue date guard (9eb1ec8); future-dated queued readings held, not discarded (01b58b8). |
| m7 NOTICE gaps | CGMBLEKit lineage headers + `licenses/CGMBLEKit-LICENSE` (07853e6); NOTICE.md rows (ee81c64, c2922c8). |
| m8 replay UI clock | DEBUG replay clock for the UI (fbb1433). |
| m9 widget replay marker | DEBUG-only `WidgetSnapshot.isReplay` + "REPLAY" (22d866b). |
| m10 queue location undocumented | D48. |
| m11 Share-port attribution untested | `NightscoutAttributionTests` (9eb1ec8). |
| m12 VACUUM warning | `StoreSchema` comment (ea5c2b9). |
| m13 config comments vs D25 | Fixed (23efa63). |
| m14 hygiene nits | `assumeIsolated` justification, injected clock in `TrioCoordinator` (ea5c2b9); `G7ECCMath` comments (07853e6); diagnostics privacy text (23efa63, 22d866b). |
| m15 ordering comment overclaims | Comment matches the code (07853e6). |
| m16 AGP LOW/HIGH unlabeled | HIGH/LOW markers (fbb1433). |
| m17 DST overlay offset | Wall-clock overlay, lines split at the change (22d866b). |
| m18 untested wiring | Trio retry, flush after credentials, `deviceName`, future-dated import count tests (ea5c2b9, 22d866b). Found and fixed on the way: no Nightscout uploader existed after a launch until a setting changed (`test_S5_savedNightscoutSettingsUploadAfterALaunch`). |

New in Phase 3 after this audit: listen mode (D45, D49, D50) and raw packet recording (D47), each with
its own independent review; see `docs/g7-protocol.md` §14 and the device checks in §13.
