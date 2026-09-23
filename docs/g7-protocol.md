# G7 primary-mode protocol (G7Kit)

How `Packages/G7Kit` talks to a Dexcom G7 10-day sensor as the primary (authenticating) collector,
where every byte comes from, and what was deliberately left out. Written for audit (S8): every
protocol fact below cites a file and line.

**Sources** (read-only under `vendor-ref/`):

| Short name | What | Version |
|---|---|---|
| xDrip4iOS | `xdripswift/xDrip/BluetoothTransmitter/CGM/Dexcom/...` (GPL-3.0, ported) | tag `7.1.0`, commit `0370937` |
| G7SensorKit | LoopKit G7SensorKit as vendored in the owner's Trio fork, `Trio/G7SensorKit/` (MIT, *reference only*: no code copied; captured test vectors used as data) | `0c87905` |
| CGMBLEKit | LoopKit CGMBLEKit, `Trio/CGMBLEKit/` (MIT, one test vector used as data) | `98fae79` |

File:line citations without a repository name refer to xDrip4iOS paths under
`xDrip/BluetoothTransmitter/CGM/Dexcom/` (`G7/…` or `Generic/…`) unless stated.

---

## 1. Scope

- **Primary mode only.** This app authenticates to the sensor itself with the 4-digit applicator
  code. xDrip4iOS's *coexistence* mode (observing a connection the Dexcom app authenticated) is not
  ported; the Dexcom app is removed from the phone (HANDOFF §4.6).
- **G7 10-day only.** A sensor whose `0x52` reports any session length other than 907 200 s is
  refused (§6.2). ONE+ (`DX02…`) and Stelo (`DX01…`) names are never connected.
- **No stop-session command.** xDrip4iOS 7.1.0 primary mode has no G7 session-stop command
  (`CGMG7Transmitter.swift` sends none); G7SensorKit only declares opcode `0x28`
  (`G7SensorKit/Messages/G7Opcode.swift:13`) and never sends it. Nothing verified exists to port,
  so `G7CGMSource.supportsStopSession == false` and Settings offers "Forget sensor" only.

## 2. Bluetooth

### 2.1 Advertisement, service, characteristics

| Item | UUID | Use | Source |
|---|---|---|---|
| Advertised service | `FEBC` | scan filter (works in background) | `G7/CGMG7Transmitter.swift:150-151`; G7SensorKit `BluetoothServices.swift:19` |
| Advertised name | `DXCM` + 2 chars | new-sensor filter; after connect `peripheral.name` may read `Dexcom…` | G7SensorKit `G7Sensor.swift:246-250` |
| CGM service | `F8083532-849E-531C-C594-30F1F86A4EA5` | everything below | `CGMG7Transmitter.swift:153-154` |
| Communication | `F8083533-…` | unused | `:133`, `:751` |
| Write_Control | `F8083534-…` | GetData `4E`, `52`, `34`, `32` requests; glucose/command responses; `59` | `:134` |
| Receive_Authentication | `F8083535-…` | small auth control packets (readable without link encryption) | `:135` |
| Backfill | `F8083536-…` | 9-byte history records (notify) | `:136` |
| Auth_Stream | `F8083538-…` | J-PAKE payloads, certificates, signatures, 20-byte fragments, write without response | `:137` |

All multi-byte fields are **little-endian** (`Generic/DexcomG7ExtendedVersionMessage.swift:35`),
except the lengths inside the J-PAKE hash (big-endian, §3.3).

### 2.2 Connection lifecycle (HANDOFF §4.6)

- The G7 advertises about every 5 minutes, accepts a connection for a few seconds, and disconnects
  itself after the exchange (`CGMG7Transmitter.swift:107-114`). G7Kit holds **no long-lived
  connection**: after every disconnect it issues `CBCentralManager.connect(peripheral)` again. That
  request never times out, so iOS connects at the next advertisement even with the app suspended
  (`Generic/…/BluetoothTransmitter.swift:313-317`; the 7.1.1 fix 00c144e8 relies on the same
  pending request, §10).
- Background mode `bluetooth-central` and `NSBluetoothAlwaysUsageDescription` are in
  `App/Info.plist` (checked, present).
- **State restoration:** `CBCentralManagerOptionRestoreIdentifierKey =
  "com.mzarras.sensor.g7kit.central"` (`G7Configuration.defaultRestoreIdentifier`). It is fixed
  (xDrip4iOS derived one per device or randomly, `BluetoothTransmitter.swift:1062-1098`) so iOS can
  relaunch the app for this central's events after a system termination. Never change it between
  releases. The app must create `G7CGMSource` early in launch. Restored peripherals are adopted; a
  restored *connected* peripheral is rediscovered so every characteristic is subscribed again
  (`BluetoothTransmitter.swift:1003-1040`).
- iOS does not relaunch a force-quit app; the gap banner is the app's job (HANDOFF §4.6).
- **Bluetooth state → `SensorState` (S5):** `.poweredOff/.unauthorized/.unsupported/.resetting` →
  `.bluetoothUnavailable(...)`; `.poweredOn` re-emits the last sensor state and reconnects;
  `.unknown` (startup) changes nothing (`G7SensorStatus.state(for:)`, `G7CoreBluetoothCentral.power`).

### 2.3 One connection, step by step (`G7ConnectionCycle`)

