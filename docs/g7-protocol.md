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

- **Two modes (D45).** *Primary*: this app authenticates to the sensor itself with the 4-digit
  applicator code and owns the connection (HANDOFF §4.6; the Dexcom app is removed). *Listen*: the
  Dexcom app on the same phone owns the connection and this app only observes it — no pairing code,
  no slot, and no write except one read-only `52` query per connection when the session length was
  not observed (§14, D49). Ported from xDrip4iOS's coexistence (`useOtherApp`) path
  without the commands it sends there. The app chooses the mode (`G7Configuration.mode`,
  `G7CGMSource.setMode`); G7Kit never switches by itself.
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
  `.bluetoothUnavailable(...)` (and the current connection is ended: CoreBluetooth sends no
  disconnect in that case); `.poweredOn` re-emits the last sensor state and reconnects; `.unknown`
  (startup) changes nothing (`G7SensorStatus.state(for:)`, `G7CoreBluetoothCentral.power`).
- **Sensor gone:** `state` is not changed when the sensor simply stops connecting — it stays
  `.active` (or whatever the sensor last reported). Signal loss is detected downstream from the age
  of the newest reading (HANDOFF S5 "no reading for 15 min"), not by G7Kit.
- **New-pairing connect timeout (Sensor policy):** a found sensor that has not connected within 60 s
  is given up (and, during a new pairing, not tried again) and scanning resumes. xDrip4iOS has the
  same mechanism with 5 s (`BluetoothTransmitter.swift:212`, `:643-654`).
- Connect/disconnect callbacks for any peripheral other than the paired sensor or the current
  candidate are ignored (a stray `didConnect` is disconnected immediately).
- **Pairing a new sensor (`pair(code:)` = `start(pairingCode:)`):** a fresh pairing record; the first
  advertising G7 (`DXCM…`) that connects and accepts the code is paired. Sensors that refused the
  code or did not connect in time are not tried again during that pairing. Exclusions are by
  CoreBluetooth identifier, never by name: G7 names are "DXCM" + 2 characters and repeat across
  sensors (re-review N1). The **previous sensor is ignored only when its session has ended or it was
  unsupported** (safety review M1, D37); a previous sensor that is still running may be the one
  being paired.
  - **Previous sensor refusing the new code (coordinator decision; re-review N1).** When the
    candidate that refuses the code has the previous record's `peripheralIdentifier` (the same
    physical sensor as seen by this phone — a matching name is not enough), the refusal is expected:
    it is logged to `DiagnosticLog`, the sensor is excluded for the rest of this pairing and scanning
    continues, **without** `.failed(pairingCodeRejected)` (that kind raises the sensor alert; it
    would be a false alarm while the user is deliberately pairing a new sensor). Its own pairing is
    untouched and nothing is published from it. This skip is **time-limited** (Sensor policy,
    `previousSensorSkipLimit` = 10 min from the pairing start, two sensor wakes): if no sensor has
    authenticated by then, or if the previous sensor's refusal comes after that, the state becomes
    `.failed(previousSensorRejectedCode(sensorName:))` (kind `pairingRejected`), whose message names
    the previous sensor and asks to enter its 4-digit code again if the person meant to keep using
    it, or to check the new applicator's code — they may be re-pairing the sensor they wear with a
    mistyped code. (No "Pair again" in the text: onboarding offers only "Try again", `pair(code:)`,
    which does reach the worn sensor.) A refusal from any other sensor (including a different sensor with
    the same name) is shown as `.failed(pairingCodeRejected)` at once. Tests
    `test_S5_previousSensorRefusingANewCodeIsSilentlySkipped`,
    `test_S5_sameNameDifferentIdentifierRefusalSurfaces`, `test_S5_previousSensorSkipIsTimeLimited`.
  - **Which call the app uses.** `G7CGMSource.hasStoredSensor` is true once this phone has
    authenticated to a sensor (serial and identifier stored; `storedSensorSerial` gives the serial).
    Then every code retry — including "try the code again" in onboarding after the sensor already
    authenticated — must call `pairAgain(code:)`, which never skips a refusal; `pair(code:)` is for a
    first pairing (`hasStoredSensor` false) and for deliberately pairing a different sensor. Test
    `test_S5_retryAfterAuthenticationUsesPairAgain`.
- **Pairing the same sensor again (`pairAgain(code:)`, D37):** for the sensor being worn after it
  refused this phone (`.failed` kind `pairingRejected`, e.g. another device took the slot, or a wrong
  code) or asked for the code (`pairingCodeNeeded`). It keeps the stored sensor's name, iOS identifier,
  serial, session start, session end and newest-reading mark, replaces the code, deletes the saved key
  and clears `requiresNewPairing`; the next connection to that sensor (pending connect by identifier,
  or found again by name) runs the full J-PAKE (§3.2) and saves the new key once the sensor confirms
  ownership. Readings keep their ids (same serial). It claims this phone's slot again, so another
  collector paired in the same slot loses it — the user's explicit choice; automatic reconnection
  never does this (§3.1, §9). A wrong code shows `.failed(pairingCodeRejected)` and waits for another
  `pairAgain`. Throws `G7StartError.noSensorToPairAgain` when this phone never connected to a sensor
  (use `pair(code:)`).
- **Credentials:** a pairing record that cannot be read (e.g. Keychain before the first unlock after
  a restart) is reported as `.failed(credentialsUnavailable)`, never `.notPaired`; the app should call
  `start(pairingCode: nil)` again once protected data is available (the message tells the person to
unlock the phone, and to pair again from Settings › Sensor only if it continues after unlocking). Saving the record (at least once
  per wake) keeps working in memory when it fails, but a relaunch would lose what was not saved; after
  3 consecutive failed saves (Sensor policy) every further failed save emits
  `.failed(credentialsUnavailable)` too, and a successful save clears the count.

### 2.3 One connection, step by step (`G7ConnectionCycle`)

1. Discover the service and its characteristics; all of Write_Control, Receive_Authentication,
   Backfill, Auth_Stream must exist (`CGMG7Transmitter.swift:690-725`).
2. Notify **Auth_Stream first**, then Receive_Authentication: the sensor may announce a J-PAKE
   phase and immediately stream its payload (`Generic/DexcomG7AuthSession.swift:192-211`).
3. Authenticate (§3).
4. Notify Write_Control. While the sensor has never reported its session length, write `52` first
   and wait for its answer (Sensor change: xDrip4iOS asks after the first reading,
   `CGMG7Transmitter.swift:1361-1389`, which would let a 15-day sensor publish one reading). Then
   write `4E` once (`CGMG7Transmitter.swift:952-967`, `:1624-1642`). If the connection ends with
   `52` unanswered (so no `4E` was sent), `.failed(sessionLengthUnknown)` is reported at the
   disconnect instead of leaving the status at "authenticating" (safety review P7); `52` is asked
   again next time.
