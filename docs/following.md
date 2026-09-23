# Following Michael's glucose

Michael is replacing the Dexcom app on his phone with **Sensor**, an open-source app that talks to
his Dexcom G7 directly. When the Dexcom app goes, Dexcom stops receiving his readings, so Sensor
uploads them itself. You can follow in any of the three ways below; nothing changes on your side
unless you want it to.

## 1. Nightscout website (the primary way)

Open Michael's Nightscout site, **https://diabetes.mzarras.com**, with the follower link he sends
you (it contains a read-only token). It shows the current value, the arrow, and the last hours.
Keep the tab or home-screen bookmark open; the page updates itself.

- A reading below the sensor's range shows as **LOW**, above it as **HIGH** — never as a number.
- New readings appear within about a minute of the sensor sending them (every 5 minutes). After a
  signal gap, missed readings fill in when the sensor reconnects.

## 2. A follower app with alarms (recommended if you want to be woken up)

Point a Nightscout follower app at the same site and follower token:

- **LoopFollow** (iOS) — alarms for low, high, and missing data; shows LOW/HIGH correctly
  (it treats ≤ 39 as LOW and ≥ 400 as HIGH: LoopFollow `Helpers/Globals.swift:16-20`).
- **Nightguard** (iOS, Apple Watch) — alarms and a watch face. It shows the raw number, so a
  reading of **39 means LOW** and **401 means HIGH** (Nightguard accepts any value above 10 as a
  reading: `nightguard/domain/BloodSugar.swift:45-47`).

Set your own alarm thresholds in the app, including a **missing data** alarm (e.g. 20 minutes):
that is how you notice if Michael's phone stops uploading.

## 3. Dexcom Follow (unchanged app, unofficial path)

If you already use the Dexcom Follow app, keep it: Sensor also uploads to Dexcom Share, which is
what Dexcom Follow reads. Two caveats:

- **Unofficial.** Dexcom does not publish this interface; Sensor uses the one the open-source
  community reverse-engineered (from xDrip4iOS). Dexcom can break it at any time without notice.
  Michael's app will tell him when it fails, but you will simply see no new data.
- **LOW and HIGH are not sent to Dexcom Share.** There is no documented way to send them there
  faithfully, and sending 40 or 400 instead would look like a real number. During a LOW or HIGH
  you will see the last numeric reading and then no new data until the sensor reads a number
  again. The Nightscout site and LoopFollow do show LOW/HIGH.

If you rely on alarms, use option 2; keep Dexcom Follow as a backup, not the only one.

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

**Dexcom Share** (PROGRESS D7: on, region US). In Sensor's settings enter the Dexcom account name
and password (Keychain only) and the receiver/upload serial number assigned to the account — not
the G7 pairing code. Invitations to Dexcom Follow are managed in the Dexcom app; invite anyone new
**before** removing it. Wrong credentials are retried only every 30 minutes so the account is not
locked out; saving new credentials retries at once.
