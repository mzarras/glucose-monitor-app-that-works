# Predictions (Zen Predict feed)

The **Predict** tab shows forecasts from Michael's own blood-glucose model, Zen Predict (PROGRESS
D57). Every 5 minutes a `predict` Lambda forecasts his glucose at +5, +30, +60 and +120 minutes and
a `publish` Lambda writes public JSON feeds to S3 behind CloudFront. **There is no new API and no
new AWS resource:** the static feed is the API. `Packages/ForecastKit` fetches, validates and
classifies it; the app's Predict UI is built on top of ForecastKit's public API (end of this page).

Producer references are to `zen-predict-infra` at `3f3d682` (lambdas, terraform) and `zen-predict`
at `0d13ce3` (the model), both read-only.

## What the app must never do with a forecast (D57)

A forecast is a prediction, not a measurement. S1 and S6 apply to it:

- **Never a reading.** Forecasts live in their own types in `ForecastKit`, which has **no
  dependencies** (not even GlucoseCore), so it cannot build a `GlucoseReading` and its types cannot
  be passed where a reading is expected.
- **Never stored.** No persistence and no disk cache (the URL session is ephemeral with no URL
  cache). The app keeps the last document in memory only.
- **Never the current value.** Not on the Now screen, not in the widget, not as a number anywhere
  but the Predict tab.
- **Never sent** to Trio, the alert engine, Nightscout/Dexcom Share uploads, or the widget. **No
  model-driven alerts** (HANDOFF §5: alerts come from readings, never a model).
- **Always labelled** as predicted, with the model-run time (`ForecastRun.generatedAt`).
- **Hidden when stale:** a run older than 15 minutes, by the phone's clock or by the real time since
  its document arrived, shows an "out of date" message, never its values. The values are reachable
  only through `LatestForecast.currentRun(at:)`, which returns nil unless the run is current.
- **Rejected whole** when malformed or future-dated: nothing from a rejected document is shown.
- **oref values have no time** (see below): never label them with the Zen run's time.

### Enforcement

`scripts/check.sh` (safety gate, "D57 forecast isolation"; `scripts/check-selftest.sh` plants a
breach of each rule and an allowed importer as a negative control) fails unless:

- **Manifest.** `Packages/ForecastKit/Package.swift`, as SwiftPM reads it (`swift package
  dump-package`), has exactly the targets `ForecastKit` (regular) and `ForecastKitTests` (test), no
  package dependencies, no target dependency except `ForecastKitTests` → `ForecastKit`, and no
  `unsafeFlags`, linked libraries, linked frameworks or plugin usages. A `binaryTarget`,
  `systemLibrary` or `plugin` target is another target type and fails "exactly".
- **Foundation only.** Every import in `Packages/ForecastKit/Sources` is of Foundation.
- **Who may name ForecastKit.** The allowlist: files under `App/` whose name starts with `Forecast`
  or `Predict` or ends with `+Forecast.swift` or `+Predict.swift`; anything under
  `App/Sources/Screens/Predict/`; `AppTests/` and `AppUITests/`; and `Packages/ForecastKit/` itself.
  A deny list is applied first and wins over those names: `App/Sources/Pipeline/`,
  `App/Sources/WidgetBridge/`, `App/Sources/Intents/`, `App/Sources/Screens/Now/`,
  `App/Sources/ViewState/Now*`, `App/Sources/Composition/AlertPorts*`, and under
  `App/Sources/Services/` anything named `TrioCoordinator*`, `UploadCoordinator*`, `*Widget*` or
  `*Alert*`, and `Widgets/`. Outside the allowlist, **any Swift file under `App/`, `Widgets/` or
  `Packages/` that contains the word `ForecastKit` anywhere** (code, comment or string; any line
  endings) fails, named with its lines. That backstop is what makes the check fail-safe; the import
  matcher adds a precise "imported outside its allowlist" message for the imports it parses.
- **No `@_exported`.** Any `@_exported` in a file under `App/`, `Widgets/` or `Packages/` fails,
  found as raw text (no parsing): it would make a module's names visible in every file of the
  module that imports it.
