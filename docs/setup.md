# Setup, build, and on-device validation

How to sign, build and install Sensor (working name) on an iPhone, configure it next to Trio,
Nightscout and Dexcom Share, and validate it with a real sensor before relying on it.
Decisions are cited as D1…D51 (`PROGRESS.md`); the plan in §5 is HANDOFF §11 in the order D46 sets,
with every on-device check from the other docs merged in.

The plan has two parts (D45, D46). **Part A, now:** the app runs on your current sensor in **listen
mode**, alongside the Dexcom app, which stays installed and keeps the sensor; Trio stays on its own
G7 source. **Part B, the next sensor:** delete the Dexcom app, pair this app as the sensor's primary
device, switch Trio to it and turn on uploads. §0 is the checklist for today.

**If you are going to rename the app, do it before you install it on the phone** (§6): a new bundle
ID is a new app to iOS, with none of the old one's data, settings or pairing.

---

## 0. Today: run it alongside the Dexcom app (listen mode)

Listen mode (D45) only *observes* the Bluetooth connection the Dexcom app on the same phone has
authenticated (iOS shares one link per sensor among the apps using it). It needs no pairing code
and never touches the Dexcom app's slot. Its only write to the sensor is the read-only session-length
query (`52`), at most once per connection, and only if no answer to Trio's own `52` request was seen
by the second authenticated wake (D49). It sends no authentication, calibration, backfill or other
command, and it subscribes to the data characteristic only after it has seen the Dexcom app
authenticate (D50). Readings pass the same checks as in primary mode (S2), and alerts work. While
listening, the Trio handoff and the Nightscout and Dexcom Share uploads are off. Listen mode has no
backfill (gaps stay gaps; the Dexcom app has the history) and no calibration (calibrate in the
Dexcom app). Details: `docs/g7-protocol.md` §14.

1. [ ] **Build and install the Release build** (§2 signing, §3.3 commands). Not a DEBUG build: it
   must never read a live sensor (D19).
2. [ ] **On first launch, choose "Listen alongside the Dexcom app (this sensor)"** at the "How to
   connect" step, then Continue. Listening skips "Remove the Dexcom app" and "Pair your sensor"; a
   "Listening" step takes their place. Allow notifications and, on iOS 26+, alarms. History import
   (§5 step 1a) is optional here.
   - Already set up? Settings › Sensor › CONNECTION › "Listen alongside the Dexcom app (this
     sensor)", and confirm "Listen alongside the Dexcom app".
   - **No "How to connect" step?** That build predates the listen-mode screens. Tap "Set up later",
     enter **no** pairing code, and stop: a code pairs this app as the primary device and evicts the
     Dexcom app (a new install starts in pairing mode).
3. [ ] **Keep Trio on its own G7 source.** Don't switch Trio to xDrip4iOS, and leave Trio's Nightscout
   settings as they are. This app's Trio handoff is off while listening: the switch is off and
   disabled ("Off while listening alongside the Dexcom app"), Settings shows "off while listening",
   and nothing is written to Trio's App Group (no readings, no heartbeat keys).
4. [ ] **Uploads stay off.** Nightscout and Dexcom Share show the same "Off while listening…" note:
   the Dexcom app keeps uploading to Dexcom Share and Trio to Nightscout, so nothing is duplicated.
5. [ ] **Treat this app's alarms as secondary today.** Act on the Dexcom app's alerts and your
   fingerstick. This app's alerts work as usual (urgent low can't be turned off and re-alarms at
   snooze end, §4.5), so expect a second alarm for the same event. It can also miss a wake the
   Dexcom app gets (a missed authentication packet loses that wake, D50), so it may raise a
   missed-readings alert that the Dexcom app doesn't. Don't change the Dexcom app's alert settings
   because of this app.
6. [ ] **While it waits.** The Listening step reads "Waiting for the Dexcom app's connection… The
   sensor talks to it about every 5 minutes; keep the Dexcom app installed and signed in." The first
   reading can take a few sensor wakes (about 15 minutes), because the session length must come from
   the sensor: from an observed answer to Trio's `52` request, or from this app's own query at the
   second authenticated wake (diagnostics: `listen: session length not observed; one 52 query sent
   (D49)`). Meanwhile you may see, as a "Readings interrupted" banner (not an alert):
   - "Listening to the Dexcom app's connection, but the sensor's session length is not known yet, so
     readings are held back…" (`listenSessionLengthUnknown`): expected at first;
   - "Listening for the Dexcom app's connection, but it was not seen authenticating the sensor at the
     last sensor wakes…" (`listenNoAuthenticatedConnection`): two wakes in a row without an observed
     authentication. Now and then is expected; if it persists, listen mode isn't working on this
     phone.

   Plus "No readings yet" until the first reading. Once the sensor's state arrives the step reads
   "Listening. Readings arrive whenever the Dexcom app's sensor connects." (Continue), and Now and
   Settings › Sensor show "Listening — the Dexcom app owns the connection".
7. [ ] **Turn on Settings › DIAGNOSTICS › "Record raw glucose packets"** (D47). Every glucose packet's
   bytes then go to the diagnostic log (`G7: raw listen packet <hex>`), so a real LOW or HIGH is
   captured for D31. The log keeps only the last 5 000 events: export diagnostics (§7.6) the same day
   as a LOW or HIGH. Turn it off when done.
8. [ ] **At the first reading, compare the sensor expiry with the Dexcom app's.** Settings › Sensor ›
   Session reads "started … · ends <day>, <time>"; it must equal the sensor end the Dexcom app shows,
   to the minute (`docs/g7-protocol.md` §13 item 14, review m1). If the Dexcom app's traffic uses the
   `0x31`/`0x25` format only, a wrong session origin would shift warm-up end, expiry, grace end and
   reading ids without any other sign. If the two differ, report it and don't rely on this app's
   expiry, grace period or reminders (reading times are unaffected). Also check a few reading times
   against the Dexcom app's: within seconds.
9. [ ] **Watch the Dexcom app** all day: signal loss, a pairing request or "pair sensor" prompt, sensor
   errors, missing readings or gaps it would normally fill, anything unusual around the wake where
   this app's diagnostics show `one 52 query sent (D49)` (the log's times are UTC).
10. [ ] **How to stop at once** if anything looks wrong:
    - delete this app; or
    - Settings › Sensor › CONNECTION › "Pair this app (Dexcom app removed)", and confirm "Pair this
      app". That stops listening and drops the followed sensor. Then enter **no** code. "Forget this
      sensor" isn't offered while listening.

    Then tell the orchestrator what you saw, with the diagnostics export.

Then continue with §5 Part A.

---

## 1. Prerequisites