5. On the `0x4E` response: notify Backfill (`:1165-1174`), then write the next control request,
   one at a time, each after the previous response: pending calibration `34`, else calibration
   record `32` (`:1237-1248`).
6. Backfill records arrive on Backfill; `59` on Write_Control ends them (`:1010-1012`).
7. The sensor disconnects; undated backfill is discarded, dated backfill published (`:656-688`).

Nothing received on Write_Control or Backfill is used before authentication completes, nor after a
`05` rejection ends it (S2; §3.1).

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
| 4 | ← | Receive_Auth | `05` authenticated(`01`=yes) paired(`01`=yes) | `Generic/AuthChallengeRxMessage.swift:16-27`; G7SensorKit `AuthChallengeRxMessage.swift:24-25` |

**Only solicited packets count (safety review B1; Sensor change).** iOS keeps one link per
peripheral and delivers every notification to every app subscribed to it, so another G7 app's
authentication traffic (the Dexcom app, xDrip4iOS) reaches us too. xDrip4iOS accepted any `05`
(`DexcomG7AuthSession.swift:262`, `:396-458`) — a stray `05 01 01` would have counted as our own
authentication, bypassing the pairing code. G7Kit accepts a `03` only after its own `02`, a `05` only
after its own `04` and only once, `0A` only during its own J-PAKE and for the phase it expects, `0B`/
`0C` only in the certificate stage, `0D`/`06`/`07`/`08` only in their stages; everything else is
logged and ignored. `paired` is byte 2 == `01` (G7SensorKit); xDrip4iOS used `!= 02` — they agree
on every captured value.

**A `05` rejection after authentication (safety review B1, N2, P9).** It may be the sensor refusing
this phone, or another app on the shared link being refused. It can also follow a spoofed success:
another app's `05 01 01` landing between our `04` and the sensor's real answer is indistinguishable
from our own and is taken as our answer, and the real `05 02 02` then arrives as a "later"
rejection (probe P1c). So, at once and in this order: the auth session leaves "authenticated" (the
connection forwards nothing more from Write_Control or Backfill), the controller finishes the
connection and discards its backfill not yet published, reports the state, and only then asks for
the disconnect. Whether the key is really gone is decided by the next connection's own, solicited
`05` (only that sets `requiresNewPairing` and shows `.failed(savedKeyRejected)`, "Pair again"). The
state is `.failed(rejectedAfterAuthentication)`; when it recurs on consecutive connections whose own
authentication succeeded, `.failed(otherAppRejected)` (another app on this phone is the likely cause).
A connection without a rejection resets the count.

**Accepted residual risk (PROGRESS.md D35).** The spoofed success cannot be told apart from our own.
If, inside the few milliseconds between the spoof and the sensor's real rejection, the other app's
genuine `0x4E` (the answer to *its* GetData, delivered to every subscriber of the shared link) reaches
us, that one live reading is published: it is real data from this sensor, but it was not
authenticated to us. Backfill from that window is discarded and nothing after the real rejection is
forwarded, so the exposure is at most one live reading per race. Holding live readings until the
disconnect would remove it but delay every reading to Trio by one wake (Trio's heartbeat reads at the
sensor disconnect, §11), so it is not done. The race needs a second primary-mode G7 app on the phone,
which setup forbids (HANDOFF §4.6); Phase 2 onboarding/diagnostics flag other G7 apps. Pinned by
`test_S2_residualP1cRaceIsBoundedToOneLiveReading` (if it starts failing because the reading is no
longer published, the risk is gone: update D35 and this paragraph).

Decision on the solicited `05` (`DexcomG7AuthSession.swift:463-475`, unchanged):

| Path | authenticated | paired | Action |
|---|---|---|---|
| short | yes | yes | authenticated → data |
| short | yes | no | drop the key, disconnect, full pairing next wake (`:422-434`) |
| short | no | any | **stop**: key rejected, probably another collector took the slot; no automatic re-pairing (it would evict that collector), `requiresNewPairing = true`, state `.failed(savedKeyRejected)` (`:409-420`, `CGMG7Transmitter.swift:969-979`) |
| full | yes | any | continue to certificates |
| full | no | any | wrong pairing code (or wrong sensor): `.failed(pairingCodeRejected)`, candidate key discarded (`:436-441`) |

The token hash (step 2) is checked only for the log: some firmware disagrees and the challenge is
authoritative (`DexcomG7AuthBridge.m:237-249`).

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

No captured G7 J-PAKE exchange exists in either repository. Tests:
- **Known answers from Mbed TLS** (v3.6.2, commit 107ea89, `library/ecjpake.c:838-977`, the EC J-PAKE
  self-test; `vendor-ref/mbedtls`): our proof check accepts all six Mbed TLS proofs (and rejects them
  under the wrong identity), and our client, given Mbed TLS's x1/x2 and fed its server messages as the
  three G7 phases, produces Mbed TLS's exact round-two point and premaster secret (`pms[0..<16]` is the
  G7 key). This pins the hash layout, identities, password encoding and key derivation.
- P-256 primitives are checked against CryptoKit (known answers).
- The full exchange (J-PAKE, certificates, proof, `06 01` and legacy `07`/`08 01`) round-trips against
  an independently written sensor side (`Tests/G7KitTests/G7SensorSimulator.swift`, RFC 8236);
  tampered and wrong-identity proofs are rejected; a wrong code yields `pairingCodeRejected`.

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
- **Session start is fixed per serial (safety review M2).** It is derived from the first status-0
  `0x4E` of the pairing and persisted with the pairing record; every reading is dated
  `sessionStart + sensor timestamp`, so dates do not jitter with transmission latency. Each later
  `0x4E` is an *anchor* checked against it:
  - within **30 s** (Sensor policy): agrees; nothing changes (no new `.active(sessionStart:)`);
  - beyond 30 s: this connection's readings are withheld, `.failed(sensorClockMismatch)` is reported,
    and the session is **not** moved; only a second anchor agreeing with the first disagreeing one
    (within 30 s of it) re-anchors the session. One garbled packet can neither move nor end a session.
  Every anchor more than 5 s off is logged, so drift over a session can be read from the diagnostics.