- **Linkage.** `project.yml` as XcodeGen resolves it (`xcodegen dump`, so includes, YAML anchors and
  aliases, escapes and target templates are resolved): only the targets `Sensor`, `SensorTests` and
  `SensorUITests` may depend on the ForecastKit package (under any `packages:` key whose entry names
  it) or name it; nothing else outside `packages:` may name it. If XcodeGen cannot resolve the spec,
  the check fails. No other package manifest names ForecastKit.
- **Nothing vacuous.** A missing or Swift-free scan root (`App/`, `Widgets/`, `Packages/`), a
  missing `project.yml`, and a matcher that finds no import in ForecastKit's own sources each fail.

The import matcher normalises CRLF and CR-only line endings, reads each file twice (as written and
with `//` and `/* */` comments removed), and handles attributes (`@testable`, `@_spi(…)`,
`@preconcurrency`, `@_implementationOnly`), access modifiers (`internal import`), import kinds
(`import struct ForecastKit.X`), backticks, several statements on a line (`;`), trailing comments
and a declaration split over lines. It is not proof against a string holding `//` or `/*` combined
with a comment between the tokens (`let s = "//"; import/**/ForecastKit`); the backstop is.

**What it cannot see:** the import rules keep ForecastKit's names out of other files, but an allowed
file can still hand a forecast value to other code in the same module (e.g. through a property of
an app type). That stays a review rule: nothing outside the Predict UI may take a forecast value.

## The feed

Two documents at the feed host's root, `https://<host>/latest.json` and `https://<host>/metrics.json`
(publish.py `LATEST_KEY`, `METRICS_KEY`). The host is a bare host name: the build setting
`ZEN_PREDICT_FEED_HOST` in the gitignored `Config/Signing.xcconfig`, editable in Settings ›
Predictions. The real host lives only there; this page and the tests use `zen.example.com`.

The key sets are pinned by allowlists in publish.py: `LATEST_CONTRACT`, `METRICS_CONTRACT`,
`_WINDOW_CONTRACT`, `_HORIZON_MAP`. `filter_doc` writes every contract key on every run, **absent
values as `null`**, so any leaf may be null. Horizons are the string keys `"5"`, `"30"`, `"60"`,
`"120"` (`LATEST_HORIZONS`).

### latest.json

In the live format, with synthetic values (the test fixture `synthetic_latest_live_format.json`):

```json
{"as_of":"2026-10-08T14:20:41.507318+00:00",
 "bg":{"ts":"2026-10-08T14:20:05.112233+00:00","mg_dl":108,"trend":"FortyFiveUp"},
 "predictions":{"generated_at":"2026-10-08T14:20:05.112233+00:00",
                "zen":{"5":110.42,"30":127.06,"60":141.93,"120":152.37},
                "oref":{"5":111,"30":129,"60":146.5,"120":160}},
 "model_version":"20261001T000000-0f0f0f0f"}
```

| Key | Meaning (publish.py `build_latest`) | ForecastKit |
|---|---|---|
| `as_of` | when publish ran | `LatestForecast.asOf` (required) |
| `bg` | newest Nightscout entry at publish time (`_current_bg`: `ts`, `int(sgv)`, `direction`) | `feedGlucose: FeedGlucose?`, informational |
| `predictions.generated_at` | newest **live** Zen run = the timestamp of the CGM reading it ran on (predict.py writes `target_time = generated_at + horizon`) | `zenRunTime`; `ForecastRun.generatedAt` |
| `predictions.zen` | that run's predicted mg/dL per horizon, two decimals (predict.py `round(…, 2)`) | `currentRun(at:) -> ForecastRun?`, nil unless current |
| `predictions.oref` | Trio's oref forecast: per horizon, the median of its predBG scenario curves (zen-predict `oref_points.median_curve`) | `oref` (internal: not in v1, see below) |
| `model_version` | the model that made the Zen run | `modelVersion` |

**oref has no published time.** `build_latest` selects oref's newest archived run by oref's own
`generated_at` (the Trio loop time, archived from Nightscout devicestatus by the score Lambda) and
publishes only its values. That run is not the Zen run, and it can be as old as the 48 h history
window (`HISTORY_WINDOW_HOURS`). `OrefForecast` therefore carries no date at all, and
`LatestForecast.oref` is internal: the app cannot reach these timeless, ungated values, and v1 does
not show oref (D58 (3)). It becomes public, with its own freshness, once the feed publishes
`oref_generated_at` (S3: timestamps are derived, never assumed). See Open items.

