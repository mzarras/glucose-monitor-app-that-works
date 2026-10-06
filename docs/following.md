# Following Michael's glucose

Michael is replacing the Dexcom app on his phone with **Sensor**, an open-source app that talks to
his Dexcom G7 directly. When the Dexcom app goes, Dexcom stops receiving his readings, so Sensor
uploads them itself. You can follow in any of the three ways below. **If you rely on alarms for
lows, you must switch to LoopFollow (section 2).**

## 1. Nightscout website (to look, not to be alarmed)

Open Michael's Nightscout site, **https://diabetes.mzarras.com**, with the follower link he sends
you (it contains a read-only token). It shows the current value, the arrow, and the last hours.
Keep the tab or home-screen bookmark open; the page updates itself.

- A reading below the sensor's range shows as **LOW**, above it as **HIGH** — never as a number.
- New readings appear within about a minute of the sensor sending them (every 5 minutes). After a
  signal gap, missed readings fill in when the sensor reconnects.
- **Nightscout's own alarms do not go off for a LOW.** The alarm sound on the web page and
  Nightscout's push/Pushover alarms ignore a LOW reading, and if a low alarm was already sounding
  (say at 45), Nightscout sends **"All Clear"** when the sensor drops to LOW. Do not rely on
  Nightscout's own alarms for lows; use LoopFollow (below). HIGH does raise Nightscout's high
  alarms.

## 2. LoopFollow — required if you rely on alarms

If you want to be woken up, use **LoopFollow** (iOS), pointed at the same site and follower token.
It alarms on a LOW reading as a low (its low alarm fires for any reading at or below your
threshold, and LOW arrives as 39), shows LOW/HIGH as words, and has a **missing data** alarm.
Set your thresholds, and set the missing-data alarm (e.g. 20 minutes): that is how you notice if
Michael's phone stops uploading.

Other follower apps work too, but check how they handle LOW before relying on them. For example,
**Nightguard** shows the raw numbers: **39 means LOW** and **401 means HIGH**.

## 3. Dexcom Follow (unchanged app, unofficial path)

If you already use the Dexcom Follow app, keep it: Sensor also uploads to Dexcom Share, which is
what Dexcom Follow reads. Two caveats:

- **Unofficial.** Dexcom does not publish this interface; Sensor uses the one the open-source
  community reverse-engineered (from xDrip4iOS). Dexcom can break it at any time without notice.
  Michael's app will tell him when it fails, but you will simply see no new data.
- **LOW and HIGH are sent the way other apps read them (39 and 401), but this is not yet
  confirmed.** Michael will check with a follower, during his first test with the new app, that
  Dexcom Follow shows LOW/HIGH (not the numbers 39/401) and alarms on them. Until he tells you it
  works, do not rely on Dexcom Follow for LOW/HIGH; if it does not work, he will turn it off and
  LOW/HIGH readings will not appear there at all.

If you rely on alarms, use LoopFollow (option 2); keep Dexcom Follow as a backup, not the only one.

## What changes when Michael switches

- Readings come from the same sensor, so values are the same. The trend arrow is computed from
  the sensor's own rate with the app's thresholds, so an arrow can occasionally differ from what
  the Dexcom app showed at a boundary (e.g. 45° vs. straight).
- In Nightscout, readings are labelled with the device **"Sensor"**.
- Michael will tell you the day he switches. Expect a short gap around the switch.

---

## For Michael: configuration

**Exactly one app uploads CGM readings to Nightscout: Sensor.** Turn off glucose (CGM) upload in
Trio; Trio keeps uploading its own data (loop status, treatments). How to do that in Trio and why
is in [docs/trio-bridge.md → Nightscout uploads](trio-bridge.md#nightscout-uploads). Nightscout
only merges two uploads of a reading if their timestamps match to the millisecond
(`sysTime` + `type`, cgm-remote-monitor `lib/server/entries.js:238-248`), so two uploaders would
produce doubled points and skew Nightscout's statistics.

**Nightscout token for Sensor** (entered in Sensor's settings, stored in the Keychain; never paste
it anywhere else). Nightscout's default roles cannot create entries except `admin`
(`lib/authorization/storage.js:140-148`), so in Nightscout → Admin Tools:

1. Roles → Add new role: name `sensor-uploader`, permissions `api:entries:create`.
2. Subjects → Add new subject: name `Sensor`, roles `readable, sensor-uploader`.
3. Copy that subject's access token into Sensor. Sensor sends it in the `api-secret` header, not
   in the URL (`lib/authorization/index.js:76-96, 194-200`).

**Follower links**: create a subject per follower (or one shared) with role `readable` and send
them `https://diabetes.mzarras.com/?token=<that subject's token>`. Revoke it by deleting the
subject.

**Alarms (PROGRESS D29).** Sensor sends LOW as sgv 39 and HIGH as 401: Nightscout displays them
as LOW/HIGH, and they are never a real reading (the G7's numbers are 40–400). But Nightscout's own
alarms skip 39 — `lib/plugins/simplealarms.js:21` only alarms when `mgdl > 39`, `lib/plugins/bgnow.js:96`
treats ≤ 39 as not a reading — and with no alarm active it auto-acknowledges a running one with
"All Clear" (`lib/notifications.js:151-152`, message at `:52`; cgm-remote-monitor 15.0.8). Tell
every follower who relies on alarms to use LoopFollow, which alarms on 39
(`Alarm/AlarmCondition/LowBGCondition.swift:23-26`). Nightguard shows 39/401 as raw numbers.

**Dexcom Share LOW/HIGH (PROGRESS D30).** Sent as 39/401, **unverified**: no source shows how
Dexcom Follow renders them. In HANDOFF §11 step 4a, with a follower, confirm Dexcom Follow shows
LOW/HIGH and alarms; if not, revert to withholding LOW/HIGH (`DexcomShareEGV.value(for:)` and
`DexcomShareUploadDestination.canRepresent`) and update section 3 above.

**Dexcom Share** (PROGRESS D7: on, region US). In Sensor's settings enter the Dexcom account name
and password (Keychain only) and the receiver/upload serial number assigned to the account — not
the G7 pairing code. Invitations to Dexcom Follow are managed in the Dexcom app; invite anyone new
**before** removing it. Wrong credentials are retried only every 30 minutes (also across app
relaunches) so the account is not locked out; saving new credentials retries at once.