1. Discover the service and its characteristics; all of Write_Control, Receive_Authentication,
   Backfill, Auth_Stream must exist (`CGMG7Transmitter.swift:690-725`).
2. Notify **Auth_Stream first**, then Receive_Authentication: the sensor may announce a J-PAKE
   phase and immediately stream its payload (`Generic/DexcomG7AuthSession.swift:192-211`).
3. Authenticate (§3).
4. Notify Write_Control, then write `4E` once (`CGMG7Transmitter.swift:952-967`, `:1624-1642`).
5. On the `0x4E` response: notify Backfill (`:1165-1174`), then write the next control request,
   one at a time, each after the previous response: pending calibration `34`, else calibration
   record `32`, else `52` while the session length is unknown (`:1237-1248`).
6. Backfill records arrive on Backfill; `59` on Write_Control ends them (`:1010-1012`).
7. The sensor disconnects; undated backfill is discarded, dated backfill published (`:656-688`).

Nothing received on Write_Control or Backfill is used before authentication completes (S2).

### 2.4 The iOS pairing prompt

Accessing the G7's encrypted characteristics makes iOS establish an encrypted link and show the
system pairing request when needed (`CGMG7Transmitter.swift:45-49`). In practice this happens when
Write_Control (and Backfill) notifications are enabled after authentication.

- **Accept:** the notify succeeds and the connection continues; nothing else to do.
- **Cancel / ignore:** the pending operation fails with `CBATTError.insufficientAuthentication`,
  `.insufficientEncryption`, or `CBError.encryptionTimedOut` → `G7LinkError.pairingNotCompleted` →
  `SensorState.failed(G7FailureReason.bluetoothPairingNotCompleted)`, disconnect, and the pending
  reconnect stays, so iOS asks again at the next wake (~5 min). The J-PAKE key is already confirmed
  by then, so the next wake uses short authentication.
- `CBError.peerRemovedPairingInformation` → `.failed(bondRemovedBySensor)` (tell the user to
  forget the sensor in iOS Settings › Bluetooth).
- Tested with a fake link: `G7ControllerTests.test_pairingPromptCancelThenAccept`. The exact error
  code iOS reports for "Cancel" on a real G7 is **to be confirmed on device** (§13).

"Bonding data": iOS stores the link keys itself; apps cannot read them. The only bonding material
this app owns is the 16-byte J-PAKE shared key (§3.4).

## 3. Authentication

### 3.1 Short path (every normal wake; a confirmed key exists)

| # | Dir | Characteristic | Bytes | Source |
|---|---|---|---|---|
| 1 | → | Receive_Auth | `02` token(8 random) slot(1) | `Generic/DexcomG7AuthBridge.m:203-218` |
| 2 | ← | Receive_Auth | `03` tokenHash(8) challenge(8) | `Generic/AuthRequestRxMessage.swift:16-27` |
| 3 | → | Receive_Auth | `04` AES-128-ECB(key, challenge‖challenge)[0..<8] | `DexcomG7AuthBridge.m:220-261`, `:579-598`; `Generic/AESCrypt.m:14-31` |
| 4 | ← | Receive_Auth | `05` authenticated(1=yes) paired(2=no) | `Generic/AuthChallengeRxMessage.swift:16-27` |

Decision on `05` (`DexcomG7AuthSession.swift:463-475`, unchanged):

| Path | authenticated | paired | Action |
|---|---|---|---|
| short | yes | yes | authenticated → data |
| short | yes | no | drop the key, disconnect, full pairing next wake (`:422-434`) |
| short | no | any | **stop**: key rejected, probably another collector took the slot; no automatic re-pairing (it would evict that collector), `requiresNewPairing = true`, state `.failed(savedKeyRejected)` (`:409-420`, `CGMG7Transmitter.swift:969-979`) |
| full | yes | any | continue to certificates |
| full | no | any | wrong pairing code (or wrong sensor): `.failed(pairingCodeRejected)`, candidate key discarded (`:436-441`) |

The token hash (step 2) is checked only for the log: some firmware disagrees and the challenge is
authoritative (`DexcomG7AuthBridge.m:237-249`). Byte 2 of `05`: xDrip4iOS reads paired as
`!= 0x02`, G7SensorKit reads bonded as `== 0x01` (`G7SensorKit/Messages/AuthChallengeRxMessage.swift:24-25`);
they agree on every captured value (1, 2). G7Kit follows xDrip4iOS.

AES known answer used in tests: CGMBLEKit `TransmitterIDTests.swift:14-17` (same construction, G6 key)
and FIPS-197 C.1.

### 3.2 Full path (new sensor or new slot)