- **Dates follow sensor time (monotonic), live and backfill (safety review P4):** a reading is
  published only if its date lies strictly between the dates of the published readings just before
  and just after it in sensor time. With one fixed session start this always holds; it fails only
  after a re-anchor (the phone clock was changed), when the new dates would interleave with those
  already published. A live reading that fails it is withheld with `.failed(sensorClockMismatch)` (e.g.
  after the phone clock was set back: nothing is published "in the past"; readings resume when their
  dates pass the last published one). A backfill record that fails it is withheld the same way and the
  batch reports `.failed(sensorClockMismatch)`; a gap-filling record that still fits between its
  neighbours is kept. The newest published reading (sensor timestamp and date, `G7ReadingMark`) is
  persisted with the pairing record, so after a relaunch nothing is dated before it. Across a
  relaunch the rule is checked against that one mark only, not against every reading published
  before the relaunch (audit m15). Residual: if the phone clock changed and the new process
  re-anchored, a backfill record for a never-published sensor time *before* the mark is dated with
  the new anchor and can sit up to the clock change away from its stored neighbours. Its id still
  dedupes, alerts never evaluate backfill, and it is withheld anyway when it would land after the
  mark.
- **The "wedge" (accepted consequence of the rule above).** After a large backward move of the anchor
  (the phone clock was fast and is corrected, or is set back by hand by Δ), the session re-anchors
  after two agreeing wakes, and every new reading is then dated up to Δ earlier than the readings
  already published. Readings are withheld — with `.failed(sensorClockMismatch)` shown — until real
  time passes the newest published date, i.e. for about Δ. The readings of that window are **lost**:
  their dates stay before the newest published one, so neither the live copy nor a later backfill copy
  can ever be published. (Probe P4: Δ = 1 h → 12 wakes withheld.) The missed-readings alert fires from
  reading age during the window.
- **Note for downstream consumers (Phase 2 wiring).** In the same situation the newest *stored*
  reading is dated in the future by up to Δ (it was dated with the fast clock). Anything that judges
  freshness from the newest reading (staleness banners, missed-readings alert, Trio/Nightscout/Share
  upload freshness, widgets) must treat a reading dated after "now" as **stale**, not as fresh — it is
  never evidence that data is arriving.
- Backfill arriving before this connection's `0x4E` waits for an agreeing anchor; records never dated
  are discarded at disconnect (`CGMG7Transmitter.swift:656-667`).
- `id = GlucoseReading.sensorID(serial:sensorTimestamp:)`; duplicates by sensor timestamp are
  dropped; a live reading must be strictly newer (in sensor time and in date) than every published
  reading; each backfill batch is published in ascending order with `isBackfill = true`.
- Backfill received before a `05` rejection after authentication (§3.1) and not yet published is
  discarded with that connection.

### 5.2 Validity (S2) — a reading is published only if all hold

