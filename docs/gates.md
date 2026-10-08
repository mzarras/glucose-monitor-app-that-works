# Running the gates

`scripts/check.sh` runs the HANDOFF §10 gates 1–4 (build, tests, safety, replay); what each gate
checks is in [`setup.md`](setup.md) §3.1. This page is about *running* them: the two modes, targeted
runs, the machine-wide build slots and the pooled simulators (D60), and how a reviewer confirms that
a log is a full certify run.

## Modes

| | `certify` (default) | `CHECK_MODE=fast` |
|---|---|---|
| For | merges (D18): the author's final run, the test-verifier's run per stage | iterating; a reviewer's targeted checks |
| Generic-iOS build | fresh derived data per run (`.build-logs/<dir>/dd`, deleted at exit) | persistent `.derived/fast-build` |
| `swift test` | fresh scratch path per package per run | persistent `.derived/fast-spm/<pkg>` (incremental) |
| Warnings | every file is compiled, so every warning is seen | only recompiled files report warnings |
| Release build, S2/S6 Release-configuration tests, S6 `nm` compile-out checks | always | only with `FAST_RELEASE=1` (otherwise a `SKIP` line) |
| Pool simulator before tests | erased (a fresh device) | kept; every installed app uninstalled, Keychain reset |
| Log directory | `.build-logs/<timestamp>/` | `.build-logs/<timestamp>-fast/` |
| Valid for merge | yes, if `--verify-certify` accepts it | **no** |

Fast mode runs the same checks with the same pass/fail rules except the Release-configuration
steps in the table, which it skips (with a `SKIP` line) unless `FAST_RELEASE=1`, and it re-reports
warnings only for the files it recompiles. Both modes exit non-zero on any failure. Fast mode
prints this as its first and last line:

```
FAST MODE: incremental; warnings in unchanged files are not re-reported; NOT valid for merge
```

Every log directory holds `MODE` (`certify` or `fast`), `RUN` (settings, commit and whether the
worktree was clean at the start and at the end, build-tree paths, simulator, slot, load average,
timings, `complete=yes|no`), `git-status.txt`, `git-status-end.txt`, `summary.txt` and
`EXIT_STATUS`. A run stopped by a signal (Ctrl-C, `kill`, a closed terminal, or `| head` closing
its output) records `EXIT_STATUS` as `interrupted (exit <n>)` and `complete=no`.

## Who runs what (D60)

- **Authors** iterate with `CHECK_MODE=fast` (narrowed as below). The final run before reporting is
  a certify run of the reported commit on a clean worktree; the report names its log directory.
- A certify run takes about 20 minutes, longer than an agent's Bash tool allows in the foreground
  (600 s): agents start it with `run_in_background` and wait for its completion notice. Long fast
  runs (the replay gate alone is about 4 minutes) go in the background too.
- **Reviewers** don't re-run the full clean suite. They check the author's certify log, then run
  targeted fast runs on whatever they doubt:

  ```sh
  scripts/check.sh --verify-certify /path/to/author-worktree/.build-logs/<dir> <commit>
  ```

- **The test-verifier** runs one certify run per stage, before any merge, and reports
  `--verify-certify` on it.

`--verify-certify` accepts a log directory only if: `MODE` and `RUN` say certify; the gates were
build, tests, safety and replay; the packages were all of `ALL_PACKAGES` and the rules S1–S8; no
`ONLY_TESTING` or `PKG_FILTER`; the build trees were the run's own fresh ones; the worktree had no
uncommitted changes at the start or the end, and HEAD did not move; the log was made by this
`scripts/check.sh` (same blob); the run reached its summary and exited 0; `summary.txt` has no
`FAIL` or `SKIP` line and has every required `PASS` line; and, if a commit is given, the run was of
that commit. Otherwise it lists every reason and exits 1. It warns, but accepts, when no commit is
given and when the run used the caller's `SIM_DEST` instead of an erased pool simulator.

The required `PASS` lines (`scripts/check.sh --certify-requirements`) are derived, not listed: one
per build configuration, package (its tests, and its coverage where it has a minimum), safety rule,
Release-safety package, `compiled_out_check` and replay suite, plus every `pass` call in the gate
code whose label starts with fixed text (the lint checks, and any check added later).

## Targeted runs

```sh
CHECK_MODE=fast scripts/check.sh                                         # all gates, incremental
CHECK_MODE=fast GATES=build,tests APP_TESTS=1 PACKAGES=AlertEngine scripts/check.sh
CHECK_MODE=fast ONLY_TESTING=SensorTests/AppShellTests scripts/check.sh   # those app tests only
CHECK_MODE=fast ONLY_TESTING=SensorTests/AppShellTests/test_widgetDeepLinkOpensNow,SensorTests/LaunchOrderTests scripts/check.sh
CHECK_MODE=fast GATES=tests PACKAGES=AlertEngine PKG_FILTER=UrgentLowSnoozeEndTests scripts/check.sh
CHECK_MODE=fast FAST_RELEASE=1 GATES=build,safety scripts/check.sh       # include the Release steps
```

- `ONLY_TESTING`: comma-separated `-only-testing:` identifiers for the hosted app tests (replacing
  the default "all of `SensorTests` except `ReplayScenarioTests`"). It makes the app tests run;
  package tests run only if `PACKAGES` is given as well. It does not narrow gate 4 (replay).