| # | Dir | Characteristic | Bytes | Source |
|---|---|---|---|---|
| 1 | → | Receive_Auth | `0A 00` open J-PAKE | `DexcomG7AuthBridge.m:188-201` |
| 2 | ← | Receive_Auth + Stream | `0A 00 00` + 160 B (G3 + proof) | `DexcomG7AuthSession.swift:264-272`, `:491-514` |
| 3 | → | Stream + Receive_Auth | 160 B (G1 + proof) in 20 B fragments 40 ms apart, then `0A 01` | `DexcomG7AuthBridge.m:375-393`; `DexcomG7AuthSession.swift:632-659` |
| 4 | ← | | `0A 00 01` + 160 B (G4 + proof) | |
| 5 | → | | 160 B (G2 + proof), `0A 02` | `DexcomG7AuthBridge.m:395-413` |
| 6 | ← | | `0A 00 02` + 160 B (B + proof) | |
| 7 | → | | 160 B (A + proof), then `02 token slot`; candidate key derived | `DexcomG7AuthBridge.m:415-434` |
| 8-10 | ↔ | Receive_Auth | `03` / `04` / `05 01 xx` as in §3.1, with the candidate key | |
| 11 | → | Receive_Auth | `0B 00 <len(partA) UInt32 LE>` | `DexcomG7AuthBridge.m:263-297` (LE is required: `:291-295`) |
| 12 | ← | + Stream | `0B 00 00 <size LE32>` + size B (sensor cert, ≤ 4096, not interpreted) | `DexcomG7AuthSession.swift:534-592` |
| 13 | → | Stream + Receive_Auth | part A (494 B) then `0B 01 <len(partB)>` | |
| 14 | ← | | `0B 00 01 <size>` + size B | |
| 15 | → | | part B (465 B) then `0B 02 00000000` | |
| 16 | ← | | `0B 00 02 00000000` | |
| 17 | → | Receive_Auth | `0C` + 16 random bytes | `DexcomG7AuthBridge.m:333-349` |
| 18 | ← | + Stream | `0C 00` challenge(16) (exactly 18 B) + 64 B sensor proof | `DexcomG7AuthSession.swift:594-605` |
| 19 | → | Stream + Receive_Auth | ECDSA-P256(partC, SHA-256(challenge)) as r‖s (64 B), then `0D 00 02` | `:607-630`; `Generic/DexcomG7ProofSigner.swift:17-24` |
| 20 | ← | Receive_Auth | `0D …` | `:284-292` |
| 21 | → | Receive_Auth | `06 19` keep-alive, 0x19 = 25 s | `:292`; `Generic/KeepAliveTxMessage.swift:11-19` |
| 22 | ← | Receive_Auth | `06 01` → **key confirmed**, authenticated | `:294-306`, `:480-489` |
| 22' | ← | | or `06 00` → `07` → `07 00` → `08 01` → key confirmed (older firmware) | `:308-334` |

The sensor's certificate bytes and its 64-byte proof are consumed but **not verified**, exactly as
xDrip4iOS 7.1.0. The candidate key is never stored before step 22 (`DexcomG7AuthBridge.m:557-562`).

### 3.3 J-PAKE on P-256 (`G7JPAKEClient`, port of `DexcomG7AuthBridge.m:351-935`)

Standard EC J-PAKE (RFC 8236) with Schnorr proofs (RFC 8235), the mbedTLS `ecjpake` conventions:

- Payload (160 B): public point X (64 B, raw x‖y) ‖ proof point V (64 B) ‖ proof scalar r (32 B)
  (`DexcomG7AuthBridge.m:51`, `:643-676`). Remote points are checked on-curve first.
- Proof: v random, V = base·v, h = SHA-256( len‖04‖base, len‖04‖V, len‖04‖X, len‖identity ) mod n
  with 4-byte **big-endian** lengths, r = v − h·x (`:678-728`, `:937-967`). Verify: base·r + X·h = V
  (`:766-802`). Identities: ours `"client"`, sensor `"server"` (`:46-49`).
- Password s = ASCII digits of the code as a big-endian integer (`:905-935`).
- Round 3: B's base is G1+G2+G3 (`:737-764`); A = (G1+G3+G4)·(x2·s) with a proof over that base
  (`:804-858`).
- Key: K = (B − G4·(x2·s))·x2; key = SHA-256(K.x)[0..<16] (`:860-903`).
- P-256 arithmetic: vendored micro-ecc `541b3a78026420a3e369c4c9281c396b5e531113` (BSD-2-Clause,
  `Sources/G7ECC/micro-ecc/LICENSE.txt`) compiled only through `DexcomG7ECC.c` (one translation unit,
  P-256 only, VLI API on), as xDrip4iOS does.

No captured J-PAKE vectors exist in either repository. Tests: P-256 primitives are checked against
CryptoKit (known answers); the full exchange round-trips against an independently written sensor
side (`Tests/G7KitTests/G7SensorSimulator.swift`, from RFC 8236); tampered and wrong-identity
proofs are rejected; a wrong code yields `pairingCodeRejected`.

### 3.4 Keys and storage

- The confirmed key belongs to one sensor **and one slot** (`DexcomG7AuthBridge.m:149-161`,
  `:505-519`). Stored in `G7PairingRecord` with the pairing code, sensor name, iOS peripheral
  identifier, serial, reported timing. Production store: `G7KeychainCredentialStore` — one
  generic-password item, `kSecAttrAccessibleAfterFirstUnlock` (reconnects happen while locked),
  not synchronizable. Tests: `G7InMemoryCredentialStore`.