| What | Version | Why |
|---|---|---|
| Xcode | **26.2** (`project.yml` `xcodeVersion`; the gates run on 26.2) | Swift 6 strict concurrency; the iOS 26 SDK for AlarmKit (`import AlarmKit` in AlertEngine) |
| XcodeGen | 2.46.0 or later: `brew install xcodegen` | `Sensor.xcodeproj` is generated from `project.yml` and gitignored |
| iOS Simulator | an iPhone 17 simulator on the latest iOS (the gates' default `SIM_DEST`) | `scripts/check.sh` gates 2 and 4 |
| Apple Developer team | **the team that signs your Trio build** | Sensor and Trio must share Trio's App Group (D2) |
| iPhone | iOS **17.0** or later (D5, same as Trio). AlarmKit (urgent low as a system alarm) needs iOS 26+ | |
| On the iPhone | Developer Mode on (Settings › Privacy & Security › Developer Mode) | to run a development-signed build |
| Xcode account | Xcode › Settings › Accounts signed in to that team | automatic signing from `xcodebuild -allowProvisioningUpdates` |

Swift packages (GRDB 7.11.1, pinned exactly, D8) are fetched on the first build.

## 2. Signing

### 2.1 `Config/Signing.xcconfig`

```sh
cp Config/Signing.example.xcconfig Config/Signing.xcconfig   # gitignored; never commit it
```

`Config/Base.xcconfig` includes it last (`#include? "Signing.xcconfig"`), so its values override the
safe unsigned defaults (`org.example.sensor`) the gates build with. Fill in:

| Setting | Value | Used for |
|---|---|---|
| `DEVELOPMENT_TEAM` | your 10-character Team ID (§2.2) | signing; expands inside `TRIO_APP_GROUP_ID` |
| `BUNDLE_ID_PREFIX` | `com.mzarras.sensor` (D1) | app bundle ID; the widget is `$(BUNDLE_ID_PREFIX).widgets`; also the URL scheme the widget opens |
| `APP_GROUP_ID` | `group.com.mzarras.sensor` (D2) | this app's own App Group: the widget snapshot (`widget-snapshot.json`). App **and** widget entitlements |
| `TRIO_APP_GROUP_ID` | leave as `group.org.nightscout.$(DEVELOPMENT_TEAM).trio.trio-app-group` | Trio handoff and heartbeat (§4.1). App entitlements only, not the widget |
| `SENSOR_APP_ENTITLEMENTS` | `App/Sensor.entitlements` (default) | switch to `App/Sensor+CriticalAlerts.entitlements` only after Apple grants Critical Alerts (§2.4) |

The reading database is **not** in either App Group: it lives in the app's own container,
`Application Support/GlucoseStore/readings.sqlite` (D25), as do the upload queues (D48).

### 2.2 Team ID

It must be the team that signs Trio, or the two apps cannot share Trio's App Group (D2), and
nothing in either app can detect the mismatch: writes land in a group Trio never reads. Trio's
bundle ID is `org.nightscout.<TEAM_ID>.trio` (`Trio/Config.xcconfig:12`), so take the 10 characters
between `org.nightscout.` and `.trio`. Where to read it:

- your Trio fork's `ConfigOverride.xcconfig` (`DEVELOPER_TEAM = …`), or
- developer.apple.com › Certificates, Identifiers & Profiles › Identifiers: the App ID
  `org.nightscout.<TEAM_ID>.trio`, or
- developer.apple.com › Account › Membership details › Team ID.

### 2.3 App Groups

Trio's group `group.org.nightscout.<TEAM_ID>.trio.trio-app-group` already exists in your team
(Trio's build registered it). This app needs its own group as well.

Automatic signing (`CODE_SIGN_STYLE = Automatic`) normally registers the App IDs and groups from the
entitlements on the first signed build (§3.3). Check the result, or do it by hand, at
developer.apple.com › Certificates, Identifiers & Profiles:

1. **Identifiers › App Groups › +**: register `group.com.mzarras.sensor` if it is not listed.
2. **Identifiers › App IDs › `com.mzarras.sensor`** (create it as an explicit App ID if missing):
   - App Groups › Configure: tick **both** `group.com.mzarras.sensor` and
     `group.org.nightscout.<TEAM_ID>.trio.trio-app-group`;
   - Time Sensitive Notifications: on (the app entitlements request it).
3. **Identifiers › App IDs › `com.mzarras.sensor.widgets`**: App Groups › tick only
   `group.com.mzarras.sensor`.
4. Save. Profiles are regenerated by the next `xcodebuild … -allowProvisioningUpdates` (or Xcode).

The `.tests` / `.uitests` bundle IDs are simulator-only and need nothing in the portal.

### 2.4 Critical Alerts (optional, D4, D17)

The code always asks for `.criticalAlert` authorization and uses Critical Alerts automatically if
they are available; without them it falls back to Time Sensitive notifications, in-app audio and
(iOS 26+) AlarmKit for urgent low. The entitlement is granted per team by Apple
through Apple's request form
(developer.apple.com/contact/request/notifications-critical-alerts-entitlement/); approval for a
build-from-source app is unlikely (PROGRESS "Open questions"). Signing **fails** if the entitlement is
requested before Apple grants it, so it is a switch:

```
SENSOR_APP_ENTITLEMENTS = App/Sensor+CriticalAlerts.entitlements   # in Config/Signing.xcconfig, only once granted
```

Rebuild. Settings › Alert delivery › Critical Alerts then reads "On" (or "Off" if you turned it off
in iOS Settings › Notifications › Sensor › Critical Alerts).

### 2.5 Generate the project

```sh
xcodegen generate     # after every checkout, pull, or project.yml change
```

## 3. Building

### 3.1 Gates: `scripts/check.sh`

```sh
scripts/check.sh                                         # gates 1–4, exits non-zero on any failure
GATES=build scripts/check.sh                             # a subset: build, tests, safety, replay
GATES=tests,safety scripts/check.sh                      # safety reads the test logs of the same run
PACKAGES="GlucoseStats AlertEngine" GATES=tests scripts/check.sh
APP_TESTS=1 PACKAGES="TrioBridge" GATES=tests scripts/check.sh   # also run the app's hosted tests
SAFETY_RULES="S6 S7" GATES=tests,safety scripts/check.sh
SIM_DEST='platform=iOS Simulator,id=<SIMULATOR_UDID>' scripts/check.sh   # xcrun simctl list devices available
KEEP_BUILD_DIRS=1 scripts/check.sh                       # keep the fresh build trees (~0.5–1 GB)
scripts/check-selftest.sh                                # plants defects in a throwaway worktree; each must be caught
```

| Gate | What it does | What it proves |
|---|---|---|
| `build` | `xcodegen generate`; `plutil -lint` on both Info.plists and all entitlements; `xcodebuild` for `generic/platform=iOS`, **Debug and Release**, from a fresh DerivedData, unsigned (`CODE_SIGNING_ALLOWED=NO`) | both configurations compile under Swift 6 strict concurrency with zero project warnings (a cached build would hide warnings, hence fresh) |
| `tests` | `swift test` per package on the Mac host, fresh scratch path, with coverage: GlucoseStats ≥ 95 %, AlertEngine ≥ 90 %, TrioBridge ≥ 90 %, G7Kit `Messages/` ≥ 90 %; a package that runs 0 tests fails. Then the app's hosted unit tests (`SensorTests`, without the replay suite) on the simulator, signed ad hoc (D40) so Keychain tests run; a skipped app test fails. App tests run only with the full `PACKAGES` list or `APP_TESTS=1` | the logic of every package and of the app's wiring, against fakes and mock servers |
| `safety` | for each rule in `SAFETY_RULES`: ≥ 1 passing `test_S<n>_…` in this run's logs, none failing or skipped; no `XCTSkip`/`XCTExpectFailure` in files holding safety tests; `nm` on Release vs Debug objects: no ReplayKit symbols, no `validateAllowingReplay`, no GlucoseStore replay role in Release (each must exist in Debug, so the check can't pass vacuously); `validateAllowingReplay` called only from GlucoseCore, AlertEngine, App; `.writeSentinel` outside TrioBridge only on lines citing D21; `.replay`/`.mock` readings built outside ReplayKit only inside `#if DEBUG` (a line heuristic); the `test_S2_`/`test_S6_` tests of GlucoseCore, AlertEngine, TrioBridge and NightscoutKit run again in the **Release** configuration (`swift test -c release -Xswiftc -enable-testing`), and AlertEngine's Release-only `test_S6_releaseBuildRefusesReplayReadings` must pass | S1–S8 each have passing tests; Release builds contain no replay code and refuse replay readings (S6) |
| `replay` | `SensorUITests` (the DEBUG app launched in the simulator on every ReplayKit scenario, and with no sensor) and `SensorTests/ReplayScenarioTests` (alert assertions through the app's own `ReplayRun` wiring); both suites must run | the wired app starts on each scenario and alerts fire when, and only when, expected |

Logs go to `.build-logs/<timestamp>/`. Gate 5 of HANDOFF §10 (independent review) is not a script.
The UI tests launch the app with DEBUG `-silenceAlertAudio`, so nothing plays. If you run the DEBUG
app in the simulator yourself, alarms play on the Mac's speakers: add `-silenceAlertAudio` to the
scheme's Run arguments, and `xcrun simctl shutdown all` when done.

### 3.2 Which configuration, when (D11, D19, D20)

| Build | Use it for | Never |
|---|---|---|
| **DEBUG** | §5 step 1 only: replay scenarios on the phone. Contains ReplayKit and the replay-accepting alert path; shows a persistent **DEBUG BUILD** banner on every tab; the Trio handoff and uploads are paused unless Settings › Developer › Live outputs is on (D20) | with a real sensor, paired or listening; installed over a Release build that is feeding Trio (Trio would stop getting readings, D20) |
| **Release** | everything else, and everything involving a real sensor: §0, and §5 from step 1a on | — |

Both configurations have the same bundle ID, so installing one replaces the other and keeps the
data and settings, **including the connection mode** (the replay store is in memory and never
touches the production database, D20). A Release build never shows the DEBUG banner; that is how
you tell them apart on the phone.

Installing a DEBUG build over a Release build that is listening (§0) would leave the DEBUG build
listening to your live sensor (D19). Before installing DEBUG, switch Settings › Sensor › CONNECTION to
"Pair this app (Dexcom app removed)" and enter no code; after reinstalling Release, switch back to
"Listen alongside the Dexcom app (this sensor)". Over a Release build that is paired (Part B), don't
install DEBUG at all while Trio depends on it.

### 3.3 Build, install and launch on the iPhone

```sh
xcodegen generate

# Connected iPhones (USB, or the same network once paired with Xcode).
# Use the Identifier column (or the device name) as <DEVICE_ID> below.
xcrun devicectl list devices

# Release, signed with your team. -allowProvisioningUpdates lets xcodebuild create or update the
# App IDs and profiles; add -allowProvisioningDeviceRegistration if the phone isn't registered to the team yet.
xcodebuild build \
  -project Sensor.xcodeproj -scheme Sensor -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .derived/device \
  -allowProvisioningUpdates

xcrun devicectl device install app --device <DEVICE_ID> \
  .derived/device/Build/Products/Release-iphoneos/Sensor.app

xcrun devicectl device process launch --device <DEVICE_ID> com.mzarras.sensor
```

For §5 step 1, the same with `-configuration Debug` and `Debug-iphoneos/Sensor.app`. A DEBUG build
can start a replay at launch; app arguments go after `--` (without it `devicectl` rejects
`-replayScenario` as one of its own options):

```sh
xcrun devicectl device process launch --terminate-existing --device <DEVICE_ID> com.mzarras.sensor \
  -- -replayScenario slowFallToUrgentLow -replaySpeed 1 -replayStartMinute 80
```

Scenarios: `steady`, `slowFallToUrgentLow`, `compressionLowSpike`, `signalGapWithBackfill`,
`sensorExpiry` (timelines in `docs/replay.md`). `-replayStartMinute <m>` delivers everything before
minute *m* at once; `-replaySpeed` > 1 runs ahead of the phone clock, so the Now screen then shows
"Phone clock doesn't match" by design. The same replays can be started from Settings › Developer
(DEBUG only), which offers speeds 1×, 10×, 60×, 300× but no start minute.

In Xcode instead: open `Sensor.xcodeproj`, select the phone, and for a Release run set Product ›
Scheme › Edit Scheme › Run › Build Configuration › Release.

## 4. Configuring

### 4.1 Trio (D2, D21, D22; details in `docs/trio-bridge.md`)

No Trio patch. Trio reads this app through its existing **xDrip4iOS** CGM source. **This is Part B
only** (§5): while this app listens alongside the Dexcom app (§0), Trio stays on its own G7 source,
and the handoff is off in this app whatever its switch says (D45).

1. **This app**: Settings › Trio handoff › **Hand readings to Trio** (off by default). The page
   shows the App Group this build writes to (`group.org.nightscout.<TEAM_ID>.trio.trio-app-group`),
   the status, the last write, and whether the heartbeat is published.
2. **Trio**: Settings › Devices › CGM: delete the current CGM (the Dexcom G7 plugin), Add CGM ›
   **xDrip4iOS**. Do this only at the Part B switch-over in §5.
3. **Trio**: Settings › Services › Nightscout › Upload: **Allow Uploading to Nightscout on**,
   **Upload Glucose off**, so exactly one app uploads each CGM reading (D22). Check the toggle *after*
   switching the CGM: a plugin CGM overwrites it, and its model default is on although the hint says
   off. With it off, fingersticks entered in Trio are not uploaded either.
4. **Heartbeat**: Trio is only woken in the background through a "heartbeat" connection to the
   sensor; without it Trio does not loop in the background on DASH, Dana or Medtrum. This app
   publishes the heartbeat keys while the handoff is on and a sensor is paired. Trio's CGM screen
   then reads **"CGM address :"** followed by a UUID instead of "CGM is not used as heartbeat."
   That line is also the practical proof that both apps share the App Group: Trio can only read the
   address from that group.
5. Never also run Trio's G7 plugin, or xDrip4iOS with "share to Trio", against the same sensor:
   one path in. Keep Trio's own calibrations empty.

LOW reaches Trio as 39 and HIGH as 401 (D21); 40/400 are never written for a flag. Imported and
replayed readings never reach Trio (S6). In a DEBUG build the handoff is paused (D20).

Trio has no screen that shows its App Group ID (v0.8.4); it prints "Group ID: …" only inside its
glucose notifications, when "Add Glucose Source to Alarm" is on (Trio Notifications, shown while
glucose notifications are enabled). Use the "CGM address" line (step 4 above) instead.

### 4.2 Nightscout (D6, D29; `docs/following.md`)

**No writes to the live site during development** (D6): tests use local mock servers, DEBUG builds
keep uploads paused (D20), and in §5 uploads stay off until Part B. While listening (§0) both uploads
are off whatever their switches say (D45): Trio keeps uploading CGM readings to Nightscout.

1. In Nightscout › Admin Tools: **Roles › Add new role**, e.g. `sensor-uploader`, permissions
   `api:entries:create`. **Subjects › Add new subject**, e.g. `Sensor`, roles
   `readable, sensor-uploader` (`readable` gives the read access the history import needs).
   Nightscout's default roles can't create entries except `admin`.
2. In this app: Settings › Sharing › Nightscout: **Site URL** (`https://` only; plain `http` is
   refused except for loopback hosts) and **Access token** (that subject's token) › Save. The token
   goes to the Keychain and is sent in the `api-secret` header, never in a URL. Never paste it
   anywhere else.
3. **Upload readings** on (§5 Part B, switch-over). Status, failures and "Waiting to upload N" show on the same
   page; failures also raise a banner. Entries carry `device` = the app's display name.

LOW is uploaded as sgv 39 and HIGH as 401. Nightscout's own alarms ignore 39 and send "All Clear"
when a low turns into LOW (D29): followers who rely on alarms need LoopFollow. Send them
`docs/following.md`.

### 4.3 Dexcom Share (D7, D30)

Removing the Dexcom app stops its uploads to Dexcom Share, so Dexcom Follow stops unless this app
uploads. Unofficial interface; it can break without notice (it then fails loud). While listening
(§0) the Dexcom app is still installed and still uploads; this app's Share upload is off (D45).

- Settings › Sharing › Dexcom Share (also offered in onboarding's "Remove the Dexcom app" step):
  **Region US** (D7), **Dexcom account name**, **Password**, **Receiver serial number** › Save, then
  **Upload to Dexcom Share** on. Credentials go to the Keychain.
- The serial is that of a Dexcom receiver registered to the account (xDrip4iOS calls it "Receiver
  Serial Number"), not the G7 pairing code. A wrong one reports "the receiver serial number is not
  assigned to this account".
- A wrong password is retried only every 30 minutes (also across relaunches) so the account isn't
  locked; saving retries at once. Readings older than 8 hours are not sent.
- Invite any new Dexcom Follow followers in the Dexcom app **before** deleting it.
- LOW/HIGH are sent as 39/401, unverified (D30): §5 step 4a checks it with a follower.

### 4.4 History import (`docs/import.md`)

Settings › Data › Import history (also the first onboarding step):

- **Nightscout**: site URL and token (read is enough), "Last 90 days" (default) or "Everything".
  Resumable and idempotent; progress shows readings imported, skipped entries and the range covered.
- **Clarity CSV**: pick the export in Files, then the time zone it was recorded in (default: the
  current one). mmol/L exports are refused.

Imported history feeds charts and statistics only (S6), never the current value, alerts, Trio or
uploads; Trends footnotes periods that contain it. A LOW/HIGH that Trio's native G7 path uploaded as
40/400 imports as the number (the flag was lost upstream).

### 4.5 Alerts and permissions (`docs/alerts.md`)

| Where | Set |
|---|---|
| Onboarding › Permissions, or Settings › Alert delivery | **Notifications**: Allow. Bluetooth is asked the first time the app looks for the sensor |
| iOS Settings › Notifications › Sensor | Allow Notifications, Lock Screen and Banners, **Sounds**, **Time Sensitive Notifications** on. The app raises "Alerts may not show or sound" if alerts (banners), sounds or Time Sensitive are off. In each Focus, allow Time Sensitive notifications |
| Onboarding › Urgent low alarm, or Settings › Alert delivery (iOS 26+) | **Allow alarms** (AlarmKit, D26): urgent low and its repeats ring as system alarms on silent, in Focus and while the app is suspended. Denied → critical banner "Urgent low alarm is off" |
| Phone volume | In-app alert audio plays at the **media** volume. Settings › Alert delivery warns below 25 %, and a banner says "Alarm volume is low" |
| Alerts tab › each alert | thresholds, sound (preview), snooze, and **Sound on silent** (D17). Urgent low: threshold 50–60, repeat every 2–5 min until acknowledged, snooze ≤ 30 min, no off switch, sound on silent always (S7) |
| Alerts tab › Quiet hours | a daily window that silences every alert **except urgent low**, including Low and Missed readings (D27) |
| Alerts tab › Sensor expiry reminders | 24 h (no sound by default), 12 h, 2 h, grace period started, sensor expired; each with its own switch; the one-off reminders have a Sound switch (D43) |

What "Sound on silent" can and can't do (D17): while the app is awake for a sensor wake-up (about
every 5 minutes) it plays the alert sound itself, through the ringer switch. An alert that comes due
while the app is suspended (missed readings, signal loss) is a Time Sensitive notification, which
**vibrates only** on silent, unless Critical Alerts are granted. Urgent low on iOS 26+ with alarms
allowed is the exception: it rings as a system alarm.

Defaults: sound on silent on for urgent low soon, low, high, missed readings, sensor failed/error/
expired, calibration needed, Bluetooth and Trio; off for the rate alerts, warm-up done, expiry
reminders and "History isn't being saved". Every other alert is on by default except urgent low
soon and rising/falling fast.

**When an urgent-low snooze ends** (acknowledging is a snooze, ≤ 30 minutes, S7):

- **D44: it re-alarms at the snooze end even without a new reading.** Acknowledging schedules the
  alarm for the snooze end on the loudest path available (an AlarmKit alarm where allowed, otherwise
  a Time Sensitive or Critical notification, plus the in-app sound if the app is awake), then repeats
  at the urgent-low repeat interval (5 minutes by default) for an hour, so it keeps sounding while the
  app is suspended or the sensor is out of range. Its text never presents the old value as current: "Snooze ended. Last reading
  50 mg/dL at 2:00 AM. Check your glucose." Quiet hours never silence it. A reading above the
  threshold before the end removes it; one arriving within the last minute can't (the alarm is due),
  so it still rings.
- **D51: in the recovery band it hands over to Low.** If at the end the latest reading is above the
  threshold but within the 5 mg/dL recovery band (56–60 by default), urgent low re-arms and **Low**
  (≤ 70 by default) is evaluated as usual, so it fires (subject to quiet hours, and silent if Low is
  off). A reading at or below the threshold at the end is the urgent-low alarm alone, without Low on
  top.

---

## 5. On-device validation plan (HANDOFF §11, D46 order)

### 5.1 What the automated gates cannot prove

The gates run on the Mac and the iOS Simulator, against fakes, a model of Trio's reader, a G7
"sensor" written from the protocol, and local mock servers. They do not prove:

- that a real G7 accepts the J-PAKE exchange, certificates and proof (no captured G7 exchange
  exists; tests use Mbed TLS vectors and an independently written sensor side);
- listen mode against the real Dexcom app: which glucose format its traffic uses (`0x4E`, or
  `0x31`/`0x25`), how often this app sees its authentication, whether the `0x25` session start is the
  real one, and whether listening (or the one `52` query) disturbs the Dexcom app;
- the iOS pairing prompt and the error codes iOS reports for Cancel or timeout;
- real Bluetooth behaviour: the 5-minute cycle, backfill after a gap, reconnecting while suspended,
  CoreBluetooth state restoration after a system termination or a reboot;
- what a real LOW or HIGH packet contains (D31): no capture exists anywhere;
- the slot hypothesis (Dexcom receiver in slot 1, this app in slot 2, both working);
- file protection: database writes while the phone stays locked for hours; the Keychain before the
  first unlock;
- audibility: in-app audio from the background, the ringer switch, media volume, Focus, phone
  calls; AlarmKit's pre-scheduled repeats, its alarm limit and the snooze-end alarm (D44); Time
  Sensitive delivery;
- that Trio reads the App Group and loops on the heartbeat, open or closed loop;
- the live Nightscout and Dexcom Share servers, and how Dexcom Follow shows 39/401;
- WidgetKit's real refresh lag; battery impact; statistics speed on the phone (the < 100 ms
  requirement is measured on the Mac);
- the monotonic clock on the phone (keeps counting through sleep; `kern.bootsessionuuid` readable).

Those are this plan. They belong to you. What the host tests do cover, and where each safety rule is
enforced, is in `docs/failure-modes.md` (the Phase 3 failure-mode pass: system kill, Bluetooth,
permissions, reboot, disk full, clock and time-zone changes, force-quit, listen mode) and
`docs/safety-review.md` (S1–S8: where enforced, which test proves it). Where those documents say
"§11", the check is in this plan.

### 5.2 Order and ground rules

**Part A, the current sensor, in listen mode** (§0): the Dexcom app stays installed and keeps the
sensor, Trio stays on its own G7 source, and this app's Trio handoff and uploads are off. Steps 1,
1a, 2L, 3L, 3a, and whatever of step 5 the rest of this sensor's session allows.
**Part B, the next sensor, in primary mode**: delete the Dexcom app, pair this app, switch Trio to it,
turn on uploads (switch-over below), then steps 2P, 3P, 4, 4a, 5 and 6.

- **Safety net throughout**: fingerstick meter on hand. In Part A the Dexcom app is the reference
  and stays your primary alarm. In Part B a Dexcom G7 **receiver** paired to the same sensor is the
  reference, if slot semantics allow (step 3P tests it); otherwise the meter only.
- **Release build** for every step with a real sensor (D19). DEBUG only for step 1, and never left
  listening to the live sensor (§3.2).
- **Never force-quit** the app except where a step says so; iOS doesn't restart it after that.
- **Never change the phone's clock** while a sensor you rely on is running: it costs readings
  (§7.3), and in listen mode it also hits the Dexcom app and Trio. The clock test needs a spare
  sensor (end of Part B). A time-zone change is not a clock change and is fine.
- **Record** for every item: date and time, iOS version, the build (Settings › About shows the
  version), what you did, what you saw. For anything unexpected, export diagnostics at once
  (Settings › Data › Export diagnostics, §7.6) and, for values or times, Settings › Data › Export all
  data (CSV): `date_utc, glucose_mgdl` (LOW/HIGH as text), `trend_mgdl_per_min, is_backfill, source,
  import_origin, sensor_serial, id`.
- Widget lag and the clock check go into the table in `docs/widgets.md` ("Measured on device").

---

### Part A — current sensor, listen mode, Dexcom app kept

#### Step 1 — Replay on the phone (DEBUG)

DEBUG build (§3.3). If a Release build is installed and listening, switch it to "Pair this app" with
no code first, and back to listening after reinstalling Release (§3.2). A replay run stops the G7
source for its duration and uses an in-memory store (D20).

- [ ] **DEBUG banner.**
  - Do: open every tab, with and without a replay running.
  - Expect: "DEBUG BUILD" on every tab; "DEBUG BUILD · REPLAY: <SCENARIO>" during a run.
  - Record: any screen without it.
- [ ] **UI walk-through of every scenario.**
  - Do: run each scenario at 1× from a start minute just before its milestones (`docs/replay.md`),
    e.g. `slowFallToUrgentLow` from 105, `sensorExpiry` from 155 and from 25, `signalGapWithBackfill`
    from 25, `compressionLowSpike` from 30, `steady` from 0. Look at Now, Trends 1 D, widget.
  - Expect: LOW shown as "LOW" (never 40) at +110; HIGH as "HIGH" (never 400) at +160 in
    `sensorExpiry`; the 45-min gap breaks the chart line and the backfill fills it at +75; the grace
    period countdown on Now from +30 in `sensorExpiry`; stale and missed-readings banners on time; no
    value shown that the scenario did not deliver.
  - Record: screenshots of anything wrong.
- [ ] **Sounds are distinct by ear** (`docs/alerts.md` §8).
  - Do: Alerts tab › each alert › sound preview; all eight sounds.
  - Expect: no two confusable; none sounds like a pager.
  - Record: pairs you confuse.
- [ ] **Low alert with the ringer off, app awake** (D17 path).
  - Do: ringer switch off, media volume up, `slowFallToUrgentLow` from minute 60; keep the app open.
  - Expect: at +65 (70 mg/dL) Low fires: Dusk plays from the app once, plus a Time Sensitive
    notification.
  - Record: heard yes/no, time.
- [ ] **Urgent low with the ringer off, alarms not allowed** (D17 path, AlarmKit off).
  - Do: turn the app's alarm permission off in iOS Settings (or test on iOS < 26); ringer off;
    `slowFallToUrgentLow` from minute 80; app open.
  - Expect: at +85 (55 mg/dL) Cascade plays from the app and loops about 30 s; a notification with
    Acknowledge/Snooze; on iOS 26+ the "Urgent low alarm is off" banner.
  - Record: heard yes/no, loop length.
- [ ] **A phone call during the urgent-low loop** (alerts.md §10.4).
  - Do: as above; have someone call during the 30-s loop; end the call.
  - Expect: the sound resumes when the call ends.
  - Record: resumed yes/no.
- [ ] **Urgent low as a system alarm** (iOS 26+, alarms allowed; D26, alerts.md §10.2).
  - Do: allow alarms; ringer off; `slowFallToUrgentLow` from 80; lock the phone and leave it.
  - Expect: at +85 a system alarm rings Cascade (no in-app sound: it would clash); **pre-scheduled
    repeats ring 5 and 10 minutes later with the app suspended** (unproven: Loop only schedules the
    immediate alarm); Stop acknowledges: the next repeat does not ring and the notifications are
    removed.
  - Record: the clock time each alarm rang vs expected; what Stop did.
- [ ] **How many alarms AlarmKit accepts** (alerts.md §10.3).
  - Do: Alerts › Urgent low › repeat every 2 min; trigger urgent low again.
  - Expect: 31 alarms (immediate + 30 repeats) accepted: no "Urgent low alarm couldn't be scheduled"
    or "Some alert repeats couldn't be scheduled" banner. (13 at the default 5 min.)
  - Record: any refusal (AlarmKit `maximumLimitReached` is undocumented). Reset the repeat to 5 min.
- [ ] **A wake just before and just after a repeat** (alerts.md §10.3a).
  - Do: while repeats are pending, bring the app to the foreground 30 s before a repeat is due (the
    foreground sends the alert engine a tick, as a wake does), and again 3 s after one starts
    ringing. Repeat with a real sensor wake in step 3L or 3P if one happens to coincide.
  - Expect: the alarm still rings / keeps ringing.
  - Record: result.
- [ ] **Revoke alarms with a repeat pending** (alerts.md §10.3b).
  - Do: with repeats pending, turn the app's alarm permission off; later back on.
  - Expect: "Urgent low alarm is off" banner while revoked; after re-allowing, nothing stale rings.
  - Record: anything that rang.
- [ ] **Media volume at zero** (alerts.md §10.6).
  - Do: media volume 0, ringer on; trigger a Low.
  - Expect: Settings › Alert delivery shows the volume warning and the "Alarm volume is low"
    banner; the notification sound still plays.
  - Record: result.
- [ ] **Quiet hours** (D27).
  - Do: set quiet hours around now; trigger a Low, then urgent low.
  - Expect: Low posts silently; urgent low sounds.
  - Record: result. Turn quiet hours off.
- [ ] **Grace-period reminder while suspended** (D43, alerts.md §10.7).
  - Do: `sensorExpiry` from minute 0 at 1×; lock the phone for 35 minutes. Then repeat from minute 0,
    force-quit the app straight away, and don't reopen it until after +30.
  - Expect: the 2-hour reminder posts at once, written for the time left ("Sensor expires in … (at
    …)"); at +30 "Sensor session ended — 12 h grace period" arrives on time with the app suspended,
    and also after the force-quit; opening the app afterwards posts nothing a second time. The
    24-hour reminder's silence is checked with a real sensor (step 3L or 5).
  - Record: arrival times.
- [ ] **Urgent low re-alarms at snooze end without a reading** (D44, alerts.md §10.7a).
  - Do: alarms allowed (iOS 26+), quiet hours on around now, ringer off; `slowFallToUrgentLow` from
    80; acknowledge the urgent low at +85 (Stop, or Acknowledge on the notification); lock the phone
    at once and leave it. A suspended app gets no replay readings: the same as the sensor out of
    range.
  - Expect: at the snooze end (30 minutes later) urgent low rings again: an AlarmKit alarm on iOS
    26+ (otherwise the notification, vibrate-only on silent while suspended); the notification reads
    "Snooze ended. Last reading … mg/dL at …" with the last reading the app saw; it repeats every 5
    minutes until acknowledged; quiet hours don't silence it.
  - Record: ring times and texts. Quiet hours off again.
- [ ] **Urgent low hands over to Low in the recovery band** (D51).
  - Do: `slowFallToUrgentLow` from minute 100 (43 mg/dL: urgent low fires at once); acknowledge it
    about 2 minutes after it fires, so the snooze ends around +132, two minutes after the 60 mg/dL
    reading at +130. Keep the app open.
  - Expect: at the snooze end no urgent-low alarm (the 60 removed it); **Low** fires (Dusk), because
    60 is in the 56–60 band.
  - Record: what sounded, and when.
- [ ] **Trio handoff and uploads are off for replay** (S6, D20).
  - Do: with Live outputs off (default), turn on Trio handoff and Nightscout upload and run a
    scenario. Then turn Settings › Developer › Live outputs on and run it again. Use no Nightscout
    credentials, or a test site — never the live one (D6).
  - Expect: off: Trio handoff and Sharing say "Paused: this is a DEBUG build…". On: still nothing
    written: Trio handoff's "Last write" doesn't change; diagnostics show `[bridge] Trio bridge:
    refused …` (the replay run gives the bridge no session, so Trio's App Group is never touched) and,
    with a test site, `[upload] … refused …`.
  - Record: result. Turn Live outputs and both toggles off again.

Then install the **Release** build over it (§3.3), in listen mode (§0), for everything below.

#### Step 1a — Import (Release; `docs/import.md`)

- [ ] **Nightscout import.**
  - Do: Settings › Data › Import history › Nightscout, Last 90 days.
  - Expect: progress with readings imported and the range covered; finishes without error.
  - Record: count, range, skipped counts.
- [ ] **Spot-check against Nightscout.**
  - Do: pick a few days; compare several readings (value and time) on Trends 1 D/3 D with the
    Nightscout site.
  - Expect: same values and times; 39/401 entries as LOW/HIGH; Trio-era LOW/HIGH as 40/400 (lost
    upstream).
  - Record: mismatches.
- [ ] **90-day Trends against Dexcom Clarity** for the same period.
  - Expect: close, not identical (different data sets and gap handling).
  - Record: TIR, mean, GMI, CV side by side.
- [ ] **Re-run the import.**
  - Expect: nothing new is stored.
- [ ] **Imported data is never current.**
  - Expect: Now doesn't show an imported reading as the current value; Trends footnotes imported
    data.
- [ ] **Optional: a redacted real Clarity CSV** to confirm the parser against the current export
  format (the test fixture is synthetic).

#### Step 2L — Listening on the current sensor (Release; g7-protocol §13 items 12–14)

Do §0 first. Then, over the first day:

- [ ] **The first follow.**
  - Expect, in diagnostics: `[ble] G7: listen: attaching to the Dexcom app's connection to DXCM..`,
    `listen: the Dexcom app's authenticated connection observed (wake N with proof)`, `[sensor] G7:
    listen mode: following DXCM.., serial DXCM..-xxxxxxxx`; then the session length (next item) and
    readings.
  - Record: time from launch to the first reading.
- [ ] **Where the session length came from** (item 13, D49).
  - Expect: `[sensor] G7: session length 907200 s, warm-up N s` either with no `one 52 query sent
    (D49)` line before it (an answer to Trio's own request was observed) or after one (this app's
    single query at the second authenticated wake was answered).
  - Record: which; and whether anything changed in the Dexcom app (alerts, readings, sensor status,
    errors) around the wake where `one 52 query sent` appears.
- [ ] **The glucose format the Dexcom app's traffic uses** (item 12; needs "Record raw glucose
  packets" on).
  - Expect: `[sensor] G7: raw listen packet <hex>` lines. Starting `4e`: the `0x4E` format; starting
    `31` and `25`: the `0x31`/`0x25` format. If both appear, no clock-mismatch banner (the two time
    bases agree).
  - Record: which, and any other opcode logged.
- [ ] **Status bytes in the `0x31`/`0x25` format** (item 14, review m8).
  - Record: any `listen: 0x31 status 0x…, 0x25 status 0x…; reading withheld` line (for example
    `0x81`, low battery in G6 terms): such readings are withheld, so report them.
- [ ] **Expiry equals the Dexcom app's** (item 14, review m1; §0 step 8).
  - Record: both, to the minute.
- [ ] **Lost wakes** (item 12, D50).
  - Record: per day, the count of `listen: no authenticated Dexcom app connection observed (n in a
    row)` lines and of "Readings interrupted" banners with `listenNoAuthenticatedConnection`. Report
    if it's often: each one is a wake without a reading in this app.
- [ ] **Readings match the Dexcom app's.**
  - Expect: same values; times within seconds; the trend arrow can differ at a boundary (this app
    maps the sensor's rate with its own thresholds).
  - Record: ten pairs.
- [ ] **The Dexcom app keeps working normally** over a day: no new errors, its own readings and
  backfill unchanged, no pairing prompts.
- [ ] **Calibration is refused here.** Now menu › Calibrate sensor… says "Calibrate in the Dexcom
  app: while listening, this app sends nothing to the sensor."
- [ ] **A real LOW or HIGH, if one happens** (D31, item 3).
  - Expect: this app shows LOW/HIGH (not a number); the `raw listen packet` lines around it are the
    capture.
  - Record: the time, this app, the Dexcom app, a fingerstick; export diagnostics the same day.
    **HIGH → 401 to Trio isn't relied on in closed loop until a HIGH has been captured** (D31).

#### Step 3L — 24-hour soak, listening (Release, app backgrounded)

The app stays in the background throughout. Listen mode has no backfill: a wake it misses stays a
gap in this app (the Dexcom app keeps its own history).

- [ ] **No gaps beyond sensor behaviour and lost wakes.**
  - Record: from the CSV, `source=sensor` rows per hour (12 expected) and each gap > 5 min with its
    cause (walk-away, reboot, force-quit, lost wake, unknown).
- [ ] **Walk out of range for 30+ minutes** (g7-protocol §13 item 8).
  - Expect: sensor state stays as last reported; missed readings fires 15 minutes after the last
    reading (vibrate only on silent while suspended, D17); the widget turns stale at 10 min and "No
    data" at 20. On return: readings resume; no backfill in this app.
  - Record: alert time and how it sounded; whether the Dexcom app backfilled as usual.
- [ ] **A staged alert at a background wake, ringer off** (D17 path while backgrounded; alerts.md
  §10.1 with a real wake).
  - Do: set High to 120 or Low to 100, whichever your current glucose will cross; ringer off; lock
    the phone; wait for the next reading.
  - Expect: at the sensor wake the app plays Summit or Dusk itself, plus a Time Sensitive
    notification.
  - Record: heard yes/no. Restore the thresholds.
- [ ] **Bluetooth off and on**, once with the app open and once with it suspended (phone locked).
  Keep it to a few minutes: it interrupts the Dexcom app and Trio's G7 plugin too.
  - Expect: open: "Bluetooth is off" banner and the Bluetooth alert (Warble); readings resume when it
    is on. Suspended: iOS reports the Bluetooth state only at the next wake, so the guaranteed signal
    is the missed-readings notification 15 minutes after the last reading (vibrate only on silent,
    D17).
  - Record: what arrived when.
- [ ] **Survives a phone reboot with readings flowing** (architecture.md "Known limits"; alerts.md
  §10.10).
  - Do: optionally first stage an alert (High at 120, as above) and snooze it from the notification.
    Reboot; don't unlock for 10 minutes; unlock; don't open the app.
  - Expect: no glucose alerts before the first unlock (known limit), but notifications scheduled
    before the reboot are kept and arrive (missed readings, reminders). After unlock the app is
    relaunched by the G7 and readings resume without opening it: the widget updates; diagnostics show
    `[app] waiting for the first unlock…`, `[app] protected data became available`, `[app]
    bootstrapped (launched by Bluetooth restoration: true)`. A staged snooze still holds: the alert
    doesn't sound again before its snooze ends.
  - Record: time from unlock to the first new reading; whether the snoozed alert re-sounded early.
    Restore the threshold.
- [ ] **Force-quit banner.**
  - Do: swipe the app away; wait 20 minutes; open it.
  - Expect: banner "No readings HH:MM–HH:MM" with "The app was force-quit (swiped away)…". No backfill
    in listen mode (step 3P checks it in primary mode).
  - Record: banner text.
- [ ] **State restoration after a system termination.**
  - Record: any `[app] bootstrapped (launched by Bluetooth restoration: true)` line not caused by a
    reboot, and whether readings continued around it.
- [ ] **Writes while locked for hours** (file protection, §4.5).
  - Do: leave the phone locked overnight.
  - Expect: the CSV has readings all night; no "History isn't being saved" banner or alert.
- [ ] **Sensor clock drift.**
  - Record: the largest `sensor clock anchor differs by N s` in 24 h; any `readings withheld` /
    re-anchor line. Continue in step 5.
- [ ] **Time zone change with quiet hours and pending notifications** (alerts.md §10.9).
  - Do: quiet hours on (e.g. 22:00–07:00); readings flowing, so missed-readings notifications and the
    expiry reminders are pending. Settings › General › Date & Time: Set Automatically off, pick
    another Time Zone (leave the time itself alone). Set Automatically back on afterwards.
  - Expect: no clock-mismatch latch (a zone change is not a clock change); within one wake
    diagnostics show `[alert] schedule …` for them again; Now shows times in the new zone; the next
    reminder's text shows the new zone's clock time.
  - Record: result. (The rebuild on a zone change comes from the Phase 3 AlertEngine pass,
    `p3-alerts` 1f113da.)
- [ ] **The current sensor's end, if it comes before you switch** (g7-protocol §13 item 9; D43).
  - Expect: the expiry reminders (24 h on the lock screen with no sound or vibration, 12 h, 2 h,
    grace period started, sensor expired), on time against the expiry the Dexcom app shows; the live
    grace countdown
    on Now; "Sensor expired" within two sensor wakes (~10 min) of the real end, and still after a
    relaunch; missed readings stays quiet while the sensor-expired alert is on (D39/D41). Listen mode
    never moves to a new sensor by itself.
  - Record: reminder times vs the Dexcom app's.

#### Step 3a — Widget (during the soak)

- [ ] **Medium widget on the Home Screen for the whole soak** (`docs/widgets.md`).
  - Expect: stale (muted number, "STALE · 10 min ago") at 10 min and "No data" at 20 min during the
    walk-away; never an old number presented as current.
  - Record: in `docs/widgets.md` › "Measured on device": typical and worst lag app → widget,
    unlocked, locked and in Low Power Mode.

---

### Part B — next sensor, primary mode, Dexcom app deleted

**Switch-over** (D46), in this order. Rollback at the end of this part.

1. Tell followers (step 4a) and invite any new Dexcom Follow followers in the Dexcom app.
2. When the current sensor ends (or when you change it), **delete the Dexcom app** from the phone.
3. This app: Settings › Sensor › CONNECTION › "Pair this app (Dexcom app removed)", and confirm "Pair
   this app". Listening stops and the followed sensor is dropped. Take the old sensor off, or expect
   "The sensor did not accept the pairing code" from it while the search continues.
4. If you use a Dexcom receiver as the reference, pair it to the new sensor first (slot 1).
5. Optional, for the notification check in step 2P: turn this app's notifications off in iOS Settings
   now (glucose alerts don't run during warm-up anyway).
6. Apply the new sensor and pair this app with its 4-digit code (step 2P). Warm-up follows.
7. Trio: **open loop**. Settings › Devices › CGM: delete the G7 plugin, Add CGM › xDrip4iOS. Then
   Settings › Services › Nightscout › Upload: Allow Uploading on, Upload Glucose off (check it after
   switching the CGM).
8. This app, once the first reading is in: Settings › Trio handoff › Hand readings to Trio on;
   Sharing › Nightscout (URL, token) and Upload readings on; Dexcom Share (credentials) on (§4.2,
   §4.3).

#### Step 2P — Primary pairing on the new sensor

- [ ] **Pairing prompt: Cancel, then Accept** (`docs/g7-protocol.md` §2.4, §13 item 1).
  - Do: enter the 4-digit code from the applicator; at the iOS pairing request tap **Cancel**; wait
    for the next wake; tap **Pair**.
  - Expect: after Cancel the banner "Pairing didn't finish" and the request again at the next wake
    (~5 min); after Pair, "Paired." Diagnostics: `[ble] G7: connection: notify … failed: <error>`
    (the Cancel), `[sensor] G7: ownership confirmed; key saved for short authentication`, `[sensor]
    G7: paired with DXCM…, serial DXCM…-xxxxxxxx`, `[ble] G7: authenticated`.
  - Record: the exact error for Cancel (to be confirmed on device); also what happens if you ignore
    the request until it disappears (timeout).
- [ ] **Session length and warm-up from the sensor** (`0x52`).
  - Expect: `[sensor] G7: session length 907200 s, warm-up <N> s`; the warm-up countdown in Settings
    and on Now.
  - Record: N (the captured 10-day value is 1620 s) and the first reading's time vs `endsAt`.
- [ ] **Notifications allowed after pairing** (alerts.md §10.8), if you turned them off in the
  switch-over.
  - Do: during warm-up, allow notifications in iOS Settings without killing the app.
  - Expect: diagnostics show `[alert] schedule sensorExpiring…` lines (the reminders were added
    again); a reminder whose add was refused is posted when its moment comes.
- [ ] **First reading and 5-minute cadence for 2 hours.**
  - Expect: about 24 readings in 2 h (CSV: `source=sensor` rows), each matching the receiver.
  - Record: a table of app time / app value / receiver time / receiver value, plus two fingersticks.
- [ ] **Calibration round trip** (D16; g7-protocol §13 item 5).
  - Do: a fresh fingerstick; Now menu › Calibrate sensor…; enter and re-type it.
  - Expect: accepted within one or two wakes; the following display-only value is not shown as a
    reading (`[sensor] G7: glucose: display-only (calibration) value; not published (S1)`).
  - Record: wakes until accepted; how many readings were withheld as display-only.

#### Step 3P — Primary-mode checks during the first days

Repeat step 3L's items that apply to both modes if anything changed; in addition:

- [ ] **Receiver (slot 1) and app (slot 2) side by side for 24 h** (slot hypothesis, g7-protocol §9,
  §13 item 4).
  - Expect: both keep receiving.
  - Record: any receiver signal loss; any "The sensor no longer accepts this phone" in this app. If
    the receiver stops, the hypothesis is wrong: continue with the meter only.
- [ ] **Times match the receiver within seconds** (spot-check five).
- [ ] **Walk out of range for 30+ minutes, with backfill** (g7-protocol §13 items 2, 8).
  - Expect: missed readings fires at 15 minutes; on return, backfilled readings at their original
    times (CSV `is_backfill=true`), no duplicate times, the chart gap closed; in Trio too (step 4).
  - Record: backfill count; any gap left.
- [ ] **Force-quit, with backfill.**
  - Do: swipe the app away; wait 20 minutes; open it.
  - Expect: the force-quit banner (step 3L) and backfill filling what the sensor still holds.
- [ ] **Backfill floor** (g7-protocol §13 item 11).
  - Do: once, terminate the app right after a wake (or while "History isn't being saved" shows).
  - Record: which records the G7 sends on Backfill at the next wakes, whether a reading already
    delivered live is sent again, and whether `published again (m1)` lines appear after the relaunch.

#### Step 4 — Trio handoff (open loop first, then closed loop)

- [ ] **Trio reads this app.**
  - Expect: this app's Trio page: App Group `group.org.nightscout.<TEAM_ID>.trio.trio-app-group`,
    Heartbeat "published", a recent "Last write". Trio's CGM screen: "CGM address :" + UUID.
  - Record: both.
- [ ] **First reading in Trio** (trio-bridge.md "On-device checks").
  - Expect: same value and time (to the minute) as this app; the direction arrow matches.
- [ ] **Loop cadence, phone locked, both apps backgrounded, 30+ minutes** (heartbeat).
  - Expect: Trio's loop runs about every 5 minutes, within a minute of each sensor wake
    (g7-protocol §13 item 6).
  - Record: Trio's loop times against the reading times (CSV) for one hour.
- [ ] **Walk out of range 30+ minutes.**
  - Expect: backfilled readings appear in Trio at their original times.
- [ ] **No "Trio isn't getting readings" or "Trio may not loop in the background" banner** during
  normal operation.
- [ ] **LOW/HIGH, if one happens** (D21, D31).
  - Expect: this app shows LOW/HIGH; Trio 39/401 at the reading's time.
  - Record: the time, this app, the receiver, Trio, a fingerstick; with "Record raw glucose packets"
    on, the `raw primary packet` lines around it are the capture (D47). Don't rely on HIGH → 401 in
    closed loop until a HIGH has been captured, here or in step 2L (D31).
- [ ] **Closed loop once satisfied.**
  - Do: repeat the locked 30+ minute cadence check in closed loop.

#### Step 4a — Followers (`docs/following.md`)

- [ ] **Tell followers before switching**; send them `docs/following.md`.
- [ ] **Each reading appears once in Nightscout within a minute.**
  - Expect: device "Sensor" (the display name); no second entry from Trio.
  - Record: lag for ten readings; duplicate count.
- [ ] **Offline queue.**
  - Do: Wi-Fi and cellular off for 15 minutes, then on.
  - Expect: "Waiting to upload N" in Sharing; afterwards the entries appear with their original
    times, once.
- [ ] **Nightscout LOW** (D29), if one happens: Nightscout shows "LOW"; LoopFollow alarms.
- [ ] **Dexcom Follow** (D30): a follower confirms Dexcom Follow updates; on a LOW/HIGH it shows
  LOW/HIGH (not 39/401) and alarms. If not, revert to withholding LOW/HIGH (`docs/following.md`) and
  tell followers.

#### Step 5 — Full sensor session (10 days + 12 h grace)

The first full session in primary mode. Keep the rollback below possible until it is done (your
Dexcom account, and the Dexcom app one reinstall away).

- [ ] **Missed readings per day.**
  - Record: from the CSV, 288 − `source=sensor` rows per local day; Trends data sufficiency.
- [ ] **Alert correctness.**
  - Record: every alert: time, kind, correct or not (meter/receiver), heard or not (ringer state,
    locked, Focus).
- [ ] **Battery.**
  - Record: iOS Settings › Battery, this app's share per day.
- [ ] **Expiry reminders** (D43, alerts.md §10.7).
  - Expect: 24 h ("Sensor expires in 24 hours", on the lock screen, **no sound or vibration**), 12 h,
    2 h, "Sensor session ended — 12 h grace period", "Sensor expired", each on time with the app
    suspended; opening the app afterwards posts nothing a second time; the sensor reporting the end
    after the "Sensor expired" reminder plays its sound without a second banner; the live grace
    countdown on Now while the app is open.
  - Record: arrival times.
- [ ] **Session end** (g7-protocol §13 item 9): "Sensor expired" within two sensor wakes (~10 min)
  of the real end, also if the app was terminated between them, and still after a relaunch; missed
  readings stays quiet while the sensor-expired alert is on (D39/D41).
- [ ] **Sensor clock drift over the session** (g7-protocol §13 item 7).
  - Record: the largest "anchor differs by N s"; each re-anchor or clock-mismatch banner. Tell the
    orchestrator if it happens more than rarely.
- [ ] **Urgent low in real life**, if one happens (also in Part A, as a second alarm): the alarm,
  repeats, Stop, the snooze-end alarm (D44); record what you heard.
- [ ] **Stop from a cold launch** (alerts.md §10.7b), if a real urgent low rings while the app isn't
  running: tapping Stop launches the app, which acknowledges and schedules the snooze-end alarm and
  its repeats in one batch.
  - Expect: diagnostics `[alert] schedule urgentLow: 12 pending from <snooze end>` (at the default
    5-minute repeat), and the snooze-end alarm rings on time.
  - Record: if the line or the alarm is missing, report it (iOS may have suspended the app between
    the two; a reading within ~5 min re-plans it).
- [ ] **Optional: a DST night** (alerts.md §10.9), if the session spans one (US fall-back: Sunday
  1 November 2026): quiet hours 22:00–07:00. Expect quiet hours to start and end at the local clock
  times on both sides of the change, urgent low never silenced, and reading times unchanged.
- [ ] **Not stageable: the clock changed, or the phone rebooted, during an urgent-low snooze**
  (alerts.md §10.5, §10.10). The replay alert service runs on the replay clock without the monotonic
  clock (`App/Sources/Composition/ReplayRun.swift`), so a phone-clock change never reaches it, and the
  production engine needs a real urgent low. Expected if it ever happens: urgent low sounds again no
  later than 30 real minutes after the snooze began, and at once when a rollback is detected (D44).
  The host tests cover the logic (`test_S7_clockMovedBackCannotExtendUrgentLowSnooze`,
  `test_S7_aClockMovedBackDuringTheSnoozeEndsItAndReAlarmsAtOnce`, the Phase 3 reboot tests).
  Record "not tested" unless it happens.
- [ ] **The monotonic clock on the phone** (alerts.md §10.5). At each launch diagnostics show
  `[alert] monotonic clock: N s since boot, boot session … (kern.bootsessionuuid readable)`, or
  "boot session unreadable": then a clock rollback with no input in between is not detected (the
  latest-wall-clock fallback applies). Compare two such lines from launches hours apart, with the
  phone locked and asleep in between: the "s since boot" difference should match the wall-clock
  difference.
  - Record: readable or not; the two differences.
- [ ] **Trends 90 D on the phone**: "Computing…" disappears quickly (the < 100 ms requirement is
  only measured on the Mac).
- [ ] **Optional: dark mode** legibility on the phone (`docs/design-tokens.md`, "tune on device").

#### Step 6 — Report issues

- [ ] For each issue: Settings › Data › **Export diagnostics** (also in the Now menu), and the CSV
  export when values or times matter. Read the file before posting it anywhere public (§7.6: it
  holds readings, the sensor's name and serial, and the Nightscout host name). File it as an issue
  (GitHub once the repository is published) with the build, iOS version, steps, expected and actual.

#### Optional, with a spare sensor not used for treatment

This app must be paired with the spare sensor for these, so not on the phone that serves your
treatment sensor: use a second iPhone signed by the same team, or skip them. Never in listen mode
(they would also hit the Dexcom app).

- [ ] **Clock change** (widgets.md, g7-protocol §5.1). It costs up to the size of the change in lost
  readings.
  - Do: with the medium widget on the Home Screen showing a current reading, set the phone clock
    back 1 h (Settings › General › Date & Time, Set Automatically off). Watch Now and the widget.
    Then Set Automatically on again.
  - Expect: Now: "Phone clock doesn't match" / banner "No current reading"; the widget: "Check phone
    clock", not an old number as current; "Readings interrupted" with the clock message while G7Kit
    withholds readings. After the clock is fixed: the latch clears with the next newer reading;
    G7Kit publishes again once its re-anchor has settled (up to about the size of the change,
    `docs/g7-protocol.md` "The wedge"); missed readings fires meanwhile.
  - Record: how long until readings resumed; any reading published out of order; the widget's
    behaviour (into `docs/widgets.md`).
- [ ] **Another G7 app on the phone, primary mode** (D35, g7-protocol §3.1, §13 item 10).
  - Do: install xDrip4iOS, primary mode, "share to Trio" off, pair it to the spare sensor. Then, in
    this app, Pair again with the code. Remove xDrip4iOS afterwards.
  - Expect: if xDrip4iOS takes slot 2, this app shows "The sensor no longer accepts this phone…"
    (correct; it doesn't fight back on its own). After this app's Pair again, while its own
    authentication keeps succeeding: `[ble] G7: auth: unsolicited … ignored` lines,
    `rejectedAfterAuthentication` then `otherAppRejected` banners if the other app is being refused —
    **never** "Pair the sensor again" while this phone's key is accepted.
  - Record: what appeared, in order.
- [ ] **A 15-day sensor**, only if you have one.
  - Expect: "This sensor is not a G7 10-day sensor…", no readings, no calibration.

**Rollback from Part B** (not tested), in this order: in this app, turn the Trio handoff off (that
removes its readings and heartbeat keys from Trio's group; switching modes alone leaves them) and
both uploads; in Trio, xDrip4iOS → the G7 plugin, and Upload Glucose back on; reinstall the Dexcom
app and pair it to the sensor (it takes slot 2 back; this app then reports "The sensor no longer
accepts this phone": expected, don't Pair again); in this app, Settings › Sensor › CONNECTION ›
"Listen alongside the Dexcom app (this sensor)".

---

## 6. Renaming the app

"Sensor" is a working name (D1). Rename **before you install it on the phone**, and in any case
before the first pairing. Keep "Dexcom" out of the name and bundle ID (trademark, HANDOFF §1.1).

**Display name only** (`APP_DISPLAY_NAME` in `Config/Base.xcconfig`; or override it locally in
`Config/Signing.xcconfig`, which is included last). This loses nothing. It changes the home-screen
name, UI copy (`AppIdentity.displayName`), export file names, and the Nightscout `device` field of
new uploads (tell followers), and the Bluetooth and alarm permission prompts (`App/Info.plist`
uses `$(APP_DISPLAY_NAME)`). `PRODUCT_NAME` (the `.app`, module and test-host name, `project.yml`)
can stay.

**Bundle ID** (`BUNDLE_ID_PREFIX`, and `APP_GROUP_ID` if you want a matching group). iOS treats the
result as a different app. Nothing is migrated (there is no migration code):

| Lost or reset | Where it lived |
|---|---|
| reading history | the app's container (`Application Support/GlucoseStore`) |
| settings, alert settings, snoozes, the alert engine's state, pending reminders | `UserDefaults` of the old app; the old app's pending notifications keep firing until it is deleted |
| the sensor pairing and its J-PAKE key (or, in listen mode, the followed sensor); the Nightscout token; Dexcom Share credentials | the old app's Keychain items |
| the connection mode and the raw-recording switch (D45, D47); a new install starts in pairing mode | `Application Support/SensorConnection.json` |
| the widget | must be added again |
| diagnostics, upload queues | the old app's container |

The new app must pair again (a full J-PAKE in slot 2), which evicts the old app's key; delete the
old app afterwards, or two G7 apps share the phone (§7.2). Old history can come back only as
imported data from Nightscout (charts and statistics only, S6). For the new IDs, register the App
IDs and group as in §2.3. Trio's group is unaffected (it depends only on the Team ID). The
CoreBluetooth restore identifier and Keychain service names (`com.mzarras.sensor.…` in code) need no
change: they are scoped to each app.

---

## 7. Troubleshooting

### 7.1 Pairing and sensor errors

Every sensor failure carries a `SensorFailure.kind` (D36) and G7Kit's message
(`Packages/G7Kit/Sources/G7Kit/Source/G7FailureReason.swift`). Kinds marked **alert** raise the sensor
alert; the others are banners only, and if they stop readings for long the missed-readings alert
covers them.

| Message (start) | Kind | Meaning | What to do |
|---|---|---|---|
| "The sensor did not accept the pairing code." | `pairingRejected` **alert** | J-PAKE with your code failed: wrong code, or another nearby G7 answered first (it is then excluded and the search continues) | Check the 4-digit code on the applicator; Try again (new pairing) or Pair again (worn sensor) |
| "The sensor <name> refused the new code, and no other sensor accepted it." | `pairingRejected` **alert** | New pairing: only your previous, still-running sensor answered within 10 minutes | To keep the old sensor, enter its code; for a new one, check the new applicator's code |
| "The sensor no longer accepts this phone. Another device may have paired in the same slot." | `pairingRejected` **alert** | The saved key was refused: another collector took slot 2 (the Dexcom app, xDrip4iOS). Automatic reconnection stops, so the two don't fight | Remove the other app first, then Pair again with the worn sensor's code. Pair again claims the slot back |
| "The sensor needs to be paired again. Enter the 4-digit code…" | `pairingCodeNeeded` **alert** | A full pairing is needed and no code is stored | Enter the code |
| "The sensor removed its Bluetooth pairing with this phone." | `bondRemoved` **alert** | iOS reports the sensor dropped the bond | iOS Settings › Bluetooth › ⓘ next to the sensor › Forget This Device; then Pair again |
| "Bluetooth pairing with the sensor was not completed." | `bluetoothPairingIncomplete` | The iOS pairing request was cancelled or ignored | Nothing to type: accept the request at the next connection (≤ ~5 min) |
| "Authentication with the sensor failed." | `authenticationFailed` | A protocol failure in J-PAKE, certificates or proof | Retried at the next connection; if it persists, export diagnostics |
| "The sensor refused a connection after it had started." | `rejectedAfterAuthentication` | A rejection after this phone authenticated: the sensor revoking this phone, or another app on the shared link being refused | Wait: the next connection re-checks this phone's key |
| "Another app on this phone seems to be connecting to the sensor and being refused…" | `otherAppRejected` | The same, on consecutive connections whose own authentication succeeded | §7.2 |
| "The sensor's clock and the phone's clock disagree…" | `clockMismatch` | §7.3 | §7.3 |
| "The sensor sent a reading without a usable glucose value." | `noGlucoseValue` | Raw 0, `0x0FFF` or `0xFFFE`: withheld, never LOW/HIGH (D31) | Transient; if it persists, export diagnostics |
| "The sensor has not reported its session length yet…" | `sessionLengthUnknown` | `0x52` unanswered before the disconnect; no reading is used without it | Clears at the next connection |
| "The sensor's pairing could not be read from or saved to the Keychain." | `credentialsUnavailable` | Before the first unlock after a restart, or three failed saves in a row | Unlock the phone; the app retries by itself. If it persists for 15 minutes, Settings › Sensor offers Pair again with the worn sensor's code |
| "This sensor is not a G7 10-day sensor…" | `unsupportedSensor` **alert** | `0x52` reported a session length other than 10 days + 12 h | Use a G7 10-day sensor |
| "The sensor reported that it has failed…" / "…its session has stopped…" | `sensorFailed` / `sessionStopped` **alert** | Reported on two wakes (latched) | Replace the sensor |
| anything else | `other` **alert** ("Sensor problem") | A failure the source could not classify | Export diagnostics |

Listen mode (D45) has three messages of its own, all banners, never the sensor alert:

| Message (start) | Kind | Meaning | What to do |
|---|---|---|---|
| "Listening to the Dexcom app's connection, but the sensor's session length is not known yet…" | `sessionLengthUnknown` | No `52` answer observed yet; this app asks once at the second authenticated wake (D49) | Wait a few sensor wakes (about 15 minutes); if it persists, export diagnostics |
| "Listening for the Dexcom app's connection, but it was not seen authenticating the sensor at the last sensor wakes…" | `authenticationFailed` | Two wakes in a row without an observed authenticated `05`; those wakes give no reading here (D50) | Keep the Dexcom app installed, signed in and running (not force-quit). Occasional is expected; frequent: report it |
| "The sensor refused the Dexcom app's connection after it had started…" | `rejectedAfterAuthentication` | A rejection seen after the Dexcom app authenticated; that wake isn't used | Check the Dexcom app; the next wake is checked again |

While listening, calibration and pairing are not available here: the Now hero and Settings › Sensor
say "Calibrate in the Dexcom app…" and "Check the sensor in the Dexcom app…" instead. Listen mode
never moves to a new sensor by itself.

Before anything reaches the sensor, the app itself may refuse a code: not exactly four digits;
the pairing couldn't be saved (Keychain unavailable); "Pair again" with no stored sensor (use a new
pairing); listening (switch Settings › Sensor › CONNECTION to "Pair this app (Dexcom app removed)"
first, after deleting the Dexcom app); or, in DEBUG, a replay run is active.

The iOS pairing request appears after authentication, when the app first enables the encrypted
characteristics. While pairing, Settings › Sensor shows "Waiting for the sensor… It connects about
every 5 minutes." Nothing happens faster than the sensor's next advertisement.

### 7.2 Another G7 app on the phone

In listen mode (§0) the Dexcom app is expected: this app follows the Dexcom app's connection and
never competes with it. Everything below is about primary mode (Part B).

Only one app can be the sensor's primary device. Remove or turn off every other app that connects to
G7 sensors: the Dexcom G7 app, xDrip4iOS, and Trio's or Loop's own G7 connection (onboarding warns
about this). iOS gives all apps on the phone one shared link per sensor, so another app's
authentication traffic reaches this one too. Symptoms:

- "Pair the sensor again" / "The sensor no longer accepts this phone": the other app took slot 2.
  Remove it, then Pair again (evicting the other app is deliberate and only ever your action).
- "Readings interrupted" with "Another app on this phone seems to be connecting…" (`otherAppRejected`):
  the other app is being refused on the shared link and cutting connections short; this phone is
  still accepted.
- Residual risk accepted in D35: if another primary-mode app's success packet lands between this
  app's request and the sensor's real answer, at most one live reading per race is published that
  was not authenticated to this app (it is still real data from this sensor).
- xDrip4iOS with "share to Trio" writes the same App Group key, and its old heartbeat keys can stay in
  Trio's group. With the handoff on, this app checks the group on every heartbeat update and rewrites
  or removes foreign keys.

### 7.3 "Phone clock doesn't match" / "No current reading" / "Check phone clock"

Two independent mechanisms, one cause: the phone's clock moved.

- **The app's latch (S1).** The latest reading is dated more than 60 s ahead of the phone clock, or
  the wall clock moved more than 60 s differently from the monotonic clock between two checks. Now
  shows "Phone clock doesn't match" in place of the number, the banner reads "No current reading",
  the widget "Check phone clock", and calibration is unavailable ("fix Date & Time first"). The latch
  survives relaunches and clears only when a **newer** reading arrives.
- **G7Kit (S3).** The sensor's clock disagrees with the stored session start by more than 30 s:
  "Readings interrupted" with "The sensor's clock and the phone's clock disagree…"; readings are
  withheld. Two agreeing wakes re-anchor the session. After the clock was set **back** by Δ,
  readings stay withheld until real time passes the newest published one, about Δ, and the readings
  of that window are lost (the "wedge", `docs/g7-protocol.md` §5.1). Missed readings fires meanwhile.

Fix: Settings › General › Date & Time › Set Automatically on, then wait for the next readings. In a
DEBUG replay above 1× the Now screen shows this by design.

### 7.4 "History isn't being saved" / "Readings aren't being saved yet"

- **"Readings aren't being saved yet"**: the phone hasn't been unlocked since it restarted, so the
  database (and Keychain) are locked by design; readings are held in memory. Unlock the phone.
- **"History isn't being saved"**: the database couldn't be opened or written (a full disk is the
  likely cause). Live readings still go to alerts and Trio (D42); charts, statistics and uploads miss
  them until it recovers, and the "History isn't being saved" alert fires after 5 minutes (sound on
  silent off by default). Settings › Data shows the error. Free space (iOS Settings › General ›
  iPhone Storage); every wake and every foreground retries, and waiting readings are stored first.
  Up to 10 000 readings wait in memory; if iOS terminates the app before the store recovers they
  are lost from history (Trio and alerts already had them). Diagnostics: `[store]` lines.

### 7.5 Trio not looping

Work down the list:

0. **Listening?** Then the handoff is off by design (D45) and Trio must be on its own G7 source (§0).
   The rest of this list is for Part B.
1. This is a **Release** build (no DEBUG banner). In DEBUG the handoff is paused (D20).
2. This app › Settings › Trio handoff: **on**; App Group = `group.org.nightscout.<TEAM_ID>.trio.trio-app-group`
   with *your* Team ID ("missing from this build" means `TrioAppGroupID` didn't expand: fix
   `Config/Signing.xcconfig` and rebuild); "Last write" recent; Heartbeat **published**.
3. Trio › Settings › Devices › CGM is **xDrip4iOS**, and its screen shows **"CGM address :"** + UUID.
   "CGM is not used as heartbeat." means Trio has no heartbeat: on DASH, Dana and Medtrum it then
   doesn't loop in the background. The keys are published only while a sensor is paired and the
   handoff is on; toggling the handoff off and on rewrites them.
4. A banner "Trio may not loop in the background" means the heartbeat keys couldn't be written;
   "Trio isn't getting readings" means writes are failing, or Trio has had none of the live readings
   for 15 minutes (starving).
5. Same Team ID for both apps (§2.2). A mismatch is invisible to both apps: this app writes, Trio
   never sees it. The "CGM address" line (3) is the check.
6. Trio refuses to loop on glucose older than 12 minutes ("Glucose data is stale…"), so a sensor gap
   stops the loop; that is the missed-readings alert's job, not the bridge's.
7. Whether Trio actually *reads* cannot be detected from this app (D22): Trio writes nothing back.

### 7.6 Reading the diagnostic log

Export: Settings › Data › Export diagnostics, or the Now menu › Export diagnostics → share sheet. File
`<Name>-diagnostics-YYYYMMDD-HHMMSS.txt`, one event per line:

```
2026-09-23T12:00:00.000Z [ble] G7: connected
```

Times are **UTC**. The log keeps the last 5 000 events, is saved to
`Application Support/Diagnostics/diagnostics.json` when the app goes to the background and every 100
events, and is read back at launch, so events before an iOS relaunch survive (saves fail before the
first unlock after a reboot; those events stay in memory). Categories: `ble`, `sensor`, `store`,
`bridge`, `upload`, `alert`, `importer`, `app`. G7Kit's lines start with `G7: `, the Trio bridge's
with `Trio bridge: ` or `Trio coordinator: ` (left out in the table).

| Look for | Means |
|---|---|
| `[ble] scanning for the sensor`, `found DXCM..; connecting`, `connected`, `authenticated`, `disconnected` | the ~5-minute cycle |
| `[sensor] paired with DXCM.., serial …`, `ownership confirmed; key saved…` | a pairing completed |
| `[sensor] session length 907200 s, warm-up N s` | the sensor's `0x52` |
| `[sensor] state …` | every sensor state change |
| `[sensor] glucose: … not published` | why a sensor value was withheld (status, state, no value, display-only, duplicate, order) |
| `[sensor] sensor clock anchor differs by N s`, `…disagrees with the session start…; readings withheld`, `…re-anchored…` | clock drift and §7.3 |
| `[sensor] gate refused reading …` | `LiveReadingGate` refused a reading before storage (S2, D38) |
| `[ble] auth: unsolicited … ignored`, `[sensor] authentication rejection after authenticating (n in a row)` | another app's traffic on the link (§7.2) |
| `[bridge] Trio bridge: wrote N reading(s) to Trio, newest …`, `refused …`, `heartbeat peripheral set to …`, `FAILED` | the Trio handoff |
| `[upload] …` | uploads, refusals, credential changes |
| `[alert] schedule <kind>: N pending from …`, `cancel …` | pending notifications and alarms |
| `[store] holding N reading(s) for the database…`, `stored N reading(s) that were waiting…` | §7.4 |
| `[app] bootstrapped (launched by Bluetooth restoration: …)`, `waiting for the first unlock…`, `…force-quit gap`, `clock mismatch latched for …` | launches, reboots, force-quits, §7.3 |
| `[alert] monotonic clock: N s since boot, boot session …` | at launch: whether clock-rollback detection has the boot session (§5 step 5) |
| `[sensor] connection mode: …`, `[sensor] raw glucose packet recording turned on (D47)` | the CONNECTION choice and the D47 switch |
| `[ble] listen: attaching to the Dexcom app's connection to DXCM..`, `listen: the Dexcom app's authenticated connection observed (wake N with proof)`, `[sensor] listen mode: following DXCM.., serial …` | listen mode finding and following the sensor (§0) |
| `listen: session length not observed; one 52 query sent (D49)` | this app's single `52` query in that connection |
| `[sensor] listen: no authenticated Dexcom app connection observed (n in a row)` | a lost wake (D50) |
| `listen: 0x31 status 0x…, 0x25 status 0x…; reading withheld` | a `0x31`/`0x25` reading with a non-zero status, withheld |
| `[sensor] raw listen packet <hex>`, `raw primary packet <hex>` | with "Record raw glucose packets" on: every glucose packet's bytes (D47, for D31) |

Never in the log: tokens, passwords, pairing codes, keys. Glucose packets' bytes are in it only while
"Record raw glucose packets" is on (they carry no code or key); without it, only malformed or unknown
packets are logged in hex. **In it**: readings (ids, dates, values), the sensor's name and serial
(`DXCM..-` + 8 hex characters of the iOS peripheral identifier) and the Nightscout host name. Review
it before attaching it anywhere public.