authenticated connection (solicited authentication only, §3.1); the sensor has reported a supported
session length (`0x52`); `0x4E` status `00`; algorithm state `06` (G7SensorKit
`AlgorithmState.swift:104-115`; backfill: the record's own state byte); the glucose field is a value
(§5.3); not display-only; the connection's anchor agrees with the session start (§5.1); dates
monotonic; and `LiveReadingGate.validate` passes against the session (start ≤ date, warm-up ended,
≤ grace end, ≤ now + 60 s, value in range, serial). Anything refused is dropped and logged to
`DiagnosticLog`; "no value", clock disagreement and an unknown session length are also surfaced as
`.failed(_:)` (S5, §7.1).

### 5.3 LOW / HIGH (S4)

The G7 has **no separate LOW/HIGH flag bit** in either reference. It reports the number itself and
its reportable range is 40…400 mg/dL: a number < 40 is LOW, > 400 is HIGH (G7SensorKit
`G7GlucoseMessage.swift:56-68`, `G7BackfillMessage.swift:82-94`, `GlucoseLimits.swift:11-13`).
xDrip4iOS passes the raw number through (`DexcomG7GlucoseDataRxMessage.swift:92-104`).

G7Kit (`G7GlucoseRange.classify`, PROGRESS.md D31):

| 16-bit field (value = low 12 bits) | Result |
|---|---|
| `FFFF` (sentinel), `FFFE`, value 0, value `0FFF` | **no value**: withheld, logged, surfaced as `.failed(noGlucoseValue)` when the sensor said OK (backfill: logged) — never LOW/HIGH |
| value 1…39 | `.belowRange` (LOW) |
| value 40…400 | `.mgdl(n)`, unchanged |
| value 401…4094 | `.aboveRange` (HIGH) |

Never 40/400. The "no value" set exists because a misread packet (0, all ones) would otherwise become
LOW/HIGH, and HIGH reaches Trio as 401. **No captured G7 LOW or HIGH packet exists in any
reference**; which numbers a real LOW/HIGH carries is unverified. Capturing one is a HANDOFF §11 item
before relying on HIGH → 401 in closed loop (D31; §13).

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

### 5.6 Backfill floor from the store (audit m1)

**The G7 has no backfill request.** In primary mode neither xDrip4iOS 7.1.0 nor G7SensorKit sends
one: enabling Backfill notifications after the `0x4E` makes the sensor send the records it chooses,
then `59` (§2.3; `CGMG7Transmitter.swift:1165-1174`, `:1010-1012`; G7SensorKit
`G7Sensor.swift:131-136`, `:285-311`). So G7Kit cannot ask for "everything since X". What it controls
is which received records it publishes.

Problem: G7Kit marks a reading as published when it yields it (and persists the newest mark). If the
app's store is failing (D42) and iOS terminates the app, readings delivered to alerts and Trio were
never stored; a later backfill copy of the newest one was skipped as "already published".

API: `G7CGMSource.setLatestStoredReading(_ reading: GlucoseReading?, forSerial serial: String)` —
the newest reading the app has durably stored for that sensor (nil: none). Rules:
- A backfill record whose sensor time is **above** the floor is published again even if G7Kit
  published it before, with the same id and date as the first delivery and `isBackfill = true`
  (byte-identical otherwise). It must carry the date it was first published with; after a re-anchor
  it would not, and it is withheld (one id, one date, S3). The store and Trio dedupe by id; alerts
  never evaluate backfill.
- Never in the connection that first published it (the app cannot have stored it yet).
- At or below the floor: unchanged behaviour (published only if G7Kit does not know it as published,
  e.g. gap filling after a relaunch).
- Everything else is unchanged: authentication, the gate (`LiveReadingGate`: session start,
  warm-up, grace end, future), the session clock, the latch (after a latched end nothing is
  published), unsupported sensors. The floor applies only to the pipeline of the serial it names, so
  no reading of another sensor or session is re-published; a reading whose id is not that sensor's
  `GlucoseReading.sensorID` is ignored (logged).
- Without any call (no store), nothing already published is re-published (the previous behaviour).
- A floor that is too low only causes duplicates (deduped by id); one that is too high is the
  previous behaviour.
The app calls it once the store is readable at launch, and after each successful store write of this
source's readings. Which records the G7 resends after a gap is the sensor's choice and is **to be
verified on device** (§13): if it never resends a reading that was delivered live, the floor
recovers only what it does resend, and full recovery needs the held readings persisted by the app.
Tests `test_S3_backfillAboveTheStoredFloorIsPublishedAgain`,
`test_S3_republishedCopyKeepsTheFirstDateOrIsWithheld`,
`test_S3_crashWithUnstoredReadingsRepublishesFromTheStoredFloor`,
`test_S3_backfillFloorAppliesOnlyToItsOwnSensor`.

## 6. Session timing

### 6.1 `SensorSession` (all from the sensor clock)

`start` = receipt − sensor clock (fixed per serial, §5.1); `warmUpEndsAt` = start + warm-up;
`expiresAt` = start + (session length − 12 h); `gracePeriodEndsAt` = start + session length.

| Value | Reported? | Value used | Source |
|---|---|---|---|
| session length | yes, `0x52` | 907 200 s (10 d + 12 h) | `DexcomG7ExtendedVersionMessage.swift:14-15`; ConstantsDexcomG7.swift:15-16 |
| warm-up | yes, `0x52` | as reported (1 620 s = 27 min for a 10-day sensor) | captured `0x52`; G7SensorKit `G7Sensor.swift:68` |
| grace | **constant** (included in the length) | 12 h | G7SensorKit `G7Sensor.swift:69`, `G7CGMManager.swift:115-117` |

`0x52` is requested **before** GetData until it has been answered once (§2.3), then stored with the
pairing record; no reading is ever handled without it (no assumed defaults). Dexcom's user-facing
"30 minutes" is not what the sensor reports; 30 min would refuse the first valid readings (≈28 min).

### 6.1a `currentSession` lifetime (PROGRESS.md D28)

Persisted in the pairing record (serial, session start, reported timing) and restored at launch, so
it stays non-nil across the ~5-minute disconnects and app relaunches. It is `nil`:
- before the first status-0 `0x4E` of a pairing (and before `0x52` answered);
- after `gracePeriodEndsAt` (a time check when read — no connection needed);
- once the sensor itself has reported the session over — expired states, failed states, or
  "stopped" after warm-up (`G7SensorStatus.sessionEnd`) — **in two status-0 `0x4E`, the second one's
  sensor clock at least 60 s and at most 1 h after the first one's** (safety review N1; Sensor
  policy: the sensor wakes about every 300 s, so 60 s means a later wake, never a repeat within one
  connection or a re-delivered packet). The sensor clock, not a connection count, tells the reports
  apart, and the first report is persisted in the pairing record (`G7UnconfirmedSessionEnd`), so iOS
  terminating the app between wakes cannot prevent the latch. A non-zero-status reply never counts
  (it may carry a cached state, §4.1); a second report with an earlier or too-close sensor clock
  neither confirms nor replaces the first; any status-0 report of a running session in between (OK,
  warm-up, calibration, temporary issue) clears it. A first report more than 1 h of sensor time
  older than a new report is discarded and the new report becomes the first (Sensor policy, last
  safety-review minor): if the save that cleared it failed and the app was relaunched, the restored
  stale report cannot let a single later report latch; a real end is reported at every wake, so this
  costs at most one wake after a long outage. A single report is shown for that connection as
  `.error(code: raw state byte, description:)` — also for an expired state, never `.expired` (D41:
  `.expired` is a confirmed end, on which the alert engine suppresses missed readings) — and a later
  OK reading is used as usual, so one bad byte cannot end a session or silence the missed-readings
  alert. `.expired` is emitted only for the latched end and for the grace end passing by time in an
  **anchored status-0 packet** (its sensor clock agrees with a session start established before it,
  so the time is sensor-clock time). A time-based expiry that is not anchored is an unconfirmed
  `.error(code: 0x06, "OK, past the session end (not confirmed)")`: the first anchor of a pairing
  (its own clock supplied the start) and **every non-zero-status reply**, which is judged by the
  phone clock — a phone clock moved forward must not show "Sensor expired" (review n1). Tests
  `test_S5_unconfirmedExpiryIsNotExpired`, `test_S5_unconfirmedExpiryIsNotExpiredAtTheController`,
  `test_S5_phoneClockJumpWithStatusReplyIsNotExpired`.
  Once latched, the end (`G7SessionEnd`) is persisted in the pairing record; every later `0x4E`, OK
  or not, shows it — `.expired`, `.failed(sensorFailed)` or `.failed(sessionStopped)`, never
  `.active` — and publishes nothing; the same state is shown at launch, after Bluetooth returns, and
  refuses calibration. An "OK" packet whose time lies past the grace end does *not* end the session
  permanently (a garbled clock could);
- for an unsupported sensor; when a new pairing is required; after "Forget sensor".
A new pairing replaces it with the new sensor's session.

### 6.2 Unsupported sensors

A `0x52` session length ≠ 907 200 s (e.g. 15-day `5200406f1400880e…` = 1 339 200 s) →
`.failed(unsupportedSensor)`, no readings from that pairing, no calibration.

## 7. Algorithm states → `SensorState` (S5)

| Byte | Name | Category | `SensorState` |
|---|---|---|---|
| `06` | OK | ok | `.active` / `.gracePeriod` / `.expired` by the derived session (`.expired` only from an anchored status-0 packet, else `.error(6, …)`, §6.1a) |
| `02` | warm-up | warmUp | `.warmingUp(endsAt:)` |
| `01` | session stopped | stopped | `.warmingUp` before warm-up end (first message after activation reports it, G7SensorKit `:40-66`), else `.error(1, …)`; after two connections (§6.1a) `.failed(sessionStopped)` |
| `04 05 07 0E` | BG(s) needed / calibration needed / outlier request | calibrationNeeded | `.calibrationNeeded(code: byte)` (D36) |
| `08 09 0A 0D` | calibration errors / out of calibration | calibrationError | `.calibrationError(code: byte)` (D36) |
| `03 12` | excess noise / temporary issue | temporaryIssue | `.error(code: byte, …)` |
| `0B 0C 10 11 13-16 19 1B 25` | failed | sensorFailed | `.error(code: byte, …)`; after two connections (§6.1a) `.failed(sensorFailed)` |
| `0F 18 1A 24` | expired / session ended | expired | `.error(code: byte, …)` while unconfirmed (one report, or a non-zero-status reply); `.expired` once latched (two reports, §6.1a; D41) |
| other | unknown | unknown | `.error(code: byte, "Unknown sensor state 0x..")` |

Names: `Generic/DexcomAlgorithmState.swift:19-81`. `0x18`: xDrip4iOS calls it `questionMarks`,
G7SensorKit `expired` (`AlgorithmState.swift:38`) and its capture 7 h after expiry carries it; G7Kit
follows the capture. Only `06` ever publishes a reading, so these naming differences cannot leak
values. The categories come from `G7AlgorithmState.category`.