- The pairing code and key are **never logged**.
- Fixed ownership credentials (`G7OwnershipCredentials`): KEKS parts A (CA cert), B (client cert),
  C (P-256 private scalar for B's key) — the same public constants Juggluco and xDrip+ send
  (`DexcomG7AuthBridge.m:36-44`). A test proves C's public key is the key inside B. Part B's
  `notAfter` is 2025-04-13; the sensor evidently does not check it (xDrip4iOS 7.1.0 pairs in 2026).

## 4. Messages used

| Opcode | Dir | Char. | Length | Layout (offset:size) | Source |
|---|---|---|---|---|---|
| `02` | → | RA | 10 | 0:1 op, 1:8 token, 9:1 slot | `DexcomG7AuthBridge.m:203-218` |
| `03` | ← | RA | ≥17 | 1:8 token hash, 9:8 challenge | `AuthRequestRxMessage.swift:16-27` |
| `04` | → | RA | 9 | 1:8 hash | `DexcomG7AuthBridge.m:256-260` |
| `05` | ← | RA | ≥3 | 1 authenticated (`==1`), 2 paired (`!=2`) | `AuthChallengeRxMessage.swift:25-26` |
| `06` | ↔ | RA | 2 | `06 19` out; `06 01` / `06 00` in | `DexcomG7AuthSession.swift:292`, `:480-489` |
| `07`,`08` | ↔ | RA | 1-2 | `07` out; `07 00`, `08 01` in | `:319-334`; `PairRequestTxMessage.swift` |
| `0A` | ↔ | RA | 2 / ≥3 | out `0A phase`; in `0A 00 phase` | `:264-272` |
| `0B` | ↔ | RA | 6 / ≥7 | out `0B phase len32LE`; in `0B 00 phase size32LE` | `DexcomG7AuthBridge.m:287-296`; `:534-564` |
| `0C` | ↔ | RA | 17 / 18 | out `0C chal16`; in `0C 00 chal16` | `:333-349`; `:594-605` |
| `0D` | ↔ | RA | 3 / any | out `0D 00 02` | `:619-626` |
| `4E` | → | WC | 1 | GetData | `CGMG7Transmitter.swift:1633-1641` |
| `4E` | ← | WC | 19 | see §4.1 | `Generic/DexcomG7GlucoseDataRxMessage.swift:53-129` |
| `52` | → / ← | WC | 1 / ≥15 | see §4.3 | `CGMG7Transmitter.swift:1373`; `DexcomG7ExtendedVersionMessage.swift:30-41` |
| backfill | ← | BF | 9 | see §4.2 | `Generic/DexcomG7BackfillMessage.swift:14-45` |
| `59` | ← | WC | 1 | backfill finished | `CGMG7Transmitter.swift:1010-1012` |
| `34` | → / ← | WC | 9 / 4 | §8 | `Generic/DexcomG7CalibrationMessages.swift:8-23`, `:135-165` |
| `32` | → / ← | WC | 1 / 20 | §8 | `CGMG7Transmitter.swift:1746`; `DexcomG7CalibrationMessages.swift:200-252` |

(RA = Receive_Authentication, WC = Write_Control, BF = Backfill.) No other message is sent.

### 4.1 `0x4E` glucose response (19 bytes)

| Off | Size | Field | Notes |
|---|---|---|---|
| 0 | 1 | `4E` | |
| 1 | 1 | response status | non-zero = status reply that may carry an old cached value; never published (`CGMG7Transmitter.swift:1031-1053`; G7SensorKit `G7GlucoseMessage.swift:87` rejects it) |
| 2 | 4 | **sensor clock** at transmission, s since session start | = the sensor-reported session age at receipt (§5) |
| 6 | 2 | sequence | |
| 8 | 1 | not decoded (`00` in all captures) | |
| 9 | 1 | not decoded (`01`; Dexcom log "session=1") | G7SensorKit `G7GlucoseMessageTests.swift:94-96` |
| 10 | 2 | **age**: s from the reading to this transmission | two bytes (G7SensorKit `:120-126`, `:128-133`) |
| 12 | 2 | glucose mg/dL, low 12 bits; `FFFF` = none | |
| 14 | 1 | algorithm state (§7) | |
| 15 | 1 | trend, Int8 tenths of mg/dL/min; `7F` = none | → `trendRate` exactly as reported |
| 16 | 2 | predicted, low 12 bits; `FFFF` = none | not used |
| 18 | 1 | flags; `0x10` = display-only | §5.4 |

### 4.2 Backfill record (9 bytes)

| Off | Size | Field | Notes |
|---|---|---|---|
| 0 | 3 | reading time, s since session start | G7SensorKit `G7BackfillMessage.swift:27-36` reads 3 bytes; xDrip4iOS 4 (`:23`); byte 3 is `00` in every capture |
| 3 | 1 | not decoded | |
| 4 | 2 | glucose, low 12 bits; `FFFF` = none | |
| 6 | 1 | algorithm state | decoded (G7SensorKit `:48`); xDrip4iOS ignored it |
| 7 | 1 | flags; `0x10` = display-only | G7SensorKit `:46`; xDrip4iOS used the glucose high nibble (`:31`); G7Kit treats either as display-only |
| 8 | 1 | trend, Int8 tenths; `7F` = none | |

### 4.3 `0x52` extended version (≥15 bytes)

2:4 session length in s **including** the 12 h grace; 6:2 warm-up s; 8:4 algorithm version;
12:1 hardware; 13:2 "max lifetime days" (12 for 10-day, not the session length)
(`DexcomG7ExtendedVersionMessage.swift:10-41`). Captured 10-day: `5200c0d70d00540600020404ff0c00`
→ 907 200 s, 1 620 s (xDrip Tests/`DexcomG7CalibrationTests.swift:231-239`).

## 5. Readings (S1–S4)

### 5.1 Timestamps (S3)

- **Bytes 2-5 of `0x4E` are the sensor clock at transmission; the reading happened `age` seconds
  earlier.** Session start = receipt time − sensor clock (G7SensorKit `G7Sensor.swift:129`).
  Reading sensor timestamp = sensor clock − age; reading date = session start + that timestamp.
- **This deviates from xDrip4iOS**, which treated bytes 2-5 as the reading time and added `age` to
  get the sensor age (`DexcomG7GlucoseDataRxMessage.swift:79-87`), putting session start `age`
  seconds early and backfill dates `age` seconds off. Evidence for G7Kit's reading: LoopKit's
  captured pair — live `4e00f9590200030200012a018f000610d9000f` (clock 154 105, age 298, 143 mg/dL)
  and the backfill copy of the same reading `cf5802008f00060f10` (timestamp 153 807 = 154 105 − 298)
  (G7SensorKit `G7GlucoseMessageTests.swift:120-126`, `:143-151`); and the startup vectors land on a
  300 s grid only after subtracting age (`:40-77`). With it, a live reading and its backfill copy get
  the **same id and the same date** (test `test_S3_liveAndBackfillCopiesShareIdAndDate`).
- The clock is re-derived from each connection's `0x4E` (never assumed, never "now" as a reading
  time). Backfill arriving before this connection's `0x4E` waits for it; records never dated are
  discarded at disconnect (`CGMG7Transmitter.swift:656-667`).