- `PKG_FILTER`: passed to `swift test --filter` for every package in `PACKAGES`. Coverage is
  reported but its minimum is not applied. A package with no matching test still fails ("executed no
  tests"), so name the package too. With `PKG_FILTER` the app tests run only with `APP_TESTS=1`.
- Without `GATES`, a run with `ONLY_TESTING` or `PKG_FILTER` runs the tests gate only (safety
  needs every rule's tests, and the replay gate is not narrowed).
- Both need `CHECK_MODE=fast`. A certify run with either set exits 2 before doing anything, so an
  exported variable can't quietly narrow a merge run.
- No `test-without-building`: `xcodebuild test` already rebuilds only what changed in the
  persistent `.derived/sim` (both modes), and a no-op build measured 11 s. Skipping it would need its
  own staleness check, and a wrong one would silently test old code.
- Disk: the fast trees take about 0.5 GB (`fast-build`) plus 0.2 GB per package (`fast-spm`) per
  worktree; `rm -rf .derived/fast-*` when you are done with a worktree.

## Build slots

Each run holds one of `CHECK_SLOTS` (default 2) machine-wide slots for its whole length, so at
most two build-heavy runs share the Mac (D60). Slots are `mkdir` locks under
`~/Library/Caches/sensor-check/slots/<n>/` (per user, the same for every worktree and `TMPDIR`)
holding the holder's pid, process start time (read with `LC_ALL=C TZ=UTC`, so every checker sees
the same text) and worktree. A waiting run prints who holds each slot every 30 s. A slot whose pid
is dead, or whose pid now belongs to a process with a different start time, is stale; a waiting run
takes it over and first shuts down that slot's pool simulator (a holder killed with `kill -9` never
ran its exit trap). A live pid whose start time can't be read is never judged stale.
`CHECK_SLOTS=0` runs without a slot and therefore without a pool simulator: simulator gates then
need `SIM_DEST`, and check.sh exits 2 without it. Two runs in the same worktree at once still share
`.derived/sim` (and the fast-mode trees); don't.

## Simulator pool

Slot *n* runs the simulator gates on `sensor-check-<n>`: an iPhone 17 on the newest installed iOS
26.x runtime, created on first use and reused. check.sh boots it for the run and shuts it down at
exit (also after Ctrl-C, `kill` or a closed terminal), so nothing is left booted to play alarms;
`KEEP_SIM_BOOTED=1` leaves it booted. An explicit `SIM_DEST` still wins; check.sh then neither
resets nor shuts down that device.

- Certify erases the pool simulator before booting it, so every certify run starts from a fresh
  device for everything the tests can observe: the app's container and UserDefaults, the App Group
  containers, the Keychain, notification settings, privacy grants and AlarmKit authorization.
  Measured: uninstalling the app removed its data container and both App Group containers, and
  `simctl keychain reset` clears the Keychain, but nothing showed that an uninstall resets
  notification, privacy or AlarmKit authorization, so certify erases (about 60 s more, below).
- Fast mode keeps the device and its data migration, uninstalls every installed app (the app and
  the UI-test runner, whatever their bundle IDs) and resets the Keychain.

```sh
scripts/sim-pool.sh status      # the slots (who holds each), the pool simulators, any left booted
scripts/sim-pool.sh shutdown    # shut down every pool simulator (not one a live run holds; --force)
scripts/sim-pool.sh delete      # delete the pool (same rule); check.sh recreates it on demand
```

Rules for agents: never create, boot, erase or delete simulators yourself, and don't set `SIM_DEST`;
use the pool through check.sh. Running `swift test` or `xcodebuild` directly bypasses the build
slots and the pool; use `CHECK_MODE=fast` with `ONLY_TESTING` or `PKG_FILTER` instead. Never boot "iPhone 17 Pro" and never open Simulator.app (activating
it boots its default iPhone 17 Pro, which costs memory and can play real alarm sounds). Every app
launch, in UI tests or by hand, passes `-silenceAlertAudio`.

## Measured (2026-10-08, M4 10-core, 16 GB)

Other agents and another project's simulator were running throughout (1-minute load average
90–700), so treat these as rough.

| Run | Wall time | Load (1 min) |
|---|---|---|
| certify, all gates (`scripts/check.sh`) | 1160 s | 90 → 16 |
| fast, first run in a worktree (`GATES=build,tests APP_TESTS=1 PACKAGES=AlertEngine`, cold) | 350 s | 21 → 265 |
| the same, after a one-line change in an app source file (two runs) | 142 s, 139 s | 493, 154 |
| the same, no change (two runs) | 200 s, 136 s | 188 → 703, 157 |
| fast, `ONLY_TESTING=SensorTests/AppShellTests` (10 tests) | 59 s | 219 |

Steps of the certify run: Debug build 52 s, Release build 198 s, the nine `swift test` runs 346 s,
pool simulator erase and boot 60 s, app unit tests 97 s, Release S2/S6 tests 99 s, `nm` compile-out
builds 47 s, replay 253 s. The fast run's scope costs about 436 s of those steps in certify. In the
fast runs the Debug build took 4–17 s, AlertEngine's tests 1–4 s, the simulator 15–41 s and the app
tests 82–146 s, of which a no-op `build-for-testing` is 11 s.

Simulator costs: create 1 s; first boot after create 39 s; boot of an existing device 12–17 s;
shutdown 4 s; erase 1 s, then first boot 60–91 s; uninstalling the app 9 s; Keychain reset 1 s.