### 7.1 Failures → `SensorFailure.kind` (contract D36)

Every `.failed(_:)` carries a `SensorFailure`: consumers decide from `kind`, never from the text;
`message` is G7Kit's wording for the person wearing the sensor (`G7FailureReason`).

| `G7FailureReason` | `kind` | Raises the sensor alert | Where |
|---|---|---|---|
| `sensorFailed`, `sessionStopped` | same | yes (replace sensor) | latched end, §6.1a |
| `unsupportedSensor` | same | yes (replace sensor) | §6.2 |
| `pairingCodeRejected`, `savedKeyRejected`, `previousSensorRejectedCode(sensorName:)` | `pairingRejected` | yes (pair again) | §3.1, §2.2 |
| `pairingCodeNeeded` | same | yes (pair again) | §3.2 |
| `bondRemovedBySensor` | `bondRemoved` | yes (pair again) | §2.4 |
| `bluetoothPairingNotCompleted` | `bluetoothPairingIncomplete` | no (banner) | §2.4 |
| `authenticationFailed` | same | no | §3 |
| `rejectedAfterAuthentication`, `otherAppRejected` | same | no | §3.1 |
| `sensorClockMismatch` | `clockMismatch` | no | §5.1 |
| `noGlucoseValue` | same | no | §5.3 |
| `sessionLengthUnknown` | same | no | §2.3, §6.1 |
| `credentialsUnavailable` | same | no | §2.2 |