- `id = GlucoseReading.sensorID(serial:sensorTimestamp:)`; duplicates by sensor timestamp are
  dropped; a live reading must be strictly newer than every published reading; each backfill batch is
  published in ascending order with `isBackfill = true`.

### 5.2 Validity (S2) — a reading is published only if all hold

authenticated connection; `0x4E` status `00`; algorithm state `06` (G7SensorKit
`AlgorithmState.swift:104-115`; backfill: the record's own state byte); glucose ≠ `FFFF`; not
display-only; and `LiveReadingGate.validate` passes against the session derived from the same clock
(start ≤ date, warm-up ended, ≤ grace end, ≤ now + 60 s, value in range, serial). Anything refused is
dropped and logged to `DiagnosticLog`.

### 5.3 LOW / HIGH (S4)

The G7 has **no separate LOW/HIGH flag bit** in either reference. It reports the number itself and
its reportable range is 40…400 mg/dL: a number < 40 is LOW, > 400 is HIGH (G7SensorKit
`G7GlucoseMessage.swift:56-68`, `G7BackfillMessage.swift:82-94`, `GlucoseLimits.swift:11-13`).
xDrip4iOS passes the raw number through (`DexcomG7GlucoseDataRxMessage.swift:92-104`). G7Kit maps
< 40 → `.belowRange`, > 400 → `.aboveRange`, 40…400 → `.mgdl(n)` unchanged (`G7GlucoseRange`); never
40/400. **No captured LOW/HIGH packet exists in either repository**; the numbers a real LOW/HIGH
carries are unverified (every one of them maps to the flag) — verify on device (§13).

### 5.4 Display-only values (S1)

Flag `0x10` marks a value the sensor shows because of a calibration; LoopKit stores it as
`wasUserEntered` (G7SensorKit `G7CGMManager.swift:408-409`). A calibration is never a reading (S1),
so display-only values are not published (live or backfill). This drops at most the one reading that
follows a calibration.

### 5.5 Sensor serial

`serial = "<advertised name>-<first 8 hex of the iOS peripheral identifier>"`, e.g.
`DXCM4F-1A2B3C4D`, fixed at the first authenticated connection and stored. The name alone
(`DXCM`+2 chars, ~1 300 values; G7SensorKit matches on `suffix(2)`) would repeat across sensors,
and because sensor timestamps restart near 0 every session, `sensorID` collisions would make the
store's insert-or-ignore silently drop a later sensor's readings.

## 6. Session timing

### 6.1 `SensorSession` (all from the sensor clock)

`start` = receipt − sensor clock; `warmUpEndsAt` = start + warm-up; `expiresAt` = start + (session
length − 12 h); `gracePeriodEndsAt` = start + session length.

| Value | Reported? | Value used | Source |
|---|---|---|---|
| session length | yes, `0x52` | 907 200 s (10 d + 12 h) | `DexcomG7ExtendedVersionMessage.swift:14-15`; ConstantsDexcomG7.swift:15-16 |
| warm-up | yes, `0x52` | 1 620 s; default 27 min until `0x52` arrives | G7SensorKit `G7Sensor.swift:68` |
| grace | **constant** (included in the length) | 12 h | G7SensorKit `G7Sensor.swift:69`, `G7CGMManager.swift:115-117` |

`0x52` is requested after the first `0x4E` of a pairing (xDrip4iOS order) and stored; until then the
defaults (equal to what a 10-day sensor reports) apply. Dexcom's user-facing "30 minutes" is not
what the sensor reports; 30 min would refuse the first valid readings (≈28 min).

### 6.2 Unsupported sensors

A `0x52` session length ≠ 907 200 s (e.g. 15-day `5200406f1400880e…` = 1 339 200 s) →
`.failed(unsupportedSensor)`, no readings from that pairing, no calibration.

## 7. Algorithm states → `SensorState` (S5)

| Byte | Name | Category | `SensorState` |
|---|---|---|---|
| `06` | OK | ok | `.active` / `.gracePeriod` / `.expired` by the derived session |
| `02` | warm-up | warmUp | `.warmingUp(endsAt:)` |
| `01` | session stopped | stopped | `.warmingUp` before warm-up end (first message after activation reports it, G7SensorKit `:40-66`), else `.error(1, …)` |
| `04 05 07 0E` | BG(s) needed / calibration needed / outlier request | calibrationNeeded | `.error(code: byte, …)` |
| `08 09 0A 0D` | calibration errors / out of calibration | calibrationError | `.error(code: byte, …)` |
| `03 12` | excess noise / temporary issue | temporaryIssue | `.error(code: byte, …)` |
| `0B 0C 10 11 13-16 19 1B 25` | failed | sensorFailed | `.error(code: byte, …)` |
| `0F 18 1A 24` | expired / session ended | expired | `.expired` |
| other | unknown | unknown | `.error(code: byte, "Unknown sensor state 0x..")` |

Names: `Generic/DexcomAlgorithmState.swift:19-81`. `0x18`: xDrip4iOS calls it `questionMarks`,
G7SensorKit `expired` (`AlgorithmState.swift:38`) and its capture 7 h after expiry carries it; G7Kit
follows the capture. Only `06` ever publishes a reading, so these naming differences cannot leak
values. `SensorState` has no calibration case; the proposed contract refinement is in the WS1 report.

## 8. Calibration

### 8.1 Messages

- **`34` command** (9 B): `34` glucose(UInt16 LE, mg/dL) sensorTime(UInt32 LE) CRC-16/XMODEM(LE)
  (`DexcomG7CalibrationMessages.swift:8-23`; CRC `Generic/NSData+CRC.swift:11-60`). Vector
  153 mg/dL @ `0x0008840E` → `34 9900 0e840800 crc` (xDrip Tests `:5-11`).
- **`34` response** (4 B, no CRC): `34` response primary secondary (`:135-165`):
  primary 0 = accepted-high, 1 = accepted-low (secondary 0 accepted, 1 error0, 2 error1),
  2 = rejected (secondary = reason), 3 = factory-calibrated, else unknown.
- **Rejection reasons** (secondary byte, `:25-57`; each reported as
  `CalibrationStatus.rejected(code:reason:)` with this code): 0 unspecified, 1 outside range,
  2 timestamp in future, 3 duplicate, 4 earlier than session start, 5 not in order, 6 already
  entered, 7 disabled, 8 not permitted, 9 calibration bounds failed, 10 extreme outlier, 11 stale;
  other → "unknown reason n".
- **`32` record** (20 B): 1 response, 2 session number, 3:4 session signature, 7:2 glucose,
  9:4 calibration sensor time, 13 processing (0 none, 1 factory, 2 in progress, 3 complete-high,
  4 complete-low), 14 permitted (≠0), 15 originating display (2 phone, 4 receiver, …), 16:4 last
  update time (`:167-252`). Matches our calibration when glucose is equal and the time within 2 s
  (`:254-259`); a stale record for the previous calibration is ignored (`CGMG7Transmitter.swift:1890-1909`).

### 8.2 Flow (`G7CalibrationQueue`, port of `CGMG7Transmitter.swift:889-2069`)

`submitCalibration` → **refused** (typed `CalibrationRefusal`, nothing queued) unless paired,
authenticated (confirmed key, not rejected, supported sensor, a sensor-reported state exists), and
the sensor is running (`.active`, `.gracePeriod`, or `.error` in the calibration-needed /
calibration-error / temporary-issue categories); value in **40…400 mg/dL**
(`CGMG7Transmitter.swift:1967-1974`); one calibration at a time (queued, sent or awaiting the
record). Then:

1. `.queued` until the next wake.
2. After that wake's `0x4E`: re-check age (0 ≤ age ≤ 5 min, `ConstantsDexcomG5.swift:23-24` applied
   at `CGMG7Transmitter.swift:1971-1972` and `:1655-1674`); convert the fingerstick time with the
   connection's sensor clock: sensorTime = clock + (takenAt − receivedAt) (§5.1;
   `DexcomG7CalibrationMessages.swift:273-288`); write `34` → `.sent`.
