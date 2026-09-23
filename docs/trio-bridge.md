# Trio bridge

How this app hands readings to Trio, what Trio does with them, and how to set both apps up.
Code: `Packages/TrioBridge`. Handoff: §8, §8A.

**Short version.** Trio's existing **"xDrip4iOS"** CGM source reads this app's readings unchanged.
No Trio patch is needed. In Trio, select **Settings → Devices → CGM → Add CGM → xDrip4iOS**, and turn
**Settings → Services → Nightscout → Upload → Upload Glucose** off so only this app uploads CGM
readings to Nightscout. One decision is still open: whether LOW and HIGH readings reach Trio (see
[LOW and HIGH](#low-and-high-s4)). Until Michael decides, they don't.

## Sources

Trio is AGPL-3.0. It was read to learn the contract; no Trio code is copied into this repository.
Citations are `path:line` in these read-only checkouts under `vendor-ref/`:

| Checkout | Version | Role |
|---|---|---|
| `Trio` | `mzarras/Trio` `main` @ `29350e31a` (v0.8.4) | the reader |
| Trio submodules `Trio/LoopKit`, `Trio/G7SensorKit` (@ `0c87905`), `Trio/dexcom-share-client-swift` (@ `875faf2`) | as checked out by Trio | LoopKit types, Trio's native G7 and Share paths |
| `Trio/trio-oref/lib`, bundled as `Trio/Trio/Resources/javascript/bundle/*.js` | oref0 `dev` @ `8282ce7` (`Trio/oref0_source_version.txt:1`) | the algorithm that doses on the readings |
| `xdripswift` | 7.1.0 @ `0370937` | the established writer of the same contract |
| `cgm-remote-monitor` | 15.0.8 | Nightscout, for LOW/HIGH codes and entry dedupe |
| `share2nightscout-bridge` | v0.2.12 | Dexcom Share field conventions |

Short names such as `AppGroupSource.swift`, `FetchGlucoseManager.swift`, `GlucoseStorage.swift`, `APSManager.swift`
are Trio files under `Trio/Trio/Sources/`; the full path is given at first use. `determine-basal.js`, `cob.js`,
`autosens.js` are under `Trio/trio-oref/lib/determine-basal/` (the bundled copies contain the same checks).

## App Group ID (D2, verified)

| Step | Where | Value |
|---|---|---|
| Trio defines it | `Trio/Config.xcconfig:16-18` | `TRIO_APP_GROUP_ID = group.org.nightscout.$(DEVELOPMENT_TEAM).trio.trio-app-group`, "should not be modified" |
| Trio's team | `Trio/Config.xcconfig:7, :26-29`; `Trio.xcodeproj/project.pbxproj:5200` | `DEVELOPMENT_TEAM = $(DEVELOPER_TEAM)`, set in `ConfigOverride.xcconfig` |
| Build setting | `Trio.xcodeproj/project.pbxproj:5059` (Debug), `:5127` (Release); also `:5188`, `:5234` | `APP_GROUP_ID = "$(TRIO_APP_GROUP_ID)"` |
| Info.plist | `Trio/Trio/Resources/Info.plist:5-6` | `AppGroupID = $(APP_GROUP_ID)` |
| Entitlement | `Trio/Trio/Resources/Trio.entitlements:17-20` | `$(APP_GROUP_ID)` |
| Reader | `Trio/Trio/Sources/APS/CGM/AppGroupSource.swift:34-35, :122-125` | `UserDefaults(suiteName: Bundle.main.object(forInfoDictionaryKey: "AppGroupID"))` |
| xDrip4iOS, same string | `xdripswift/xdrip.xcodeproj/project.pbxproj:5987, :6016`; `xDrip/xdrip.entitlements:14`; `xDrip/Supporting Files/Info.plist:7-8` | `group.org.nightscout.${DEVELOPMENT_TEAM}.trio.trio-app-group` |
| This app | `Config/Base.xcconfig:16`, `Config/Signing.example.xcconfig:14` | `TRIO_APP_GROUP_ID = group.org.nightscout.$(DEVELOPMENT_TEAM).trio.trio-app-group` |
| | `App/Info.plist:31-32` | `TrioAppGroupID = $(TRIO_APP_GROUP_ID)` (its own `AppGroupID`, `:5-6`, is `group.com.mzarras.sensor`) |
| | `App/Sensor.entitlements:8`, `App/Sensor+CriticalAlerts.entitlements:8` | `$(TRIO_APP_GROUP_ID)` |

The Release build of this app (gate 1) expands `TrioAppGroupID` to
`group.org.nightscout.<10-character team>.trio.trio-app-group`. It only matches Trio's group if both apps
are signed by the same team; nothing in either app can detect a mismatch (writes would land in a group
Trio does not read), so check it on device (see [Setup](#setup)).

The app passes `TrioAppGroupID` to `AppGroupUserDefaultsStore(appGroupID:)`. Before every write the store
refuses a malformed ID (not `group.org.nightscout.` + 10 upper-case letters/digits + `.trio.trio-app-group`,
for example an empty or unexpanded team) and a group the OS gives this app no container for (missing
entitlement). Without that check `UserDefaults(suiteName:)` still succeeds and writes to a private suite
Trio never sees.

## How Trio reads the key

`AppGroupSource.fetch` (`AppGroupSource.swift:33-41`) opens the suite and calls `fetchLastBGs(60, …)`
(`:47-102`):

1. `sharedDefaults.data(forKey: "latestReadings")`; missing → no readings (`:48-50`).
2. `JSONSerialization.jsonObject`; anything other than a top-level array → no readings (`:54-57`).
3. Only the first **60** elements are considered (`:61`). The writer therefore puts the newest first.
4. Per element (`:62-99`):

| Key | Type Trio requires | Trio's handling | Written by this app |
|---|---|---|---|
| `Value` | JSON number that bridges to `Int` (`:63`) | mg/dL, whatever Trio's display unit; becomes `sgv`, `glucose`, `unfiltered` (`:87-98`). A non-integral number fails the cast and the element is **skipped silently**. | integer mg/dL |
| `DT` | String `/Date(<ms since 1970>)/` (`:64-65`) | the greedy `\((.*)\)` group is passed to `Double(…)!` (`:104-115`). No parentheses → element skipped. **Parentheses around anything but a number crash Trio** (force unwrap), e.g. Dexcom Share's `/Date(1426292016000-0700)/` offset form (`share2nightscout-bridge/index.js:235`). | `/Date(<integer ms>)/`, digits only |
| `direction` | String, read first (`:71-72`) | stored via `BloodGlucose.Direction(rawValue:)` (`Trio/Trio/Sources/Models/BloodGlucose.swift:6-18`); an unknown string stores `nil` direction but keeps the reading | Nightscout name from `TrendArrow` (always a valid raw value) |
| `trend` / `Trend` | Int 1…7, or numeric string (`:73-79`) | only if `direction` is absent; mapped through LoopKit `GlucoseTrend` (`LoopKit/LoopKit/GlucoseKit/GlucoseTrend.swift:12-19`). No direction and no usable trend → element **skipped** (`:81`). | `Trend`, Dexcom Share ordinal |
| `ST` | — | not read | same as `DT` (as xDrip4iOS) |
| `from` | String, optional (`:83-85`) | if present and not equal to the source's `from` (`"xDrip"`, `FetchGlucoseManager.swift:219-220`) → element **skipped**; absent → accepted | **not written** (see [Source identity](#source-identity)) |

Everything else — noise, filtered, session start, transmitter ID — is left `nil` (`:87-98`). Trio therefore
records no sensor-change treatment from this source (`Trio/Trio/Sources/APS/Storage/GlucoseStorage.swift:221-254`
needs `sessionStartDate`).

Trio applies no range, age or future check at this stage. The same source also runs
`HeartBeatManager.checkCGMBluetoothTransmitter` whenever the key exists (`AppGroupSource.swift:52`), see below.

### Source identity

The only source label in the contract is `from`, and Trio accepts elements without it. This bridge omits
it, so its readings are never labelled as xDrip4iOS's, and they would also be accepted by a patched Trio
with a differently named App Group source. Trio's UI still calls the source "xDrip4iOS"
(`CGMType.swift:18-19, :58-63`, `Trio/Trio/Sources/Helpers/CGMOptions.swift:14`), its CGM sheet shows an
"Open xDrip4iOS" button that tries `xdripswift://` (`CGMType.swift:35-36`,
`Trio/Trio/Sources/Modules/CGMSettings/View/CustomCGMOptionsView.swift:63-86`), and the source info reads
"Group ID: …" (`AppGroupSource.swift:117-119`). All cosmetic.

## When Trio reads

- **Timer.** `FetchGlucoseManager` owns a one-minute `DispatchTimer` (`FetchGlucoseManager.swift:45`) that
  calls `glucoseSource.fetch(timer)` (`:89-124`). It runs only while Trio's process is running.
- **CGM heartbeat.** If the App Group holds `cgmTransmitterDeviceAddress`, `cgmTransmitter_CBUUID_Service`
  and `cgmTransmitter_CBUUID_Receive`, Trio opens its own CoreBluetooth connection (with state restoration)
  to that peripheral, subscribes to the characteristic, and fires the timer on every notification and every
  disconnect (`HeartBeatManager.swift:4-8, :25-75`; `BluetoothTransmitter.swift:41-67, :256-260, :335-340`).
  Trio's CGM screen shows the address, or "CGM is not used as heartbeat." (`CustomCGMOptionsView.swift:177-189`).
  xDrip4iOS 7.1.0 writes these keys (`xDrip/Managers/BluetoothPeripheral/BluetoothPeripheralManager.swift:616-640`)
  and, for a G7 in primary mode, names the G7 service and its **authentication** characteristic
  (`xDrip/BluetoothTransmitter/CGM/Dexcom/G7/CGMG7Transmitter.swift:875-876`).
- **Pump.** Trio answers the pump manager's "must provide BLE heartbeat?" with yes (`DeviceDataManager.swift:455-457`)
  but ignores the heartbeat callback (`:450-453`); pump radio traffic can still wake Trio so an overdue timer fires. Nothing guarantees a
  five-minute cadence from the pump alone.
- No notifications or KVO are used.

Consequence: today, with Trio's own G7 plugin, the sensor's BLE traffic wakes Trio every five minutes. After
switching to the App Group source, Trio has no such wake-up unless the heartbeat keys are written.
`TrioBridge.setHeartbeatPeripheral(_:)` writes them (service and characteristic first, address last,
because Trio caches a new address before it checks the UUIDs and does not retry, `HeartBeatManager.swift:33-42`)
but **the app does not call it yet**: letting Trio connect to the sensor this app authenticates to is a BLE
decision for G7Kit/Phase 2 (open question). Either way, verify background cadence on device (§11 step 4).

There is also a race xDrip4iOS shares: a heartbeat fires on the sensor's disconnect, possibly before this app
has written the new reading. Trio then picks it up on its next wake-up (the payload keeps it, see below).

## How Trio decides what is new, backfill, and stale data

After every fetch, `glucoseStoreAndHeartDecision` (`FetchGlucoseManager.swift:243-287`) runs:

1. Trio's own calibrations are applied if any exist (`:245, :293-312`; cleared when the CGM source changes, `:189-193`).
2. `syncDate` = newest stored glucose in the last day, else `distantPast` (`GlucoseStorage.swift:318-343`).
3. **Backfill path**, elements at or before `syncDate` (`FetchGlucoseManager.swift:259-267`): dropped if within 1 s
   of a glucose the user deleted, or within **3.5 min** of any stored glucose; the rest are stored
   (`GlucoseStorage.swift:77-105`). So a backfilled reading is kept with its own timestamp when it fills a gap.
4. **New path**, elements after `syncDate`: sorted, and each kept only if it is **more than 3.5 min** after the
   previous kept one (`filterTooFrequentGlucose`, `GlucoseStorage.swift:42-44, :368-382`); then stored unless
   within 1 s of an existing one (`:107-126, :133-171`).
5. If anything new was stored, the loop is triggered (`FetchGlucoseManager.swift:284`).

Deduplication is by timestamp only. Re-sending readings Trio already has is harmless, so the bridge writes a
sliding window: every write carries the newest readings again, and a reading Trio missed while suspended is
still there at its next poll.

**Stale data.** Nothing ages readings out at read time. The loop refuses to run when the newest glucose is
older than **12 min** ("Glucose data is stale…", `APSManager.swift:464-470`), and oref independently treats
data older than 12 min as unusable (`trio-oref/lib/determine-basal/determine-basal.js:396-397, :431-466`). When
the loop stops, the running temp basal finishes and the pump returns to its scheduled basal.

### Readings dated slightly ahead

`LiveReadingGate.futureTolerance` lets a reading be dated up to 60 s after the bridge's `now`. Trio accepts that:

- the App Group reader does no date check (above);
- such a reading becomes `syncDate`; the next sensor reading, derived 5 min later from the same sensor clock, is
  at least 300 − 60 = 240 s after it, which clears the 210 s `filterTooFrequentGlucose` threshold with 30 s
  to spare. (A tolerance above 90 s could make Trio lose the following reading for good: less than 3.5 min
  after `syncDate`, so dropped as too frequent, yet newer than `syncDate`, so never offered to the backfill path.)
- oref rejects a reading only when it is more than 5 min ahead (`minAgo < -5`, `determine-basal.js:397, :431`);
- Trio's "minutes ago" label shows "< 1 m" (`Trio/Trio/Sources/Helpers/TimeAgoFormatter.swift:15-28`).

Both apps read the same phone clock, so by the time Trio reads, the lead is smaller still.
`test_S2_refusesFutureReadingBeyondToleranceAcceptsWithin` covers the boundary.

## What xDrip4iOS writes, and where this bridge differs

`LoopManager.share()` (`xDrip/Managers/Loop/LoopManager.swift:409-651`) writes, when sharing to Trio
(`xDrip/Managers/Loop/LoopShareType.swift:30-38`):

- key `latestReadings` (`:615`), top-level array (`:601-603`, `:759-763`) of dictionaries
  `{"Trend": Int, "ST": "/Date(ms)/", "DT": "/Date(ms)/", "Value": Double, "direction": String, "from": "xDrip"}`
  (`:521-531`);
- readings newest first (`xDrip/Core Data/accessors/BgReadingsAccessor.swift:97-107`), at most 60
  (`xDrip/Constants/ConstantsShareWithLoop.swift:6`), from 30 min before the last shared reading (`:463`);
- an empty array when there is nothing to share (`:591-599`, `:782-791`);
- a separate metadata key `xDrip4iOSCGMMetadata` (`:12-14`, `:767-780`). **Trio `main` @ 29350e31a does not read it**
  (no reference in Trio's sources); a richer dictionary form of `latestReadings` mentioned in xDrip4iOS
  (`:817-837`) is also not read by this Trio (it requires a top-level array, `AppGroupSource.swift:55`).

| | xDrip4iOS 7.1.0 | This bridge | Why |
|---|---|---|---|
| `Value` | `Double`, `round()`ed | `Int` | Trio casts to `Int`; an integer is unambiguous |
| `DT`/`ST` | floored to the second (`:521`) | whole milliseconds of the reading's own time | S3: Trio stores exactly the instant this app stores; Trio parses any integer |
| `Trend` | 0 when the slope is hidden | Dexcom Share ordinal, 8 = NOT COMPUTABLE (`share2nightscout-bridge/index.js:57-68`) | consistent with `direction`; Trio ignores it when `direction` is present |
| `direction` | xDrip4iOS slope name | `TrendArrow(rate:).nightscoutDirection` from the sensor-reported rate | HANDOFF §7.5 mapping |
| `from` | `"xDrip"` | omitted | [Source identity](#source-identity) |
| window | readings since last share − 30 min | newest 60 readings this process accepted | lets Trio catch up after long suspensions |
| empty | writes `[]` | never writes an empty array; `clear()` removes the key | a refused-only call leaves Trio's last payload untouched |

## What this bridge writes

`TrioBridge.publish(_:session:)`, per call:

1. Given readings whose `id` is already in the window are ignored (S3: the copy Trio has is never replaced).
2. Every other reading goes through `LiveReadingGate.validate(reading, session:, now:)` (S2, S6; never the
   DEBUG replay variant), then the LOW/HIGH policy (S4). Refusals are returned, logged (category `.bridge`)
   and published in `status.lastRefusal`.
3. If nothing was accepted and no earlier write is pending, nothing is written.
4. The window = previous window + accepted, newest first, capped at 60. An accepted reading older than the
   newest 60 is reported as `olderThanPayloadWindow`.
5. **Immediately before the write, every reading in the window passes the gate again** with the current
   session and clock; readings of an earlier sensor session fail and are left out.
6. JSON-encode (sorted keys, unescaped slashes), `checkAccess()`, `set`, read back and compare.

The window lives in memory. After a relaunch the app should publish its recent stored `.sensor` readings (for
example the last 5 hours) once a session is known; each passes the gate again. Readings older than the newest
60 (about 5 hours at the G7's 5-minute cadence) never reach Trio after a long gap; xDrip4iOS has the same limit.

Golden example (`Packages/TrioBridge/Tests/TrioBridgeTests/Fixtures/latestReadings.golden.json`, formatted here):

```json
[{"DT":"/Date(1758007800123)/","ST":"/Date(1758007800123)/","Trend":8,"Value":101,"direction":"NOT COMPUTABLE"},
 {"DT":"/Date(1758007500123)/","ST":"/Date(1758007500123)/","Trend":5,"Value":108,"direction":"FortyFiveDown"},
 {"DT":"/Date(1758007200123)/","ST":"/Date(1758007200123)/","Trend":4,"Value":112,"direction":"Flat"}]
```

`isBackfill` has no field in the contract: a backfilled reading is just an element with its original
timestamp, which Trio routes through its backfill path.

## LOW and HIGH (S4)

**Default (implemented): LOW and HIGH readings are not written to Trio.** `OutOfRangePolicy.doNotWrite`.
Each withheld reading is a refusal with reason `.outOfRangeWithheld(.belowRange/.aboveRange)`, sets
`status.lastOutOfRangeWithheldAt`, and is logged, so the app can show "LOW not sent to Trio". This is a
safety trade-off for Michael to decide.

### Evidence

| Path | Sensor LOW (< 40) | Sensor HIGH (> 400) | Source |
|---|---|---|---|
| Trio + its own G7 plugin | stored as **40**; the `.belowRange` condition is produced and then dropped | stored as **400**; Trio's header shows "HIGH" for exactly 400 | `G7SensorKit/G7SensorKit/G7CGMManager/G7CGMManager.swift:399, :405, :446, :451`; `PluginSource.swift:234-253` (no `condition`); `Trio/Trio/Sources/Modules/Home/View/Header/CurrentGlucoseView.swift:73` |
| Trio + Dexcom Share plugin | 40 | 400 | `dexcom-share-client-swift/ShareClient/ShareGlucose+GlucoseKit.swift:24, :53-61` |
| Trio App Group reader | any integer stored as is | any integer stored as is | `AppGroupSource.swift:61-99` |
| xDrip4iOS G7 primary → App Group | the sensor's own number (< 40), unclamped | the sensor's number, capped at 600 | `CGMG7Transmitter.swift:1104-1143`; `xDrip/Calibration/NoCalibrator.swift:44-51` |
| xDrip4iOS calibrated sensors | floor **39**; < 10 → **38** (error) | cap 400 | `xDrip/Calibration/Protocol/Calibrator.swift:500-507`; `xDrip/Constants/ConstantsCalibrationAlgorithms.swift:8-11` |
| Nightscout | exactly 39 displays "LOW"; < 39 are error codes | exactly 401 displays "HIGH"; any > 400 is HIGH | `cgm-remote-monitor/lib/sandbox.js:248-256`; `lib/client/index.js:532-547` |
| LoopKit Share client / Trio model | `isStateValid` = `glucose >= 39` | — | `ShareGlucose+GlucoseKit.swift:30-32`; `BloodGlucose.swift:168` |

How oref (bundled in Trio) treats the numbers:

- **38, or ≤ 10**: "CGM is calibrating, in ??? state, or noise is high": replaces a high temp with a neutral
  temp, shortens a long zero temp to 30 min, otherwise does nothing (`determine-basal.js:418-466`). Trio's
  smoothing also treats 38 as an error (`FetchGlucoseManager.swift:421-429, :472-476`). **Never send 38 for LOW.**
- **39 / 40**: ordinary glucose. Below threshold → SMB disabled (`:1209`) and a 30–120 min zero temp
  (`:1265-1280`). Used in deltas (`trio-oref/lib/glucose-get-last.js:32`, `> 38`) and in COB/autosens (they drop
  only `< 39`: `determine-basal/cob.js:36, :48, :129`; `determine-basal/autosens.js:95`).
- **400 / 401**: ordinary glucose. trio-oref removed its 400 "protect due to HIGH" guard
  (`oref0_source_version.txt:4-6`, commits 8282ce7/3aeba68), so both are dosed on as numbers.

### Options

| | Trio sees during a LOW | Trio sees during a HIGH | S1/S4 | Status |
|---|---|---|---|---|
| **A. Don't write** (default) | last numeric reading; after 12 min the loop stops ("stale"), the running temp — normally the 30–120 min zero temp oref set on the way down — finishes, then **scheduled basal resumes** while the sensor may still read LOW | the loop stops after 12 min; no corrections while > 400 | clean | implemented, default |
| **B. 39 / 401 sentinels** | a real low: zero temps continue as long as LOW lasts | corrections continue as for 401 (true value ≥ 401, so no over-estimate) | not a clamp to 40/400, and they are the ecosystem's LOW/HIGH codes, but they **are numbers the sensor did not report** (S1 tension). Trio displays "39"/"401", not "LOW"/"HIGH", and counts them in its stats | implemented as `.writeSentinel`, off |
| **C. 40 / 400** | as B | as B | forbidden by S4 | not implemented |
| **D. Trio patch carrying a LOW/HIGH flag** | Trio stores `Int16` glucose and oref has no flag, so a number is still needed; larger AGPL patch, no dosing benefit over B | | | not recommended |
| **E. LOW → 39, HIGH not written** | as B | as A | S1 tension for LOW only | supported by the policy |

`OutOfRangePolicy` sets LOW and HIGH independently, so A, B and E are one line in the app's wiring.

### Recommendation

**B for LOW** (write 39). The dangerous case for option A is a sustained severe low: once the loop goes stale,
the pump can return to scheduled basal while glucose is below 40. Writing 39 keeps oref suspending for as long as
the sensor says LOW, which is also what Trio does today with its own G7 plugin (40), minus the clamp to an
in-range-looking value. **For HIGH, B or E** — B matches Trio's current native behaviour (400) and only ever
under-states the true value; E is the conservative choice if Michael would rather automation never dose on a
value of unknown magnitude. In every option this app's own alerts fire on the LOW/HIGH flags (S7 urgent low
cannot be disabled). Changing the policy needs Michael's explicit sign-off because B/E put a number the sensor
did not report into Trio (S1).

## Failure reporting (S5)

`TrioBridge.status` / `statusUpdates()` (a stream per caller, current value first):

| Field | Meaning |
|---|---|
| `lastSuccessfulWriteAt`, `newestReadingWrittenAt`, `readingsInLastWrite` | last verified write |
| `consecutiveFailures` / `isFailing` | writes failed since the last success. The app should alert (§5 "Trio bridge") while non-zero |
| `lastError`, `lastErrorAt` | `appGroupUnavailable(invalidGroupID / notEntitled / suiteUnavailable)`, `encodingFailed`, `writeNotPersisted` |
| `lastRefusal` | latest refused reading and why (gate rejection, LOW/HIGH withheld, older than the window) |
| `lastOutOfRangeWithheldAt` | latest LOW/HIGH not sent under the policy |

A failed write keeps its readings pending; the next `publish` (with or without new readings) retries.

**"Trio not consuming for 15 min" is not detectable** with unpatched Trio. Trio writes nothing into the App
Group: its only App Group access is the read in `AppGroupSource.swift:34-52`, `lastLoopDate` is persisted in
Trio's own storage (`APSManager.swift:85-86`, `Trio/Trio/Sources/Helpers/PropertyWrappers/PersistedProperty.swift:24, :34-40`, default `UserDefaults.standard`)
and Core Data uses the default store location in Trio's own container (`Trio/Model/CoreDataStack.swift:21-31`). Trio does alert on its own when
its glucose goes stale. Alternatives (open question): a small Trio patch writing a "last read" timestamp into the
group, or reading Trio's device-status uploads back from Nightscout.

## Trio patch

**None.** Trio's existing App Group source consumes the bridge's writes unchanged; the tests prove the payload
against a model of Trio's reader and against the golden file. A distinct source name ("Sensor" instead of
"xDrip4iOS") would need a new `CGMType` case and touches `CGMType.swift`, `CGMOptions.swift`,
`FetchGlucoseManager.swift:215-230`, two exhaustive switches (`HomeRootView.swift:1027-1037`,
`CGMRootView.swift:157-167`) and `CustomCGMOptionsView.swift:55-61` — cosmetic only, and a fork divergence to
carry on every Trio release. If Michael wants it, or wants the "last read" write-back above, it is a small
separate patch; the bridge works either way because it sends no `from`.

## Nightscout uploads

HANDOFF §8A: exactly one app uploads each CGM reading. D6: this app uploads (NightscoutKit, `docs/following.md`);
Trio's CGM upload is off. Feasible as follows.

**Trio's settings** (`Trio/Trio/Sources/Models/TrioSettings.swift:21, :28`; UI
`Trio/Trio/Sources/Modules/NightscoutConfig/View/NightscoutUploadView.swift:18-70`, reached via
Settings → Services → Nightscout → Upload, `Settings/View/Subviews/ServicesView.swift:25`,
`NightscoutConfigRootView.swift:53`):

| Setting | Key | Gates | Set to |
|---|---|---|---|
| Allow Uploading to Nightscout | `isUploadEnabled` | every upload: carbs, temp targets, overrides, pump history, device status, profiles, glucose (`Trio/Trio/Sources/Services/Network/Nightscout/NightscoutManager.swift:107-109, :313-341, :408, :609, :822, :864-1119`) | **On** (followers and Nightscout still get Trio's treatments and loop status) |
| Upload Glucose | `uploadGlucose` | glucose only (`NightscoutManager.swift:115-117, :822`) | **Off** |

So CGM upload can be disabled independently of treatments. Notes:

- "Upload Glucose" also carries Trio's **manual fingerstick** entries (`mbg`): `getGlucoseNotYetUploadedToNightscout`
  returns both (`GlucoseStorage.swift:398-437`). With it off, fingersticks entered in Trio are not uploaded either.
- The model default is `true` (`TrioSettings.swift:28`) although the hint text says "Default: OFF"
  (`NightscoutUploadView.swift:67`): check the toggle, don't assume.
- A plugin CGM overwrites the toggle with its own "upload readings" setting (`PluginSource.swift:166`,
  `FetchGlucoseManager.swift:168-177`); the App Group source has no CGM manager and leaves it alone. So check the
  toggle **after** switching from the G7 plugin to xDrip4iOS.
- If the toggle is later turned on, Trio uploads everything from the last 24 h not yet marked uploaded
  (`Trio/Model/Helper/GlucoseStored+helper.swift:81-84`), duplicating this app's entries unless timestamps match.
- CGM sensor-change treatments are not generated for App Group readings (see above), so none are uploaded.

**How Nightscout dedupes.** `POST /api/v1/entries` upserts on `sysTime` + `type`
(`cgm-remote-monitor/lib/server/entries.js:120-131, :238-248`), i.e. only an identical timestamp to the millisecond
merges. Trio's entries (`NightscoutAPI.swift:15, :345-376`) carry no `device` field (`BloodGlucose.swift:62-78`), so
Nightscout cannot tell the two uploaders apart. With both uploading, identical-millisecond timestamps would merge
(this bridge writes whole milliseconds and Trio stores them unchanged), but that depends on both apps' date
handling end to end; one uploader is the reliable rule. HealthKit and Tidepool uploads are separate Trio
settings and unaffected.

## Setup

1. **Same Team ID** for both apps. This app's `Config/Signing.xcconfig` `DEVELOPMENT_TEAM` must be the team that
   signs Trio (Trio's bundle ID is `org.nightscout.<TEAM>.trio`, `Trio/Config.xcconfig:12`).
2. **App Group.** Build this app once with automatic signing so Xcode adds `group.org.nightscout.<TEAM>.trio.trio-app-group`
   to its App ID (the group already exists from Trio's build). Check in the developer portal that the App ID
   `com.mzarras.sensor` lists both groups.
3. **In Trio**: Settings → Devices → CGM. Delete the current CGM (the Dexcom G7 plugin). Add CGM → **xDrip4iOS**.
   Trio's source info reads "Group ID: group.org.nightscout.<TEAM>.trio.trio-app-group" (`AppGroupSource.swift:117-119`);
   it must be the same string as this app's `TrioAppGroupID`.
4. **Do not also run Trio's G7 plugin (G7SensorKit) against the same sensor.** One path in: this app authenticates
   to the sensor and hands readings to Trio; Trio's G7 plugin must be removed (step 3). Also do not run xDrip4iOS
   with "share to Trio" on: it writes the same key.
5. **Nightscout** (§8A): in Trio, Allow Uploading to Nightscout **on**, Upload Glucose **off**. In this app, turn
   on Nightscout upload.
6. Keep Trio's own calibrations empty (switching the source clears them, `FetchGlucoseManager.swift:189-193`).

## On-device checks (add to §11 step 4)

- First reading appears in Trio with the same value and time (to the minute) as this app; direction arrow matches.
- Phone locked, both apps backgrounded for 30+ minutes: Trio keeps looping every ~5 minutes. If it doesn't, the
  heartbeat keys are needed (open question).
- Walk out of range 30+ min: backfilled readings appear in Trio at their original times.
- Nightscout shows each reading once, from this app.
- A LOW/HIGH (if one happens) shows the behaviour of the chosen policy.

## Limitations

- Trio consumption cannot be observed (see Failure reporting).
- Readings older than the newest 60 are never offered to Trio.
- The heartbeat keys are supported by the bridge but not wired.
- Behaviour documented against Trio `main` @ 29350e31a; re-check `AppGroupSource.swift` on every Trio update.