Transient kinds surface as banners; if they stop readings for long, the missed-readings alert covers
them (D36). Pinned by `test_S5_failureKindsMatchTheContract`.

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
the sensor is running (`.active`, `.gracePeriod`, `.calibrationNeeded`, `.calibrationError`, or
`.error` in the temporary-issue category); value in **40…400 mg/dL**
(`CGMG7Transmitter.swift:1967-1974`); fingerstick time not in the future and at most 5 min old,
else `.invalidTime` (D36; xDrip4iOS `calibrationIsValid`, `CGMG7Transmitter.swift:1970-1972`,
`ConstantsDexcomG5.swift:23-24`); also `.invalidTime` while the last failure the reading pipeline
surfaced is a clock mismatch (D37, §5.1): the fingerstick time can only be placed in sensor time
through the phone ↔ sensor clock relation, which is exactly what is in doubt; it clears when a later
wake reports the sensor state with agreeing clocks. One calibration at a time (queued, sent or
awaiting the record). Then:

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
record from another display ends it as `.unknown`. A queued fingerstick that is older than 5 min by
the next wake (it was valid at submission) ends as `.unknown("Not sent: …")`.

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
That much is code. **Which device uses which slot is a hypothesis**, inferred only from xDrip4iOS's
enum names and UI text above; no packet capture, Dexcom document, or hardware test in this workstream
confirms it. Note that the same slot 1 is described as "Receiver **or Pump**": Dexcom-integrated
insulin pumps (which read the G7 directly) would use slot 1 as well, so a receiver and such a pump
presumably cannot both be paired (not relevant here: Trio's pump does not read the G7).

**Can this app and a Dexcom G7 receiver both be authenticated at once? Probably yes, in different
slots (hypothesis).** If the receiver uses slot 1 as xDrip4iOS's naming says, this app in slot 2 is
a distinct identity, as Dexcom's own phone-app-plus-receiver setup suggests.

**Which slot to use to coexist with a receiver:** slot 2 (`.mobileApp`), the default — xDrip4iOS
calls it "the currently validated native G7 connection" (`TextsBluetoothPeripheralView.swift:368-370`).
Per the same naming, the Dexcom app also uses slot 2, which is why it must be removed (HANDOFF §4.6).

**What happens to a collector already using that slot:** per xDrip4iOS, completing J-PAKE ownership
replaces that slot's credential and the previous owner's saved key is refused at its next short
authentication (`authenticated = 0`). It confirms a key only after ownership so a later connection
"can restore it instead of repeating ownership and replacing another app's authentication
credential" (`DexcomG7AuthSession.swift:297-302`), and it stops instead of re-pairing when its own
key is refused because "another app may now own this slot" (`:409-420`, `:460-462`). G7Kit does the
same (`requiresNewPairing`, `.failed(savedKeyRejected)`), so it never fights another collector on its
own; only the user's "Pair again" (`pairAgain(code:)`, §2.2) claims the slot back.
Consequence (same caveat): pairing this app into slot 1 would evict a paired receiver (xDrip4iOS's G6
warning says so for G6, `TextsBluetoothPeripheralView.swift:320-321`); a Dexcom app left installed
would evict this app from slot 2 and vice versa.

**Recommended default and setting:** `G7Configuration.authenticationSlot = .mobileApp`
(`G7AuthenticationSlot.recommendedDefault`). It is an explicit, documented setting; changing it
requires a new pairing.

**Confidence:** a hypothesis from xDrip4iOS 7.1.0 naming, UI text and key handling, not verified on
hardware. §11 validation: pair the receiver first, then this app (slot 2), and confirm both keep
receiving readings for a day; if the receiver stops, the hypothesis is wrong and the side-by-side
reference falls back to the fingerstick meter.

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
| Coexistence-mode *commands* (`0x52`, `0x4A`, `0x22`, calibration `0x34`/`0x32`, arming Backfill) | Listen mode (§14) never writes to the sensor; the observation itself is ported (D45) |
| G5/G6/ONE/ONE+/Stelo/Libre/other transmitter types | Non-goals (HANDOFF §1.1); only the G7 10-day protocol is ported |
| Battery `0x22` and firmware `0x4A` requests | Diagnostics only; not needed for readings or safety; fewer bytes in the short wake window |
| Routine `0x32` requests without a pending calibration | Only needed for xDrip4iOS's calibration-permitted indicator |
| "Six identical values" filter (`CGMG7Transmitter.swift:1135-1141`) | A stalled sensor re-sends its *same* reading (the captured expired stream keeps timestamp 907 385), which S3 dedupe already collapses; the filter would also drop real flat readings. LoopKit/Trio's own G7 driver has no such filter. Reviewer's call (report) |
| Core Data, UserDefaults key storage, alert/UI/Activity Log/trace code | Replaced by `G7CredentialStore`, `DiagnosticLog`, and the app's own UI/alerts |
| ObjC bridge (`DexcomG7AuthBridge.m`) and its `objc_msgSend` call into Swift | Ported to Swift (`G7JPAKEClient`, `G7ChallengeHash`, `G7OwnershipCredentials`); the C ECC layer stays C |
| 6-digit pairing-code branch (`DexcomG7AuthBridge.m:926-929`) | G7 codes are 4 digits; codes must be ASCII digits (xDrip's `isNumber` also accepts non-ASCII digits) |

Behaviour changed relative to xDrip4iOS 7.1.0 (each explained where it is documented above):
solicited-only authentication packets, and a later `05` rejection ends the connection at once
(§3.1); `paired` = byte 2 == `01` (§3.1); reading time = sensor clock − age (§5.1); session start
fixed per serial with the 30 s two-anchor rule, and dates kept in sensor-time order for live and
backfill, across relaunches (§5.1); "no value" raws and LOW/HIGH flags (§5.3); display-only values
withheld (§5.4); serial with the iOS identifier (§5.5); `0x52` before GetData and no default timing
(§2.3, §6.1); persisted `currentSession`, ended only by a sensor-reported end on two connections
(§6.1a); backfill state byte checked (§4.2); calibration clock pairing (§8.2).

**Code from LoopKit CGMBLEKit (MIT; audit m7).** Seven ported files carry code that xDrip4iOS took
over from CGMBLEKit (formerly xDripG5, Nathan Racklyeft / LoopKit Authors). Its MIT notice ships as
`Packages/G7Kit/licenses/CGMBLEKit-LICENSE` (verbatim from loopandlearn/CGMBLEKit @ 98fae79, the Trio
submodule in `vendor-ref`), and each file has a "CGMBLEKit lineage" header line (checked by
`test_S8_cgmbleKitDerivedFilesShipItsLicense`):

| G7Kit file | CGMBLEKit file | What came from it |
|---|---|---|
| `Messages/G7Opcode.swift` | `Opcode.swift` | the opcode enum pattern and the values 0x03-0x07 (auth request rx, challenge tx/rx, keep-alive, bond request) |
| `Messages/G7AuthStatusMessage.swift` | `Messages/AuthChallengeRxMessage.swift` | parsing `05 authenticated paired` |
| `Messages/G7AuthChallengeMessages.swift` | `Messages/AuthRequestRxMessage.swift` | parsing `03 tokenHash(8) challenge(8)` |
| `Auth/G7ChallengeHash.swift` | `AESCrypt.m` | the AES-128-ECB call through CommonCrypto |
| `Messages/G7CRC16.swift` | `NSData+CRC.swift` | CRC-16 CCITT (XModem) |
| `Messages/G7OwnershipMessages.swift` | `Messages/KeepAliveTxMessage.swift`, `Messages/BondRequestTxMessage.swift` | the `06 <seconds>` keep-alive and `07` bond-request packets |
| `Auth/G7AuthenticationSlot.swift` | `Messages/AuthRequestTxMessage.swift` | the slot byte enum of the `02` auth request |

The CGMBLEKit release xDrip4iOS took these from is not recorded upstream; the xDrip4iOS release is
(7.1.0, 0370937), and the copies were compared with CGMBLEKit @ 98fae79.

Layering for future sensor families (HANDOFF §1.1): `Messages/` (pure parsers), `Auth/`,
`Connection/` (link + cycle), `Session/` (clock, pipeline, status), `Calibration/`, `Credentials/`,
`Source/` (controller, CoreBluetooth adapter, public `G7CGMSource`). Another family would add its own
package or folder behind `CGMSource`; nothing G7-specific leaks into GlucoseCore.

## 13. To verify on device (cannot be proven by host tests)

1. First pairing: iOS pairing prompt appears; Accept continues; Cancel shows the pairing banner and
   the prompt returns at the next wake (§2.4 error codes).
2. Timestamps: app reading times match the receiver within seconds; a backfilled reading after a
   30-min walk-away lands exactly on the previously missing times (§5.1).
3. **Capture a real LOW and a real HIGH packet** (export diagnostics) and confirm they show as
   LOW/HIGH, not a number, before relying on HIGH → 401 in closed loop (§5.3, D31).
4. Receiver (slot 1) and app (slot 2) both keep receiving for 24 h — tests the slot hypothesis (§9).
5. Calibration: accepted within one or two wakes; the following display-only value is not shown as a
   reading (§5.4, §8).
6. Trio heartbeat: Trio's loop runs within a minute of each sensor wake while locked (§11).
7. Anchor drift: over a full session, read the "anchor differs by N s" diagnostics lines; if the
   sensor clock drifts past 30 s, expect one withheld reading and a clock-mismatch banner per
   re-anchor (§5.1). Tell the orchestrator if this happens more than rarely.
8. Signal loss: walk away for 20 min; `state` stays as last reported and the missed-readings alert
   fires from reading age (§2.2).
9. Session end: at a real expiry (or failure), the ended state appears within two sensor wakes
   (~10 min), also if the app was terminated between them, and stays after an app relaunch (§6.1a).
10. With another G7 app installed (Dexcom G7 or xDrip4iOS in primary mode), `.failed(otherAppRejected)`
    surfaces (after `.failed(rejectedAfterAuthentication)` the first time), never "Pair again" while
    this phone's key is accepted (§3.1, D35).
11. Backfill floor (§5.6): with the store made to fail (or the app terminated right after a wake),
    check in the diagnostics which records the G7 sends on Backfill at the next wakes — whether a
    reading already delivered live is ever sent again — and whether "published again (m1)" lines
    appear after a relaunch.
12. Listen mode (§14), with raw recording on: which format the Dexcom app's traffic uses (`0x4E` or
    `0x31`+`0x25`, "raw listen packet" lines; other opcodes are logged by number); whether the
    `0x31`/`0x25` time base agrees with `0x4E`'s (no clock-mismatch banner when both appear); how
    often a wake is lost because the `05` was missed (`listenNoAuthenticatedConnection`, "no
    authenticated Dexcom app connection observed" lines) — if often, report it (D50); reading times
    match the Dexcom app's within seconds; and the Dexcom app keeps working normally (no new
    errors, its own readings and backfill unchanged) over a day.
13. Listen-mode session length (D49): whether answers to **Trio's** `52` requests are observed
    ("session length … s" without a preceding "one 52 query sent (D49)" line); if not, whether this
    app's one `52` query (sent at the second wake with proof) is answered and the session
    established; and whether that one query disturbs anything in the Dexcom app — judged from its
    behaviour (alerts, readings, sensor status, errors) and, if available, its log, around the wake
    in which "one 52 query sent" appears.
14. Listen mode with `0x31`/`0x25` only (reviews m1, m8): at the first follow, the sensor expiry this
    app shows must equal the Dexcom app's (to the minute); if not, the `0x25` session-start origin
    is not the session start (§14) — report it and do not rely on listen-mode expiry. Note which
    `0x31`/`0x25` status bytes appear ("listen: 0x31 status 0x…" lines); any reading withheld for a
    status such as `0x81` (low battery in G6 terms) should be reported.
15. Listen mode, first follow (review m4): if the app stays on "Searching" and the diagnostic log shows
    "not a G7 seen advertising", iOS reports the connected G7 as "Dexcom" + 2 and this app run has
    not yet received the sensor's "DXCM…" advertisement. Keep the app open for a sensor wake (it
    restarts its scan every 10 s until the first follow, so each advertisement is a new discovery),
    or relaunch it. `AllowDuplicates` was not used: iOS ignores it in the background, and the
    foreground scan restart gives the same effect only until the first follow. Also check that after
    a failed attach the app recovers by itself at the next wake while in the background (review N1:
    "backoff ended" or a pending connection in the log).