3. `34` accepted (or duplicate/already-entered: an earlier copy is processing, `:1833-1835`) → ask
   `32` once per wake until the matching record says complete → `.accepted`; not permitted →
   `.rejected(8, …)`; other rejection → `.rejected(code, …)`; accepted-with-error / unrecognised /
   record state none → `.unknown(…)`.
4. Write failure or disconnect before the `34` response → `.queued` again, retried next wake
   (`:793-807`, `:2059-2069`).

Deviations: xDrip4iOS paired the clock field with `receivedAt − age`, shifting calibration times
`age` s into the future; G7Kit pairs it with the receipt time it describes. Sensor policy (not in
xDrip4iOS): a sensor record that never arrives ends the wait after 60 min as `.unknown`, and a newer
record from another display ends it as `.unknown`. A fingerstick in the future or older than 5 min at
submission is reported at once as `.unknown("Not sent: …")` because `CalibrationRefusal` has no time
case (proposed in the report).

S1: nothing in the calibration path creates a `GlucoseReading`; test
`test_S1_calibrationIsNeverEmittedAsReading` runs a full accept cycle plus the display-only echo.

## 9. Slot choice ("Bluetooth channel")

**What it is.** The last byte of the `0x02` authentication request selects one of the sensor's
independent authentication identities (`CGMG7Transmitter.swift:11-13`, `:164-165`;
`DexcomG7AuthBridge.m:203-218`). xDrip4iOS 7.1.0 offers (`Generic/AuthRequestTxMessage.swift:37-50`;
UI text `xDrip/Texts/TextsBluetoothPeripheralView.swift:340-378`):