**`bg.mg_dl` is a Nightscout `sgv`,** which encodes the sensor's flags as numbers: 39 = LOW,
above 400 = HIGH, below 39 = a Dexcom error code (cgm-remote-monitor 15.0.8 `lib/sandbox.js:248-256`,
`lib/client/index.js:540-549`, `lib/plugins/errorcodes.js:13-22`; this app uploads LOW as 39 and
HIGH as 401, D29). `FeedGlucoseValue` keeps them as `.belowRange`, `.aboveRange`, `.notGlucose(code:)`
and never as `.mgdl(39)`/`.mgdl(401)` (S4).

### metrics.json

`windows."7d"` and `windows."30d"` (`METRICS_WINDOWS`), each with per-horizon `mae`,
`persistence_mae` (error of "no change", the baseline to beat), `win_rate_vs_oref` (fraction 0–1),
plus `n` (scored runs) and `parkes_ab_pct` (% in Parkes zones A+B). They aggregate the daily
rollups of **every** Zen model version in the window, weighted by `n` (`_window_stats`). The
deployed model publishes point forecasts only (no intervals), so the Predict tab shows the
**7-day MAE per horizon as the "typical miss"**: `ForecastAccuracy.typicalMiss(at:)`.

### Timestamps

`FeedTimestamp` parses `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)` by hand (every rule visible and
tested): the live feed's Python `isoformat()` (`…05.112233+00:00`, and `…05+00:00` when the
microseconds are 0), the site fixtures' `…T12:03:00Z`, fractions of any length, any `±HH:MM`
offset. Impossible dates and times (30 February, hour 24, second 60) are refused.

## Validation