## 14. Listen mode (D45)

**What it is.** The Dexcom app on this phone owns the sensor: it pairs, authenticates every wake,
and asks for the readings. iOS keeps one Bluetooth link per peripheral and delivers every
notification to every app subscribed to it, so this app can *observe* the Dexcom app's exchange.
Ported from xDrip4iOS 7.1.0's coexistence path (`CGMG7Transmitter.swift:51-66`, `:553-571`,
`:714-717`, `:744-750`, `:994-1013`, `:1064-1102`, `:1587-1622`, `:2082-2087`), as
`G7ListenCycle` and the "Listen mode" section of `G7Controller`. Chosen by the app with
`G7Configuration(mode: .listen)` or `G7CGMSource.setMode(.listen)`, then `start(pairingCode: nil)`.
No pairing code. Used for Michael's current sensor alongside the Dexcom app (D45, D46); the next
sensor is paired in primary mode after the Dexcom app is deleted.

**Writes (hard rule, D45 + D49).** The only write listen mode ever makes is the read-only `52`
session-length query, under the D49 conditions below, at most once per connection. Nothing else:
no `02`/`04`/`0A`… authentication, no ownership packets, no `0x31`/`0x25` requests (they are the
Dexcom app's responses, only observed), no GetData, no backfill, no calibration, no other control
command. The listen cycle's link is a `G7ObservingLink`, a protocol with no write method; its one
write capability is `G7SessionLengthQuery`, which can only send the fixed `52`. Calibration is
refused (`.notAuthenticated`); `pair`/`pairAgain` throw `notAvailableInListenMode`. Every listen
test fails on any write other than one `52` on Write_Control with response per connection, on a
Write_Control subscription before an observed `05`, and on a cancel of the followed sensor's
connection the test did not ask for (`G7ListenModeTests.tearDown`); the D49 conditions have their
own tests. Checked by mutation (an extra write, the query one wake early, an early Write_Control
subscription, a cancel at disconnect: each fails the suite). xDrip4iOS's coexistence writes:

| xDrip4iOS writes in coexistence | Here |
|---|---|
| queued calibration `34` and its `32` record (`:778-780`, `:1640-1734`) | **not ported**: changes the Dexcom app's session (it shows/uses calibrations) |
| `52` lifetime request after a reading (`requestExtendedVersionIfNeeded` `:1364-1389`, called after glucose `:1104-1108`; G7SensorKit does the same, `G7Sensor.swift:143-151`, `:160-170`) | **ported under D49** (below): only if no answer was observed by the second wake with proof, once per connection |
| `4A` firmware and `22` battery requests (`:1181-1215`) | **not ported**: no use; each would be a write |
| arming Backfill notifications after a reading (`:1165-1174`; G7SensorKit `G7Sensor.swift:131-136`) | **not ported**: the sensor then sends its backfill now, which may change what the Dexcom app receives |

**Subscribed (CCCD only; both are subscriptions the Dexcom app itself holds on the shared link).**
Receive_Authentication at once, to observe the `05` its exchange produces (`:1611-1622`).
Write_Control **only after an authenticated and bonded `05` was observed**, for every sensor (D50;
xDrip4iOS `:57-59`, `:1598-1601`; G7SensorKit `G7Sensor.swift:317-322`): an encryption-required
characteristic is never subscribed before the Dexcom app has secured and authenticated the link.
Not Auth_Stream (ownership payloads, `:1615-1616`), not Backfill (above), not Communication.

**Connecting.** Until a sensor is followed, this app attaches only to a G7 that is already
connected to the phone — by the Dexcom app — found with `retrieveConnectedPeripherals` for the G7
service (`:2082-2087`, BluetoothTransmitter.swift:561-586), checked at start, at each FEBC
advertisement (scanning is only a wake-up signal, `:562-571`) and every 10 s in the foreground. An
advertising sensor is never connected to directly (it could take another phone's sensor
connection). Only a G7 is attached (review m4): a connected peripheral named "DXCM" + 2 characters,
or named "Dexcom" + 2 characters — the form a connected G7 can report (G7SensorKit
`G7Sensor.swift:246-247`), but also a G6's name — only if this app saw that same peripheral
advertise as "DXCM" + 2 (G6 transmitters advertise as "Dexcom…"); the serial uses the advertised
name. ONE+ ("DX02…"), Stelo ("DX01…"), unnamed peripherals and G6-style names without a G7
advertisement are never attached. Once followed, a pending connection request to that sensor keeps
this app awake at every wake, as primary mode does (`BluetoothTransmitter.swift:313-317`; the
xDrip4iOS 7.1.1 coexistence fix 00c144e8 relies on the same request); iOS shares the one physical
link with the Dexcom app. Only the followed sensor is retried after a failed connect (review m3).
When a connect or attach to it fails before a cycle could start (e.g. service discovery failed):
- if the Dexcom app still holds the link (the sensor is system-connected), the retry waits 30 s,
  doubling to 5 min, never at once on that link (review m6); meanwhile the scan is restarted, so the
  sensor's next advertisement — it advertises again once that link drops — is a new discovery, which
  also wakes a suspended app; that discovery ends the backoff and arms the pending connection
  (review N1);
- otherwise the pending connection is armed at once (it completes only at the next advertisement,
  so it cannot loop) — a suspended app runs no timers, and a pending connection is what lets iOS
  wake it (review N1);
- Bluetooth off → on ends any backoff and re-arms; a normal connection resets it. CoreBluetooth events carry their peripheral, and one for a peripheral that is
not the current connection is dropped (review m7). This app cancels its use of the link only when
told to stop (`stop`, `setMode`, forget); iOS keeps the physical link for the Dexcom app.

**What makes a reading publishable (S2).**
1. **Proof of an authenticated link in *this* connection (D50, amending D49):** only an observed
   `05` with authenticated = 1 and bonded (`paired`) = 1 (`G7AuthStatusMessage`, `:1587-1609`;
   G7SensorKit `G7Sensor.swift:317`). It proves that *a* client authenticated this link, not which
   one (§3.1). No frame on Write_Control is proof — Write_Control is not even subscribed before the
   `05`. **A missed `05` loses that wake** (e.g. this app's subscription came after the Dexcom app's
   exchange): nothing is used, and two such wakes in a row show
   `.failed(listenNoAuthenticatedConnection)`; a longer gap shows through the missed-readings alert.
   A later `05` "not authenticated" stops forwarding for the rest of the connection (as primary N2),
   `.failed(listenConnectionRejected)`; the link is not dropped. A reading published between the
   observed `05` and such a rejection in the same connection stays published (review m9; as primary
   mode, §3.1 and D35); with the `05` as the only proof, nothing reaches the pipeline before it.
   Tests `test_S2_statusArrivingAfterOurSubscriptionIsHandled`,
   `test_S2_writeControlIsNeverSubscribedBeforeAnObservedStatus`, `test_S2_missedStatusLosesTheWake`,
   `test_S2_glucoseWithoutAnObservedStatusIsNeverProof`.
2. The first such connection fixes the followed sensor: the advertised "DXCM" + 2 name (see
   Connecting), iOS identifier, serial `G7SensorSerial.make` — the same serial primary mode would
   give. Other sensors' connections are not attached; a delivered one is ignored
   (`test_S2_otherSensorsPacketsAreRefused`, `test_S2_listenAttachesOnlyToG7Names`).
3. The session must come from what the sensor sends: the start from the observed clocks (below), the
   length and warm-up from a `52` answer (D49):
   - first, an **observed** answer to another app's `52` — Trio's G7SensorKit on the same phone asks
     (`G7Sensor.swift:143-151`, `:160-170`), and iOS delivers its answer to every subscriber;
   - if none was observed by the **second wake with proof**, this app sends **one** `52` itself in
     that connection, after proof and after a glucose report (as xDrip4iOS `:1104-1108`,
     `:1364-1389`), at most once per connection, and only while the length is unknown, the sensor is
     followed, supported and not ended. The answer is parsed exactly as in primary (§4.3); a
     malformed one establishes nothing (the next connection may ask once more); a 15-day answer
     refuses the sensor and ends the queries.
   - "Session length from the user" was rejected (not sensor data, S2).
   Until a length is known, nothing is published and `.failed(listenSessionLengthUnknown)` is shown.
   Tests `test_S2_listenSessionNeedsTheObservedSessionLength`,
   `test_S2_sessionLengthQueriedOnceFromTheSecondProvenWake`,
   `test_S2_observedSessionLengthOrNoProofMeansNoWrite`,
   `test_S2_malformedSessionLengthResponseEstablishesNoSession`.
4. Then exactly the primary pipeline: response status 0, algorithm state OK, a value (D31),
   not display-only (S1), anchor within 30 s (§5.1), date order, the end latch (§6.1a, D41), and
   `LiveReadingGate`.

**Glucose formats observed.** The Dexcom app's request decides the format:
- `0x4E` (its GetData; what G7SensorKit observes, `G7Sensor.swift:268-276`): parsed exactly as in
  primary mode (§4.1).
- `0x31` glucose + `0x25` transmitter time (G6 layout; what xDrip4iOS 7.1.0 coexistence observes,
  `:1064-1102`; captured pair in xDrip Tests/`DexcomG7CalibrationTests.swift:344-357`). Both carry a
  CRC-16 (verified on the capture) and are dropped if it fails (CGMBLEKit `GlucoseRxMessage.swift:53`,
  `TransmitterTimeRxMessage.swift:25`). A non-zero status byte in either half withholds the reading
  (fails safe) and is logged; CGMBLEKit reads it as a transmitter status and still uses the glucose
  for `0x81` "low battery" (`TransmitterStatus.swift:23-24`) — which status bytes a G7 sends is a
  device check (§13 item 14, review m8).
  Glucose high nibble set → display-only (CGMBLEKit `:33`), withheld (S1). Trend: signed tenths,
  `0x7F`/`0x80` none. The G7 transmitter clock is not session time (163 days vs. a 2.7-day session in
  the capture), so both are put in session time with the `0x25`'s session start:
  `sensorClock = now − start`, `readingSensorTimestamp = reading − start` (xDrip4iOS `:1090-1091`),
  dated against the `0x25`'s receipt. Reading **dates** depend only on the sensor's clock relative to
  the receipt and are right either way. **Hypothesis to verify on device:** the `0x25` session start
  is the session's real start, i.e. session time equals `0x4E`'s `clock − age` for the same reading.
  When both formats appear, a disagreement shows as `.failed(sensorClockMismatch)` through the 30 s
  anchor check (`test_S3_timeBaseDisagreementShowsAsClockMismatch`). **With `0x31`/`0x25` only, it
  cannot be detected (review m1):** if the origin were off, the session start — and with it
  warm-up end, expiry, grace end and reading ids — would be off by the same amount without any
  mismatch. Device check §13 item 14: at the first follow, the app's sensor expiry must equal the
  Dexcom app's.
- `0x52` (an answer to another app's request, or to this app's one D49 query): adopted as in primary
  (§4.3).
- Anything else on Write_Control: logged by opcode and length only.

**What listen mode cannot do.** No backfill (gaps stay gaps; the Dexcom app has the history), no
calibration (`supportsCalibration == false`), no sensor control, no Trio heartbeat target
(`heartbeatTarget == nil`; D45 turns the Trio handoff and Nightscout/Share uploads off while
listening, app side). If the Dexcom app stops connecting (deleted, signed out, force-quit), no
readings arrive: the state stays as last reported (or `.failed(listenNoAuthenticatedConnection)`
after two observed wakes without its authentication) and the **missed-readings alert fires from
reading age** (S5), as in primary mode. After the followed sensor's session ends, forget the sensor
(or switch to primary) to follow another one; listen mode never moves to a new sensor by itself.

**Mode switching.** `setMode` stops, deletes the stored record of the old mode (code, key, followed
sensor, session start/end, newest mark) and reports `.notPaired` (primary) or `.searching`
(listen). A record of the other mode found at launch is deleted the same way
(`test_S5_switchingModesDropsStoredStateCleanly`). The app persists the user's choice and passes it
as `G7Configuration.mode`.

**Raw glucose packet recording (D47).** `G7Configuration.recordsRawGlucosePackets` or
`G7CGMSource.setRecordsRawGlucosePackets(_:)`, off by default (Settings › Diagnostics): the hex of
every received glucose packet — `0x4E` in both modes, `0x31` and `0x25` in listen mode — valid ones
included, goes to the diagnostic log with its time ("G7: raw primary|listen packet <hex>"). These
packets carry no code or key. Purpose: capture a real LOW/HIGH (D31, §13 item 3).

Tests: `G7ListenModeTests` (S1-S5 named), `test_modeAndRecordingThroughTheSource`.