| Byte | xDrip4iOS name | Intended owner |
|---|---|---|
| `01` | Slot 1: Receiver or Pump (`medicalDevice`) | Dexcom receiver or a compatible pump |
| `02` | Slot 2: Mobile App (default) | the phone app — "the currently validated native G7 connection" (`:368-370`) |
| `03` | Slot 3: Smart Watch | a directly connected watch |

Each slot holds its own J-PAKE key: xDrip4iOS stores keys per sensor **and** slot and never reuses a
key across slots (`DexcomG7AuthBridge.m:149-161`, `:505-519`; `DexcomG7AuthSession.swift:158-167`).

**Can this app and a Dexcom G7 receiver both be authenticated at once? Yes, in different slots.**
The receiver uses slot 1; this app pairs into slot 2. Distinct slots are distinct identities, which
is also how Dexcom itself runs a phone app and a receiver on one sensor.

**Which slot to use to coexist with a receiver:** slot 2 (`.mobileApp`), the default. The Dexcom
app also uses slot 2, which is why it must be removed (HANDOFF §4.6).

**What happens to a collector already using that slot:** completing J-PAKE ownership replaces that
slot's credential; the previous owner's saved key is refused at its next short authentication
(`authenticated = 0`). xDrip4iOS relies on this: it confirms a key only after ownership so a later
connection "can restore it instead of repeating ownership and replacing another app's authentication
credential" (`DexcomG7AuthSession.swift:297-302`), and it stops instead of re-pairing when its own
key is refused because "another app may now own this slot" (`:409-420`, `:460-462`). G7Kit does the
same (`requiresNewPairing`, `.failed(savedKeyRejected)`), so it never fights another collector.
Consequence: pairing this app into slot 1 evicts a paired receiver (xDrip4iOS's G6 warning says the
same, `TextsBluetoothPeripheralView.swift:320-321`); a Dexcom app left installed would evict this app
from slot 2 and vice versa.

**Recommended default and setting:** `G7Configuration.authenticationSlot = .mobileApp`
(`G7AuthenticationSlot.recommendedDefault`). It is an explicit, documented setting; changing it
requires a new pairing.

**Confidence:** derived from the xDrip4iOS 7.1.0 code and texts, not verified on hardware by this
workstream. §11 validation: pair the receiver first, then this app (slot 2), and confirm both keep
receiving readings for a day.

## 10. xDrip4iOS 7.1.0 → 7.1.1 review

`git log 7.1.0..7.1.1 -- '*G7*' '*Dexcom*'` lists two commits:

| Commit | What | Applies to primary mode? | Action |
|---|---|---|---|
| `00c144e8` Fix G7 coexistence reconnection between readings | In `CGMG7Transmitter`: coexistence keeps a pending connect for a known peripheral instead of relying on background scan callbacks; stops a stale scan on connect in coexistence. Every behavioural change is inside `useOtherApp` branches; the primary branches of `connectOnCentral` and `reconnectAfterDisconnect` are unchanged. | No code change for primary. Its lesson — background scan callbacks are not guaranteed; a pending `connect` is what reconnects — is already G7Kit's design (§2.2). | None to port; design confirmed. |
| `7ceb94c0` Waiting state after Dexcom warm-up | G6 (`CGMG5Transmitter`) warm-up report + Home/Live Activity "Waiting for first reading…". No G7 transmitter change. | No (G6 + UI). Concept for our UI: G7Kit keeps `.warmingUp(endsAt:)` until the sensor itself reports OK, so the UI can show "waiting for first reading" when `endsAt` is past. | None. |

## 11. Trio heartbeat (answer to the Trio workstream)

