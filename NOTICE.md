# Notices and credits

Sensor is free software under the GNU General Public License v3.0 (see `LICENSE`).

It builds on the work of the diabetes open-source community. Code that is ported keeps its
original copyright header and names the file and release it came from. This list is updated
as code is ported; it names only projects actually used.

| Project | License | Used for |
|---|---|---|
| [xDrip4iOS](https://github.com/JohanDegraeve/xdripswift) (JohanDegraeve/xdripswift), release 7.1.0 | GPL-3.0 | Dexcom G7 primary-mode Bluetooth: pairing, J-PAKE authentication, bonding, message handling, backfill; Dexcom Share upload |
| [LoopKit G7SensorKit](https://github.com/LoopKit/G7SensorKit) | MIT | G7 message formats (reference) |
| [xDrip+](https://github.com/NightscoutFoundation/xDrip) (Android) | GPL-3.0 | G7 protocol research (reference) |
| [DiaBLE](https://github.com/gui-dos/DiaBLE) | GPL-3.0 | G7 protocol research (reference) |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | SQLite persistence |

Fonts (SIL Open Font License 1.1; license texts in `Resources/Fonts/licenses/`):
Newsreader (Production Type), IBM Plex Sans and IBM Plex Mono (IBM).

Trio (AGPL-3.0) is integrated with through its documented App Group contract only; no Trio
code is included in this repository. Any Trio change lives in the owner's Trio fork.

"Dexcom" and "G7" are trademarks of Dexcom, Inc. This project is not affiliated with or
endorsed by Dexcom.