`ForecastFeedDecoder.decodeLatest(_:at:)` / `decodeAccuracy(_:at:)` accept or reject a whole
document; a rejection is a `ForecastDocumentError` naming the JSON path. Nothing from a rejected
document is used, and the client forgets its remembered copy so the next request is unconditional.
`at` is a `ForecastInstant` (the phone's wall clock and a monotonic clock, read together): the
client passes `ForecastInstant.now()` when the response arrives. The wall clock judges
"future-dated"; the accepted document is stamped with the whole instant, from which its run's age
is later measured (Freshness).

| Rule | Error | Why |
|---|---|---|
| Body is a JSON object | `notAJSONObject` | An HTML error page, an array, or Python's bare `NaN`/`Infinity` (which `json.dumps` writes by default) are not a feed. Foundation refuses `NaN`, `Infinity` and `1e400` as JSON. |
| Every known key has its JSON type | `wrongType(field:)` | A changed producer must not be half-read. Numbers too large for Swift (e.g. `-1e400`) land here as `(document)`. |
| `as_of` present | `missingField("as_of")` | The only required key: without it the document's age is unknown. |
| Every timestamp parses | `unparseableTimestamp(field:text:)` | |
| No timestamp later than now + 2 min | `futureDated(field:)` | A future-dated forecast would look fresh for longer than the 15-minute rule allows (S1). |
| `generated_at`, `bg.ts` no later than `as_of` + 2 min | `laterThanAsOf(field:)` | A document cannot contain a run or a reading from after it was written. |
| Values have their time | `valueWithoutTimestamp(field:)` | Zen values with a null `generated_at`, or `bg.mg_dl` with a null `bg.ts`, cannot be placed in time; the producer never writes them, so they mean a fault. |
| Zen values finite, **20…600 mg/dL** | `implausibleForecast(field:value:)` | The model clips to 40–400 (zen-predict `model.py:34-35`, `_clip` `:54-55`), so outside it the clip was bypassed. The margin lets a deliberate clip change pass; 20–600 is a blood-glucose meter's measuring range, so outside it is not glucose. Also catches unit faults: mmol/L values below 20 and a doubled conversion (40 × 18 = 720). |
| oref values finite, **39…1500 mg/dL** | `implausibleForecast(field:value:)` | Exactly oref's own clamps (Trio `determine-basal.js:995, 1005, 1030`: 39–401; COB curve `:1016`: 39–1500). At long horizons the median can be the COB curve alone, so up to 1500 is a genuine oref output. |
| `bg.mg_dl` finite, 0…1000 | `implausibleFeedGlucose(value:)` | NightscoutKit's `maximumPlausibleSGV`. |
| `mae`, `persistence_mae` 0…600; `win_rate_vs_oref` 0…1; `parkes_ab_pct` 0…100; `n` ≥ 0 | `implausibleMetric(field:value:)` | Each is a mean error, a fraction or a percentage (`_window_stats`). |

**Null means "not published", not an error:** a null horizon is no point; a null or all-null `zen`
(also with `generated_at` set) is "no forecast yet" (`zen == nil`); null `oref`, `bg`, `trend`,
`model_version`, windows or metrics are nil. A missing key counts as null. **Unknown keys are
ignored** (a new horizon, a new top-level key), so the producer can add fields without breaking
the app.

The 2-minute clock-skew tolerance (`ForecastLimits.clockSkewTolerance`): the feed's times come from
other clocks (the Lambda for `as_of`, the uploading device for `generated_at` and `bg.ts`).
NTP-synced clocks agree to well under a second; 2 minutes absorbs a badly set clock while staying
under one CGM interval. What it bounds: **if the phone's clock was right when the document
arrived**, a run can look up to 2 minutes younger than it is (an uploader clock up to 2 minutes
fast), so it can stay current up to 2 minutes beyond the 15-minute rule. Changing the phone's clock
after the document arrived does not extend that (the monotonic clock, below). A phone clock that was
already slow when the document arrived does, by as much as it was slow, for runs that still passed
the future-dated check; nothing in the feed can detect that (see Open items).

## Freshness: the 15-minute rule

The wall clock alone is not enough. If the phone's clock is set back after a document arrived,
newer documents are refused as future-dated, the app keeps the old one, and by the wall clock its
run looks younger than it is: set back 10 minutes at a real age of 14 minutes, it would read
"current" until a real age of 25 minutes. So a run's age is measured two ways and the larger counts
(`ForecastFreshness`, pure, both instants injected):

    age = max(now.wall − generatedAt,
              (receivedAt.wall − generatedAt) + (now.monotonic − receivedAt.monotonic),
              0)

The second term is the run's age when its document arrived plus the real time since, on Darwin's
`CLOCK_MONOTONIC_RAW`, which ignores changes to the time and keeps counting while the phone sleeps
(the clock the app's own clock-mismatch check uses; `ProcessInfo.systemUptime` stops during sleep).
Setting the clock back cannot lower the age; setting it forward raises the first term, so the run
goes stale early, which errs safe.

`LatestForecast.zenFreshness(at:)`:

- `.current(age:)` — age ≤ 15 min (exactly 15 min is still current).
- `.stale(age:)` — age > 15 min: show "out of date" with `zenRunTime`, not the values. Also when the
  monotonic clock went backwards, which cannot happen within one boot (documents live only in
  memory) but would leave the age unknown.
- `.aheadOfClock(by:)` — the run is more than 2 min ahead of the phone's wall clock (only possible
  if the clock was set back after the document arrived): treated like stale.

`LatestForecast.currentRun(at:)` returns the Zen run only when it is current; it is the only way to
the run's values. `zenRunTime` and `zenRunAge(at:)` (the age above) serve "last model run … ago".
A **304 keeps the document's original receipt instant**: re-stamping it at the 304 would restart its
age from a clock that may have been set back. 15 minutes matches the predict Lambda's own
`STALE_CGM_MINUTES = 15.0` (predict.py:55), above which it makes no run: when the sensor or
Nightscout goes quiet, the forecast goes "out of date" within 15 minutes. **Freshness changes with
time, not only with fetches**: the UI evaluates it when it draws and at least once a minute, so a run
goes "out of date" even while every fetch is failing.

Predicted values at the model's clip edges are bounds, not numbers (the forecast analogue of S4):
`ForecastPoint.modelBound` is `.atOrBelowFloor` at ≤ 40 mg/dL, `.atOrAboveCeiling` at ≥ 400, else
`.within` (zen-predict `model.py:34-35` clips to 40–400). The Predict tab shows "≤40"/"≥400" from
it, never by comparing numbers (D58 (4)).

## Polling (the app owns the timers)

`ForecastPolling`, pure functions:

- Fetch **only while the app is in the foreground**: immediately on entering it, then
  `delayBeforeNextLatestPoll(consecutiveFailures:)` — **60 s** normally; after 1, 2, 3+ consecutive
  failures **60 s, 120 s, 300 s**; back to 60 s after any success (a 304 is a success).
  `ForecastFeedError.cancelled` is not a failure: it does not count and is not shown.
- `metrics.json` with a latest poll when `isMetricsFetchDue(lastSuccessfulFetch:now:)`: never
  fetched, or **30 minutes** since the last success (or the clock moved back). A failed metrics
  fetch retries with the next latest poll.
- Conditional requests: the client sends `If-None-Match` with the ETag CloudFront passed through
  from S3, and a **304** (empty body) returns the document it validated earlier. Verified against
  the live host: `If-None-Match: "<etag>"` → `HTTP/2 304`, `x-cache: Hit from cloudfront`.

Requests: `GET`, `Accept: application/json`, 10 s overall timeout, no cookies, no credentials, no
URL cache, **redirects refused** (a 3xx is reported as `httpStatus`, so a misconfigured host shows
an error instead of following to another host), **bodies over 512 KiB refused** (by `Content-Length`
or while reading; the real documents are 330 and 540 bytes). **One request per URL at a time**: a
fetch that starts while another for the same document is in flight waits for it and gets its result,
so overlapping polls cannot return an older document after a newer one or bring back a document
after a rejection. Cancelling a caller cancels that shared request; a caller that arrives after
that does not join it, but waits for it to unwind and sends its own. The transport owns its
`URLSession` and invalidates it when released (a new host in Settings means a new client).

Errors: `ForecastFeedError.transport` (no usable response, including an oversized body),
`.httpStatus(Int)` (non-2xx, non-304; CloudFront answers 403 for a missing object),
`.notModifiedWithoutCachedValue`, `.invalidDocument(ForecastDocumentError)`, `.cancelled` (the
caller's task or URLSession cancelled the request; not a failure).

Feed host (`ForecastFeedEndpoint`): a bare host or `https://host[/]`, lower-cased; refused if it has
another scheme, credentials, a query or fragment, a path or a port, or is not an ASCII DNS name of
at least two labels whose last label is letters only (checked on the UTF-8 bytes). **IP addresses
are refused** (`192.168.1.10`, `999.999.999.999`, `0`), as are single labels such as `localhost`.
The displayed `host` is exactly the host of the two URLs the client contacts.

## Latency

Since zen-predict-infra `3f3d682` (deployed 2026-10-08 19:16 UTC), predict invokes publish
asynchronously right after it writes a new live forecast (predict.py `_trigger_publish`), and the
scheduled publish skips itself when a predict-triggered publish wrote `latest.json` within 330 s
(publish.py `_triggered_publish_is_recent`, `TRIGGERED_PUBLISH_FRESH_SECONDS`). The 5-minute
publish schedule remains the fallback (sensor gaps, a failed trigger).

| Step | Time |
|---|---|
| Reading reaches Nightscout (from the uploading phone) | seconds |
| Next predict tick (`rate(5 minutes)`, terraform/main.tf) | 0–5 min wait |
| Predict run + triggered publish | ≈ 5–15 s |
| CloudFront edge cache (`*.json` 30 s TTL) | 0–30 s |
| **Feed public after the reading** | **typically ≈ 1–3 min, worst case ≈ 5.5 min** |
| App poll interval while open | + 0–60 s |

Measured on 2026-10-08 after the change: forecasts public 11 s and 6 s after the CGM reading they
ran on (baseline before the change: ≈ 5.5 min). A capture before the change showed the old lag:
published at 18:56:48 with the 18:56:13 reading, but the newest run was still the one on the
18:51:14 reading (the synthetic fixture `synthetic_latest_lagging_run.json` has that shape).

## Cost

No new AWS resources: the app reads the feed the dashboard already publishes. While the app is in
the foreground it makes one small request a minute (mostly empty 304s) plus one metrics request per
30 minutes: even with the app open 24 hours a day that is about 45,000 requests a month, under 1%
of CloudFront's always-free tier of 10,000,000 requests and 1 TB out per month
(https://aws.amazon.com/cloudfront/pricing/). Edge misses go to S3 at most once per 30 s per edge.
Nothing is fetched in the background.

## API for the Predict UI

All types are `Sendable`; values are created only by `ForecastFeedDecoder`, so every instance has
passed validation (previews and tests decode JSON strings with `ForecastFeedDecoder`).

```swift
// Settings › Predictions
let endpoint = try ForecastFeedEndpoint(userInput)   // ForecastEndpointError.description for the form
// Bare host or https://host[/]; refuses http://, credentials, query/fragment, path, port, IP, bad host.

let client = ForecastFeedClient(endpoint: endpoint)  // transport: URLSessionForecastTransport(), now: ForecastInstant.now
let latest: LatestForecast = try await client.fetchLatest()       // throws(ForecastFeedError)
let accuracy: ForecastAccuracy = try await client.fetchAccuracy() // throws(ForecastFeedError)
// .cancelled is not a failure: don't count it toward backoff or show it.

// Timers
ForecastPolling.delayBeforeNextLatestPoll(consecutiveFailures: n) // 60, 60, 120, 300…
ForecastPolling.isMetricsFetchDue(lastSuccessfulFetch: date, now: now)

// Display (evaluate at draw time and at least every minute)
let now = ForecastInstant.now()      // both clocks; tests build ForecastInstant(wall:monotonic:)
if let run = latest.currentRun(at: now) {
    for point in run.points {        // ascending horizon, null horizons absent
        point.horizon                // .fiveMinutes, .thirtyMinutes, .oneHour, .twoHours
        point.modelBound             // .atOrBelowFloor → "≤40", .atOrAboveCeiling → "≥400"
        point.predictedMgdl          // Double as published; round for display when .within
        run.targetDate(for: point.horizon)
        accuracy.typicalMiss(at: point.horizon)   // 7-day MAE, mg/dL, or nil
    }
    run.generatedAt                  // "predicted at …" label
} else if let runTime = latest.zenRunTime {  // "out of date", with the model-run time runTime
    latest.zenFreshness(at: now)     // .stale(age:) / .aheadOfClock(by:)
    latest.zenRunAge(at: now)        // conservative age, for "last model run N min ago"
} else {
    // no forecast yet
}
// oref: internal until the feed publishes oref_generated_at (then public, with its own freshness)
latest.feedGlucose                   // informational; .value is FeedGlucoseValue (LOW/HIGH as flags)
latest.modelVersion, accuracy.sevenDays?.accuracy(at:), accuracy.thirtyDays, …
```

## Tests

`Packages/ForecastKit/Tests/ForecastKitTests`, no network: the client runs against an in-process
transport, and the real `URLSessionForecastTransport` against a `URLProtocol` stub (including a
real redirect, with a control that a plain session would follow it). Fixtures: zen-predict-infra's
sample documents `site/fixtures/{latest,metrics}.json`, and synthetic documents in the live feed's
exact format (no real glucose values or hosts are committed). Concurrency tests hold requests in a
gated transport and answer them out of order; clocks are moved by hand (`TestClock`), never slept.

Safety tests: `test_S1_staleRunIsNeverCurrent`, `test_S1_currentRunIsNilOnceTheRunIsStale`,
`test_S1_runAheadOfThePhonesClockIsNeverCurrent`, `test_S1_clockSetBackDoesNotMakeAnOldRunCurrent`
(set back 10 and 60 minutes), `test_S1_monotonicClockGoingBackwardsIsNeverCurrent`,
`test_S1_notModifiedAfterTheClockIsSetBackKeepsTheRunsAge`, `test_S1_futureDatedFeedIsRejected`,
`test_S1_implausibleForecastRejectsWholeDocument`, `test_S1_forecastValuesWithoutTheirRunTimeAreRejected`,
`test_S1_rejectedDocumentIsNeverServedLater`, `test_S1_rejectedDocumentIsNeverServedLaterWhenFetchesOverlap`,
`test_S1_overlappingFetchesNeverReturnAnOlderDocumentAfterANewerOne`,
`test_S3_orefForecastIsNotGivenTheZenRunTime`, `test_S4_feedLowAndHighAreFlagsNotNumbers`,
`test_S4_forecastAtTheModelsClipIsABoundNotANumber`.

## Open items

- **oref run time.** Adding `predictions.oref_generated_at` to publish.py's `LATEST_CONTRACT`
  would let the app show oref with its own time and freshness; until then oref is untimed.
- **A phone clock that is already wrong.** The monotonic clock covers a clock changed after a
  document arrived, not one that was slow when it arrived. The response's HTTP `Date` header
  (CloudFront's clock) could stand in for the phone's wall clock at receipt; not done.