**What xDrip4iOS 7.1.0 publishes, and when.** Into the loop app's App Group
(`LoopShareType.trio` → Trio's suite): `cgmTransmitterDeviceAddress` = the CGM's
`CBPeripheral.identifier` UUID string, `cgmTransmitter_CBUUID_Service` = `F8083532-…`,
`cgmTransmitter_CBUUID_Receive` = `F8083535-…` Receive_Authentication
(`xDrip/Managers/BluetoothPeripheral/BluetoothPeripheralManager.swift:614-642`;
`CGMG7Transmitter.swift:875-876`). Written when the active CGM's address changes — i.e. on the first
connection to a new transmitter (`BluetoothPeripheralManager.swift:49-68`,
`BluetoothPeripheralManager+BluetoothTransmitterDelegate.swift:160-186`, called from
`didConnectTo`) — and only while sharing to the loop app is
permitted; removed otherwise and when the source is blocked (`:647-655`;
`xDrip/Managers/Loop/LoopManager.swift:797-806`). Trio reads them on its App Group poll and creates a
heartbeat central that retrieves the peripheral by identifier, pending-connects, subscribes to that
characteristic, and fires its heartbeat on every value and every disconnect
(`Trio/Sources/APS/CGM/HeartBeatManager.swift:25-72`, `BluetoothTransmitter.swift`; read for the
contract only — AGPL, nothing copied).

**Does a second central risk our connection, authentication or backfill?** Low risk, with reasons:

- iOS keeps **one** link per peripheral and multiplexes it between apps; the sensor sees one phone.
  Trio's connect adds no second connection and no contention for the wake window. Trio cancelling
  its connection does not drop ours while we hold it; the sensor ends the link itself.
- Trio subscribes to **Receive_Authentication**, which is readable without link encryption: xDrip4iOS
  coexistence and G7SensorKit subscribe to it without authenticating
  (`CGMG7Transmitter.swift:1611-1622`; G7SensorKit `G7Sensor.swift:197-207`), while Write_Control needs
  encryption (`CGMG7Transmitter.swift:758-763`). So Trio triggers no pairing prompt and never touches
  the data characteristics (Write_Control, Backfill); notifications are delivered to every
  subscribed app, so nothing is consumed from us.
- Trio writes nothing to the sensor, so it cannot interfere with J-PAKE or short authentication. It
  does *see* our authentication packets; they are designed to be safe on the air.
- Enabling the Receive_Authentication CCCD early does not make the sensor send anything by itself; the
  auth-stream-first ordering (§2.3) only matters for our own `0A 00`.
- Timing: the auth notifications arrive *before* our `0x4E` reading, so Trio's first heartbeat in a
  wake may find nothing new; its disconnect heartbeat comes after the reading was published. TrioBridge
  must have written the reading before the sensor disconnects (it is written during the connection).

What xDrip4iOS does to make it safe is precisely the choice of **Receive_Authentication** (not a data
characteristic) plus publishing/removing the keys with the source's permission.

**Recommendation:** follow xDrip4iOS's approach. Publish the three keys only when there is an
authenticated pairing and the Trio bridge is enabled; remove them on forget/unpair/disable. G7Kit
exposes `G7CGMSource.heartbeatTarget: G7HeartbeatTarget?` (peripheral identifier + the two UUIDs);
TrioBridge writes it. Re-read it after `pair`, `forgetSensor`, and on state changes. Verify on device
that Trio's loop cadence follows the sensor (§13).

## 12. What was stripped, and why

| Stripped from xDrip4iOS | Why |
|---|---|
| Coexistence mode (`useOtherApp`, `0x31`/`0x25` pairing, passive auth observation) | Primary only; the Dexcom app is removed (HANDOFF §4.6) |
| G5/G6/ONE/ONE+/Stelo/Libre/other transmitter types | Non-goals (HANDOFF §1.1); only the G7 10-day protocol is ported |
| Battery `0x22` and firmware `0x4A` requests | Diagnostics only; not needed for readings or safety; fewer bytes in the short wake window |
| Routine `0x32` requests without a pending calibration | Only needed for xDrip4iOS's calibration-permitted indicator |
| "Six identical values" filter (`CGMG7Transmitter.swift:1135-1141`) | A stalled sensor re-sends its *same* reading (the captured expired stream keeps timestamp 907 385), which S3 dedupe already collapses; the filter would also drop real flat readings. LoopKit/Trio's own G7 driver has no such filter. Reviewer's call (report) |
| Core Data, UserDefaults key storage, alert/UI/Activity Log/trace code | Replaced by `G7CredentialStore`, `DiagnosticLog`, and the app's own UI/alerts |
| ObjC bridge (`DexcomG7AuthBridge.m`) and its `objc_msgSend` call into Swift | Ported to Swift (`G7JPAKEClient`, `G7ChallengeHash`, `G7OwnershipCredentials`); the C ECC layer stays C |
| 6-digit pairing-code branch (`DexcomG7AuthBridge.m:926-929`) | G7 codes are 4 digits; codes must be ASCII digits (xDrip's `isNumber` also accepts non-ASCII digits) |

Layering for future sensor families (HANDOFF §1.1): `Messages/` (pure parsers), `Auth/`,
`Connection/` (link + cycle), `Session/` (clock, pipeline, status), `Calibration/`, `Credentials/`,
`Source/` (controller, CoreBluetooth adapter, public `G7CGMSource`). Another family would add its own
package or folder behind `CGMSource`; nothing G7-specific leaks into GlucoseCore.

## 13. To verify on device (cannot be proven by host tests)

1. First pairing: iOS pairing prompt appears; Accept continues; Cancel shows the pairing banner and
   the prompt returns at the next wake (§2.4 error codes).
2. Timestamps: app reading times match the receiver within seconds; a backfilled reading after a
   30-min walk-away lands exactly on the previously missing times (§5.1).
3. A real LOW/HIGH shows as LOW/HIGH, not a number (§5.3).
4. Receiver (slot 1) and app (slot 2) both keep receiving for 24 h (§9).
5. Calibration: accepted within one or two wakes; the following display-only value is not shown as a
   reading (§5.4, §8).
6. Trio heartbeat: Trio's loop runs within a minute of each sensor wake while locked (§11).
