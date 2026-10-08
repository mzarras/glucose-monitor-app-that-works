#!/usr/bin/env bash
# Runs the HANDOFF §10 validation gates locally and exits non-zero on any failure.
#
#   scripts/check.sh                       all gates: build, tests, safety, replay
#   GATES=build,tests scripts/check.sh     a subset (used for Phase 1 merges into `integration`)
#   PACKAGES="GlucoseStats" GATES=tests scripts/check.sh   one package's tests + coverage
#   SIM_DEST='platform=iOS Simulator,id=<udid>' scripts/check.sh   use your own simulator
#   scripts/check-selftest.sh              proves the gates fail on planted defects
#   CHECK_MODE=fast scripts/check.sh       incremental run for iteration; NOT valid for merge (D60)
#   CHECK_MODE=fast ONLY_TESTING=SensorTests/AppShellTests scripts/check.sh   chosen app tests only
#   PACKAGES=AlertEngine PKG_FILTER=UrgentLowSnoozeEndTests GATES=tests scripts/check.sh   swift test --filter
#   scripts/check.sh --verify-certify .build-logs/<dir> [<commit>]   is that log a full certify run?
#
# Modes (D60; docs/gates.md):
#   certify (default)  what merges rely on (D18): fresh build trees, every check below.
#   fast               persistent build trees (.derived/fast-build, .derived/fast-spm/<pkg>), so
#                      warnings in unchanged files are not re-reported; the Release build, the S2/S6
#                      Release-configuration tests and the S6 compile-out checks run only with
#                      FAST_RELEASE=1. Logs go to .build-logs/<timestamp>-fast/; --verify-certify
#                      rejects them.
#   Every run holds one of CHECK_SLOTS (default 2) machine-wide build slots (CHECK_SLOTS=0: none) and,
#   unless SIM_DEST is given, runs the simulator gates on its slot's pool simulator sensor-check-<n>
#   (scripts/sim-pool.sh): certify erases it first, fast uninstalls the test apps and resets its
#   Keychain. The simulator is shut down at exit unless KEEP_SIM_BOOTED=1.
#
# Gates:
#   build   xcodegen generate; plist/entitlement lint; xcodebuild app scheme for generic/platform=iOS,
#           Debug and Release, from a FRESH derived-data directory (a cached build prints no warnings),
#           zero project warnings.
#   tests   `swift test` for every package on the macOS host from a FRESH scratch path, with coverage
#           minimums; "0 tests executed" fails; the app's hosted unit tests (SensorTests) on the simulator.
#   safety  ≥ 1 passing `test_S<n>_…` for every rule S1…S8, none failing or skipped, no XCTSkip /
#           XCTExpectFailure in files that hold safety tests; S6 compile-out checks (ReplayKit and
#           `validateAllowingReplay` absent from Release objects, present in Debug); S6 caller checks.
#   replay  SensorUITests (app launched on each ReplayKit scenario) and SensorTests/ReplayScenarioTests
#           (alert assertions) on the iOS simulator; both suites must run and pass.
#
# Bash 3.2 compatible (macOS /bin/bash). Logs go to .build-logs/<timestamp>/.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
. "$ROOT/scripts/sim-pool.sh"   # build slots and pool simulators (D60)

# Mode and targeted-run settings (D60). PACKAGES_GIVEN is read before PACKAGES gets its default.
CHECK_MODE="${CHECK_MODE:-certify}"
PACKAGES_GIVEN="${PACKAGES:-}"
ONLY_TESTING="${ONLY_TESTING:-}"
PKG_FILTER="${PKG_FILTER:-}"
FAST_RELEASE="${FAST_RELEASE:-}"
CHECK_SLOTS="${CHECK_SLOTS:-2}"
FAST_BANNER="FAST MODE: incremental; warnings in unchanged files are not re-reported; NOT valid for merge"

GATES="${GATES:-build,tests,safety,replay}"
ALL_PACKAGES="GlucoseCore G7Kit GlucoseStore GlucoseStats AlertEngine TrioBridge NightscoutKit ReplayKit WidgetCore"
PACKAGES="${PACKAGES:-$ALL_PACKAGES}"
SAFETY_RULES="${SAFETY_RULES:-S1 S2 S3 S4 S5 S6 S7 S8}"
# A given SIM_DEST wins; otherwise sim_prepare points SIM_DEST at this run's pool simulator (D60).
SIM_DEST_GIVEN="${SIM_DEST:-}"
SIM_DEST=""
SIM_UDID=""
# ONLY_TESTING names hosted app tests; unless PACKAGES is given too, no package tests run.
if [ -n "$ONLY_TESTING" ] && [ -z "$PACKAGES_GIVEN" ]; then PACKAGES=""; fi
# Set by start_run once this run holds a build slot. Certify: LOGS=.build-logs/<timestamp>,
# BUILD_DD="$LOGS/dd" — fresh per run so every compile (and therefore every warning) is seen;
# package checkouts are shared. Fast: LOGS=.build-logs/<timestamp>-fast, BUILD_DD=.derived/fast-build.
STAMP=""
LOGS=""
BUILD_DD=""
BUILD_CONFIGS="Debug Release"
SIM_DD="$ROOT/.derived/sim"
SPM_CHECKOUTS="$ROOT/.derived/SourcePackages"
# Simulator test runs are signed ad hoc ("Sign to Run Locally") so entitlements such as Keychain
# access apply to the hosted tests; no team or provisioning profile is needed for the simulator.
SIM_SIGNING="CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES"

# Fresh build trees are ~0.5–1 GB per run; keep only the logs unless asked (KEEP_BUILD_DIRS=1).
# Fast mode's persistent trees under .derived/ are never deleted here.
cleanup_build_dirs() {
    [ "${KEEP_BUILD_DIRS:-}" = "1" ] && return
    [ -n "$LOGS" ] || return
    if [ "$CHECK_MODE" = "certify" ]; then rm -rf "$BUILD_DD"; fi
    rm -rf "$LOGS"/spm-*
}

FAILURES=0
SUMMARY=""

note()  { printf '%s\n' "$*"; }
pass()  { SUMMARY="$SUMMARY\nPASS  $*"; note "PASS  $*"; }
fail()  { SUMMARY="$SUMMARY\nFAIL  $*"; note "FAIL  $*"; FAILURES=$((FAILURES + 1)); }
wants() { case ",$GATES," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------------------------------------
# D60: modes, build slots, the pool simulator, and the run record (docs/gates.md)
# ---------------------------------------------------------------------------------------------

# A check this run left out on purpose (fast mode only; certify never skips).
skip()  { SUMMARY="$SUMMARY\nSKIP  $*"; note "SKIP  $*"; }

# SwiftPM scratch path for build $1: fresh under the log directory in certify (deleted at exit),
# persistent and incremental under .derived/fast-spm in fast mode.
spm_scratch() {
    if [ "$CHECK_MODE" = "fast" ]; then echo "$ROOT/.derived/fast-spm/$1"; else echo "$LOGS/spm-$1"; fi
}

# The Release-configuration safety steps (S2/S6 Release tests, S6 compile-out checks) run in
# certify, and in fast mode only with FAST_RELEASE=1.
release_checks_wanted() { [ "$CHECK_MODE" = "certify" ] || [ "$FAST_RELEASE" = "1" ]; }

# -only-testing/-skip-testing arguments for the hosted app tests: ONLY_TESTING (comma-separated
# test identifiers) when given, else all of SensorTests except the replay suite (gate 4 runs it).
app_test_selection() {
    if [ -z "$ONLY_TESTING" ]; then
        echo "-only-testing:SensorTests -skip-testing:SensorTests/ReplayScenarioTests"
    else
        printf '%s\n' "$ONLY_TESTING" | tr ',' '\n' \
            | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e 's/^/-only-testing:/' | tr '\n' ' '
    fi
}

# Appends key=value to the run record ($LOGS/RUN) that --verify-certify reads.
record() { [ -n "$LOGS" ] && printf '%s=%s\n' "$1" "$2" >> "$LOGS/RUN"; }

load_average() { sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | sed 's/^ *//; s/ *$//'; }

# Points SIM_DEST at a simulator for this run, once. A caller's SIM_DEST is used as given (not
# reset, not shut down). Otherwise this slot's pool simulator: certify erases it, so every certify
# run starts from a fresh device (app and App Group containers, UserDefaults, Keychain, notification
# and privacy grants, AlarmKit authorization); fast keeps it but uninstalls every installed app
# (which removes its data and App Group containers) and resets the Keychain. Either way it is
# booted here and shut down at exit (alarm noise, D60). docs/gates.md has the measurements.
sim_prepare() {
    [ -n "$SIM_DEST" ] && return 0
    local plog="$LOGS/sim-pool.log" idx="${SLOT:-0}" t0 action app left
    if [ -n "$SIM_DEST_GIVEN" ]; then
        SIM_DEST="$SIM_DEST_GIVEN"
        record sim "caller's SIM_DEST: $SIM_DEST_GIVEN (not reset or shut down by check.sh)"
        return 0
    fi
    t0="$(date +%s)"
    if ! pool_sim_ensure "$idx" >> "$plog" 2>&1; then
        fail "simulator pool: could not get $POOL_PREFIX$idx (see $plog)"
        return 1
    fi
    SIM_UDID="$POOL_UDID"
    if [ "$CHECK_MODE" = "certify" ]; then
        action="erased"
        xcrun simctl shutdown "$SIM_UDID" >> "$plog" 2>&1   # fails harmlessly if already shut down
        if ! xcrun simctl erase "$SIM_UDID" >> "$plog" 2>&1; then
            fail "simulator pool: could not erase $POOL_PREFIX$idx (see $plog)"
            return 1
        fi
    fi
    if ! xcrun simctl bootstatus "$SIM_UDID" -b >> "$plog" 2>&1; then
        sleep 5   # e.g. still shutting down from a previous run: try once more
        if ! xcrun simctl bootstatus "$SIM_UDID" -b >> "$plog" 2>&1; then
            fail "simulator pool: $POOL_PREFIX$idx did not boot (see $plog)"
            return 1
        fi
    fi
    if [ "$CHECK_MODE" = "fast" ]; then
        action="apps uninstalled, Keychain reset"
        for app in $(pool_user_apps "$SIM_UDID"); do
            xcrun simctl uninstall "$SIM_UDID" "$app" >> "$plog" 2>&1
        done
        xcrun simctl keychain "$SIM_UDID" reset >> "$plog" 2>&1
        left="$(pool_user_apps "$SIM_UDID")"
        if [ -n "$left" ]; then
            fail "simulator pool: could not uninstall from $POOL_PREFIX$idx: $(echo $left)"
            return 1
        fi
    fi
    [ "$POOL_CREATED" = "1" ] && action="created, $action"
    SIM_DEST="platform=iOS Simulator,id=$SIM_UDID"
    note "      simulator $POOL_PREFIX$idx ($SIM_UDID): ${action:-booted}; ready in $(( $(date +%s) - t0 )) s"
    record sim "$POOL_PREFIX$idx $SIM_UDID"
    record sim_reset "${action:-none}"
    record sim_ready_seconds "$(( $(date +%s) - t0 ))"
}

# Shuts this run's pool simulator down (KEEP_SIM_BOOTED=1 leaves it booted).
sim_release() {
    [ -n "$SIM_UDID" ] || return 0
    [ "${KEEP_SIM_BOOTED:-}" = "1" ] && return 0
    xcrun simctl shutdown "$SIM_UDID" >> "$LOGS/sim-pool.log" 2>&1
}

on_exit() {
    local status=$?
    cleanup_build_dirs
    sim_release
    slot_release
    if [ -n "$LOGS" ] && [ -d "$LOGS" ]; then
        printf '%s\n' "$status" > "$LOGS/EXIT_STATUS"
        printf '%b\n' "$SUMMARY" | sed '/^$/d' > "$LOGS/summary.txt"
        record finished "$(date '+%Y-%m-%d %H:%M:%S')"
        record elapsed_seconds "$(( $(date +%s) - RUN_START ))"
        record load_end "$(load_average)"
    fi
    if [ "$CHECK_MODE" = "fast" ]; then note "$FAST_BANNER"; fi
}

# Validates the settings, waits for a build slot, creates the log directory and the run record.
start_run() {
    local suffix="" dirty
    case "$CHECK_MODE" in
        certify|fast) ;;
        *) echo "check.sh: CHECK_MODE must be certify or fast, not '$CHECK_MODE'" >&2; exit 2 ;;
    esac
    case "$CHECK_SLOTS" in ''|*[!0-9]*) echo "check.sh: CHECK_SLOTS must be a number" >&2; exit 2 ;; esac
    if [ "$CHECK_MODE" = "fast" ]; then note "$FAST_BANNER"; fi
    RUN_START="$(date +%s)"
    trap on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    SLOT=""; SLOT_WAITED=0
    if [ "$CHECK_SLOTS" -gt 0 ]; then
        slot_acquire "$CHECK_SLOTS" "$CHECK_MODE $GATES" || { echo "check.sh: could not create $SLOT_ROOT" >&2; exit 2; }
    fi
    RUN_START="$(date +%s)"
    STAMP="$(date +%Y%m%d-%H%M%S)"
    if [ "$CHECK_MODE" = "fast" ]; then
        suffix="-fast"
        BUILD_DD="$ROOT/.derived/fast-build"
        [ "$FAST_RELEASE" = "1" ] || BUILD_CONFIGS="Debug"
    fi
    mkdir -p "$ROOT/.build-logs"
    LOGS="$ROOT/.build-logs/$STAMP$suffix"
    mkdir "$LOGS" 2>/dev/null || { LOGS="$LOGS-$$"; mkdir -p "$LOGS"; }
    [ "$CHECK_MODE" = "certify" ] && BUILD_DD="$LOGS/dd"
    printf '%s\n' "$CHECK_MODE" > "$LOGS/MODE"
    git status --porcelain > "$LOGS/git-status.txt" 2>&1
    dirty="$(wc -l < "$LOGS/git-status.txt" | tr -d ' ')"
    record mode "$CHECK_MODE"
    record logs "$LOGS"
    record commit "$(git rev-parse HEAD 2>/dev/null)"
    record branch "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    record dirty "$dirty"
    record check_sh "$(git hash-object scripts/check.sh 2>/dev/null)"
    record gates "$GATES"
    record packages "$PACKAGES"
    record all_packages "$ALL_PACKAGES"
    record safety_rules "$SAFETY_RULES"
    record only_testing "$ONLY_TESTING"
    record pkg_filter "$PKG_FILTER"
    record app_tests "${APP_TESTS:-}"
    record fast_release "$FAST_RELEASE"
    record build_dd "$BUILD_DD"
    record spm_scratch "$(spm_scratch '<pkg>')"
    record slot "${SLOT:-none} of $CHECK_SLOTS (waited $SLOT_WAITED s)"
    record started "$(date '+%Y-%m-%d %H:%M:%S')"
    record load_start "$(load_average)"
    note "check.sh: $CHECK_MODE run, build slot ${SLOT:-none} of $CHECK_SLOTS (waited $SLOT_WAITED s), load $(load_average), logs $LOGS"
}

# --verify-certify <log directory> [<commit>]: succeeds only for a complete certify run — every
# gate, every package and safety rule, no test selection, fresh build trees, a clean worktree,
# exit 0, no FAIL or SKIP — optionally of the given commit. Reviewers use it on an author's logs.
verify_certify() {
    local dir="${1:-}" want="${2:-}" problems="" lacking="" mode gates exit_status want_sha commit pkg rule re n f
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        echo "usage: scripts/check.sh --verify-certify <.build-logs/directory> [<commit>]" >&2
        return 2
    fi
    dir="$(cd "$dir" && pwd)"
    problem() { problems="$problems
  - $*"; }
    run_field() { sed -n "s/^$1=//p" "$dir/RUN" 2>/dev/null | tail -n 1; }

    mode="$(cat "$dir/MODE" 2>/dev/null)"
    case "$mode" in
        certify) ;;
        fast) problem "mode is fast: incremental build trees, warnings in unchanged files not re-reported; NOT valid for merge" ;;
        "")   problem "no MODE file: not written by a D60 check.sh, so its mode and build trees are unknown" ;;
        *)    problem "unknown mode '$mode'" ;;
    esac
    if [ ! -f "$dir/RUN" ]; then
        problem "no RUN record"
    else
        [ "$(run_field mode)" = "certify" ] || problem "RUN record says mode=$(run_field mode)"
        gates="$(run_field gates | tr ',' '\n' | sed '/^$/d' | sort -u | tr '\n' ',')"
        [ "$gates" = "build,replay,safety,tests," ] || problem "gates were '$(run_field gates)', not build,tests,safety,replay"
        [ "$(run_field packages)" = "$ALL_PACKAGES" ] || problem "packages were '$(run_field packages)', not all of '$ALL_PACKAGES'"
        [ "$(run_field safety_rules)" = "S1 S2 S3 S4 S5 S6 S7 S8" ] || problem "safety rules were '$(run_field safety_rules)', not S1…S8"
        [ -z "$(run_field only_testing)" ] || problem "ONLY_TESTING was set: $(run_field only_testing)"
        [ -z "$(run_field pkg_filter)" ] || problem "PKG_FILTER was set: $(run_field pkg_filter)"
        [ "$(run_field build_dd)" = "$(run_field logs)/dd" ] || problem "build trees not fresh: generic-iOS derived data was $(run_field build_dd), not the run's own $(run_field logs)/dd"
        [ "$(run_field spm_scratch)" = "$(run_field logs)/spm-<pkg>" ] || problem "build trees not fresh: SwiftPM scratch paths were $(run_field spm_scratch)"
        [ "$(run_field dirty)" = "0" ] || problem "the worktree had $(run_field dirty) uncommitted change(s) (git-status.txt), so this is not a run of commit $(run_field commit)"
        commit="$(run_field commit)"
        if [ -n "$want" ]; then
            want_sha="$(git rev-parse --verify -q "$want^{commit}" 2>/dev/null)"
            case "$commit" in
                "${want_sha:-$want}"*) ;;
                *) problem "commit is $commit, not $want" ;;
            esac
        fi
    fi
    exit_status="$(cat "$dir/EXIT_STATUS" 2>/dev/null)"
    [ "$exit_status" = "0" ] || problem "exit status ${exit_status:-missing (interrupted, or still running)}"
    f="$dir/summary.txt"
    if [ ! -f "$f" ]; then
        problem "no summary.txt"
    else
        n="$(grep -c '^FAIL' "$f")"; [ "$n" = "0" ] || problem "$n FAIL line(s) in summary.txt"
        n="$(grep -c '^SKIP' "$f")"; [ "$n" = "0" ] || problem "$n SKIP line(s) in summary.txt"
        for re in 'Info.plist and entitlements lint' 'build Debug \(clean\), zero warnings' \
            'build Release \(clean\), zero warnings' 'app unit tests — [0-9]+ executed' \
            'no XCTSkip/XCTExpectFailure in safety-test files' \
            'S6: test_S6_releaseBuildRefusesReplayReadings ran in Release and passed' \
            'S6: ReplayKit absent from Release' 'S6: LiveReadingGate.validateAllowingReplay absent from Release' \
            'S6: GlucoseStore replay role absent from Release' \
            'replay run — suite ReplayScenarioTests passed' 'replay run — suite SensorUITests.xctest passed'; do
            grep -qE "^PASS  $re" "$f" || lacking="$lacking; $(printf '%s' "$re" | sed -e 's/\\//g' -e 's/ — \[0-9\]+ executed$//')"
        done
        for pkg in $ALL_PACKAGES; do
            grep -qE "^PASS  $pkg tests — [0-9]+ executed" "$f" || lacking="$lacking; $pkg tests"
        done
        for pkg in $RELEASE_SAFETY_PACKAGES; do
            grep -qE "^PASS  S2/S6 Release-configuration tests in $pkg:" "$f" || lacking="$lacking; $pkg Release-configuration S2/S6 tests"
        done
        for rule in S1 S2 S3 S4 S5 S6 S7 S8; do
            grep -qE "^PASS  $rule: [0-9]+ passing" "$f" || lacking="$lacking; $rule safety tests"
        done
        [ -z "$lacking" ] || problem "summary.txt has no PASS line for: ${lacking#; }"
    fi
    if [ -n "$problems" ]; then
        echo "verify-certify: NOT a complete certify run: $dir$problems"
        return 1
    fi
    echo "verify-certify: OK, a complete certify run: $dir"
    echo "  commit $commit ($(run_field branch)), clean worktree; gates build,tests,safety,replay; all packages; S1–S8"
    echo "  fresh build trees ($(run_field build_dd)); exit 0; no FAIL or SKIP"
    echo "  started $(run_field started), elapsed $(run_field elapsed_seconds) s, load $(run_field load_start) → $(run_field load_end); simulator $(run_field sim) ($(run_field sim_reset))"
}

# Minimum line coverage per package (HANDOFF §10 gate 2). Empty = report only.
coverage_min() {
    case "$1" in
        GlucoseStats) echo 95 ;;
        AlertEngine)  echo 90 ;;
        TrioBridge)   echo 90 ;;
        G7Kit)        echo 90 ;;
        *)            echo "" ;;
    esac
}
# Which sources the minimum applies to. G7Kit's target is its message parsers only.
coverage_scope() {
    case "$1" in
        G7Kit) echo "Sources/G7Kit/Messages" ;;
        *)     echo "Sources/$1" ;;
    esac
}

# Project warnings, ignoring third-party checkouts and known tool noise (listed here, not hidden).
project_warnings() {
    grep -E ': warning: |^warning: ' "$1" \
        | grep -v '/SourcePackages/checkouts/' \
        | grep -v '/checkouts/GRDB' \
        | grep -v 'appintentsmetadataprocessor.*Metadata extraction skipped' \
        | sort -u
}

# "Executed N tests" → N from the last summary line of a log (empty if none).
executed_count() {
    grep -E "Executed [0-9]+ tests?" "$1" | tail -1 | sed -E 's/.*Executed ([0-9]+) tests?.*/\1/'
}

xcodegen_generate() {
    if ! command -v xcodegen >/dev/null 2>&1; then
        fail "xcodegen not installed (brew install xcodegen)"
        return 1
    fi
    xcodegen generate --quiet > "$LOGS/xcodegen.log" 2>&1 || { fail "xcodegen generate (see $LOGS/xcodegen.log)"; return 1; }
}

# ---------------------------------------------------------------------------------------------
# Gate 1 — build
# ---------------------------------------------------------------------------------------------
gate_build() {
    note "== Gate 1: build =="
    xcodegen_generate || return

    lint_failed=0
    for plist in App/Info.plist Widgets/Info.plist App/*.entitlements Widgets/*.entitlements; do
        plutil -lint "$plist" > /dev/null 2>&1 || { fail "plist lint: $plist"; lint_failed=1; }
    done
    [ $lint_failed -eq 0 ] && pass "Info.plist and entitlements lint"

    for config in $BUILD_CONFIGS; do
        log="$LOGS/build-$config.log"
        xcodebuild build -project Sensor.xcodeproj -scheme Sensor -configuration "$config" \
            -destination 'generic/platform=iOS' -derivedDataPath "$BUILD_DD" \
            -clonedSourcePackagesDirPath "$SPM_CHECKOUTS" \
            CODE_SIGNING_ALLOWED=NO > "$log" 2>&1
        status=$?
        warnings="$(project_warnings "$log")"
        if [ $status -ne 0 ]; then
            fail "build $config (exit $status, see $log)"
            grep -E ': error: ' "$log" | sort -u | head -20
        elif [ -n "$warnings" ]; then
            fail "build $config has warnings:"
            printf '%s\n' "$warnings" | head -20
        else
            pass "build $config (clean), zero warnings"
        fi
    done
    if [ "$BUILD_CONFIGS" = "Debug" ]; then skip "build Release (fast mode; FAST_RELEASE=1 builds it)"; fi
}

# ---------------------------------------------------------------------------------------------
# Gate 2 — unit tests (+ coverage)
# ---------------------------------------------------------------------------------------------
package_tests() {
    pkg="$1"
    dir="$ROOT/Packages/$pkg"
    log="$LOGS/test-$pkg.log"
    scratch="$(spm_scratch "$pkg")"
    (cd "$dir" && swift test --enable-code-coverage --scratch-path "$scratch" ${PKG_FILTER:+--filter "$PKG_FILTER"}) > "$log" 2>&1
    status=$?
    warnings="$(project_warnings "$log")"
    count="$(executed_count "$log")"
    if [ $status -ne 0 ]; then
        fail "$pkg tests (exit $status, see $log)"
        grep -E "error:|failed" "$log" | head -20
        return
    fi
    if [ -n "$warnings" ]; then
        fail "$pkg has warnings:"
        printf '%s\n' "$warnings" | head -20
    fi
    if [ -z "$count" ] || [ "$count" = "0" ]; then
        fail "$pkg executed no tests"
        return
    fi
    pass "$pkg tests — $count executed, 0 failures"

    # Coverage: llvm-cov over the package's own sources only.
    bin_dir="$(cd "$dir" && swift build --show-bin-path --scratch-path "$scratch" 2>/dev/null)"
    profdata="$bin_dir/codecov/default.profdata"
    xctest_bin="$bin_dir/${pkg}PackageTests.xctest/Contents/MacOS/${pkg}PackageTests"
    scope="$dir/$(coverage_scope "$pkg")"
    min="$(coverage_min "$pkg")"
    # A PKG_FILTER run covers part of the package: report its coverage, don't apply the minimum.
    if [ -n "$PKG_FILTER" ]; then min=""; fi
    if [ ! -f "$profdata" ] || [ ! -f "$xctest_bin" ]; then
        if [ -n "$min" ]; then fail "$pkg coverage: no profile data"; else note "      $pkg coverage: no profile data"; fi
        return
    fi
    scope_files="$(find "$scope" -name '*.swift' 2>/dev/null | sort)"
    if [ -z "$scope_files" ]; then
        if [ -n "$min" ]; then fail "$pkg coverage: no sources under $(coverage_scope "$pkg")"; fi
        return
    fi
    # Pass the files explicitly; llvm-cov ignores directory arguments and would report dependencies too.
    report="$(xcrun llvm-cov report "$xctest_bin" -instr-profile="$profdata" $scope_files 2>/dev/null)"
    printf '%s\n' "$report" > "$LOGS/coverage-$pkg.txt"
    # TOTAL row columns: Regions Missed Cover Functions Missed Executed Lines Missed Cover ...
    lines_cover="$(printf '%s\n' "$report" | awk '/^TOTAL/ { gsub("%", "", $10); print $10 }')"
    if [ -z "$lines_cover" ]; then
        if [ -n "$min" ]; then fail "$pkg coverage: could not read report"; else note "      $pkg coverage: n/a"; fi
        return
    fi
    if [ -n "$min" ]; then
        if awk -v c="$lines_cover" -v m="$min" 'BEGIN { exit !(c + 0 >= m + 0) }'; then
            pass "$pkg line coverage ${lines_cover}% (min ${min}%, $(coverage_scope "$pkg"))"
        else
            fail "$pkg line coverage ${lines_cover}% < ${min}% ($(coverage_scope "$pkg"))"
        fi
    else
        note "      $pkg line coverage ${lines_cover}%"
    fi
}

app_tests() {
    log="$LOGS/test-app-unit.log"
    xcodegen_generate || return
    sim_prepare || return
    xcodebuild test -project Sensor.xcodeproj -scheme Sensor -destination "$SIM_DEST" \
        -derivedDataPath "$SIM_DD" -clonedSourcePackagesDirPath "$SPM_CHECKOUTS" \
        $(app_test_selection) \
        $SIM_SIGNING > "$log" 2>&1
    status=$?
    count="$(executed_count "$log")"
    if [ $status -ne 0 ]; then
        fail "app unit tests (exit $status, see $log)"
        grep -E "error:|failed" "$log" | head -20
    elif [ -z "$count" ] || [ "$count" = "0" ]; then
        fail "app unit tests executed no tests"
    elif grep -qE "Test Case .*' skipped" "$log"; then
        fail "app unit tests: skipped tests (hosted tests must run): $(grep -E "Test Case .*' skipped" "$log" | sed -E "s/.*\\[(.*)\\]' skipped.*/\\1/" | tr '\\n' ' ')"
    else
        pass "app unit tests — $count executed, 0 failures, 0 skipped"
    fi
}

gate_tests() {
    note "== Gate 2: unit tests =="
    for pkg in $PACKAGES; do package_tests "$pkg"; done
    # The app's hosted tests run with the full package list (unless PKG_FILTER narrows the run),
    # with APP_TESTS=1, or when ONLY_TESTING names some of them.
    if { [ "$PACKAGES" = "$ALL_PACKAGES" ] && [ -z "$PKG_FILTER" ]; } || [ "${APP_TESTS:-}" = "1" ] \
        || [ -n "$ONLY_TESTING" ]; then
        app_tests
    fi
}

# ---------------------------------------------------------------------------------------------
# Gate 3 — safety tests (test_S1_… through test_S8_…) and S6 compile-out checks
# ---------------------------------------------------------------------------------------------

# Defined symbols matching $2 in the object files of package $1 built in configuration $3.
symbol_count() {
    pkg="$1"; pattern="$2"; config="$3"
    scratch="$(spm_scratch "nm-$pkg-$config")"
    (cd "$ROOT/Packages/$pkg" && swift build -c "$config" --scratch-path "$scratch") > "$LOGS/nm-$pkg-$config.log" 2>&1 || { echo "BUILD_FAILED"; return; }
    objs="$(find "$scratch/$config/$pkg.build" -name '*.o' 2>/dev/null)"
    if [ -z "$objs" ]; then echo "NO_OBJECTS"; return; fi
    nm -U $objs 2>/dev/null | grep -c -F -- "$pattern"
}

compiled_out_check() {
    pkg="$1"; pattern="$2"; label="$3"
    rel="$(symbol_count "$pkg" "$pattern" release)"
    dbg="$(symbol_count "$pkg" "$pattern" debug)"
    case "$rel$dbg" in *BUILD_FAILED*|*NO_OBJECTS*) fail "S6: $label check could not inspect objects (release=$rel debug=$dbg)"; return ;; esac
    if [ "$dbg" = "0" ]; then
        fail "S6: $label has no symbols even in Debug — the check would pass vacuously"
    elif [ "$rel" != "0" ]; then
        fail "S6: $label defines $rel symbols in Release — wrap it in #if DEBUG"
    else
        pass "S6: $label absent from Release ($dbg symbols in Debug)"
    fi
}

# S2/S6 safety tests built in the Release configuration (no DEBUG), so `#else` branches such as
# AlertEngine's test_S6_releaseBuildRefusesReplayReadings run too (Phase 3 audit m3). The debug
# runs of gate 2 never compile them. `-enable-testing` keeps `@testable import` working.
RELEASE_SAFETY_PACKAGES="GlucoseCore AlertEngine TrioBridge NightscoutKit"

release_safety_tests() {
    pkg="$1"
    log="$LOGS/reltest-$pkg.log"
    scratch="$(spm_scratch "rel-$pkg")"
    (cd "$ROOT/Packages/$pkg" && swift test -c release -Xswiftc -enable-testing \
        --scratch-path "$scratch" --filter 'test_S[26]_') > "$log" 2>&1
    status=$?
    passed="$(grep -E "Test Case .*test_S[26]_[A-Za-z0-9_]*\]' passed" "$log" | sort -u | wc -l | tr -d ' ')"
    if [ $status -ne 0 ]; then
        fail "S2/S6 Release-configuration tests in $pkg (exit $status, see $log)"
        grep -E "error:|failed" "$log" | head -20
    elif [ "$passed" = "0" ]; then
        fail "S2/S6 Release-configuration tests in $pkg: none ran"
    else
        pass "S2/S6 Release-configuration tests in $pkg: $passed passing"
    fi
}

gate_safety() {
    note "== Gate 3: safety tests =="
    logs="$(ls "$LOGS"/test-*.log 2>/dev/null)"
    if [ -z "$logs" ]; then
        fail "safety: no test logs in this run (run with the tests gate)"
    else
        for rule in $SAFETY_RULES; do
            # XCTest prints: Test Case '-[Module.Class test_S1_name]' passed (0.001 seconds).
            passed="$(cat $logs | grep -E "Test Case .*test_${rule}_[A-Za-z0-9_]*\]' passed" | sort -u | wc -l | tr -d ' ')"
            failed="$(cat $logs | grep -E "Test Case .*test_${rule}_[A-Za-z0-9_]*\]' failed" | sort -u | wc -l | tr -d ' ')"
            skipped="$(cat $logs | grep -E "Test Case .*test_${rule}_[A-Za-z0-9_]*\]' skipped" | sort -u | wc -l | tr -d ' ')"
            if [ "$failed" != "0" ]; then
                fail "$rule: $failed failing safety test(s)"
            elif [ "$skipped" != "0" ]; then
                fail "$rule: $skipped skipped safety test(s) — safety tests may not skip"
            elif [ "$passed" = "0" ]; then
                fail "$rule: no passing test_${rule}_… test"
            else
                pass "$rule: $passed passing safety test(s)"
            fi
        done
    fi

    # A safety test that can skip or that expects failure proves nothing.
    evasive="$(grep -rlE 'func test_S[1-8]_' Packages/*/Tests AppTests AppUITests 2>/dev/null \
        | xargs grep -lE 'XCTSkip|XCTExpectFailure' 2>/dev/null)"
    if [ -n "$evasive" ]; then
        fail "safety tests live in files using XCTSkip/XCTExpectFailure: $(echo $evasive)"
    else
        pass "no XCTSkip/XCTExpectFailure in safety-test files"
    fi

    # Release-configuration builds: always in certify; in fast mode only with FAST_RELEASE=1 (D60).
    if release_checks_wanted; then
        for pkg in $RELEASE_SAFETY_PACKAGES; do
            case " $PACKAGES " in *" $pkg "*) release_safety_tests "$pkg" ;; esac
        done
        # The one test that exists only without DEBUG must have run (and passed) when AlertEngine is in scope.
        case " $PACKAGES " in *" AlertEngine "*)
            if grep -qE "test_S6_releaseBuildRefusesReplayReadings\]' passed" "$LOGS/reltest-AlertEngine.log" 2>/dev/null; then
                pass "S6: test_S6_releaseBuildRefusesReplayReadings ran in Release and passed"
            else
                fail "S6: test_S6_releaseBuildRefusesReplayReadings did not pass in the Release configuration"
            fi ;;
        esac

        # S6: replay code and the replay-accepting gate must not exist in Release builds.
        compiled_out_check ReplayKit '$s9ReplayKit' "ReplayKit"
        compiled_out_check GlucoseCore 'validateAllowingReplay' "LiveReadingGate.validateAllowingReplay"
        # GlucoseStore's replay role and its factories (D20) — mangled prefix of GlucoseStore.replay(…).
        compiled_out_check GlucoseStore '$s12GlucoseStoreAAC6replay' "GlucoseStore replay role"
    else
        skip "S2/S6 Release-configuration tests and S6 compile-out checks (fast mode; FAST_RELEASE=1 runs them)"
    fi

    # S6 / D11: only the alert engine and the app's replay wiring may call validateAllowingReplay.
    callers="$(grep -rl 'validateAllowingReplay' Packages/*/Sources App/Sources Widgets/Sources 2>/dev/null \
        | grep -vE '^Packages/(GlucoseCore|AlertEngine)/Sources/|^App/Sources/')"
    if [ -n "$callers" ]; then
        fail "S6: validateAllowingReplay used outside AlertEngine/App: $(echo $callers)"
    else
        pass "S6: validateAllowingReplay only in GlucoseCore, AlertEngine, App"
    fi

    # S4 / D21: the Trio LOW/HIGH sentinel may be enabled outside TrioBridge only on lines citing D21.
    sentinel="$(grep -rn 'writeSentinel' App/Sources Packages/*/Sources 2>/dev/null \
        | grep -v '^Packages/TrioBridge/' | grep -v 'D21')"
    if [ -n "$sentinel" ]; then
        fail "S4: .writeSentinel used outside TrioBridge without citing D21: $(echo $sentinel)"
    else
        pass "S4: .writeSentinel outside TrioBridge only on lines citing D21"
    fi

    # S6: non-test code outside ReplayKit that constructs .replay/.mock readings must sit inside an
    # `#if DEBUG` block (tracked per line through nested #if/#else/#endif; an #else branch of
    # `#if DEBUG` is not guarded). Heuristic only: it misses `source:` split across lines or a
    # source passed through a variable. The real defences are LiveReadingGate and the production
    # store refusing replay/mock rows (D20).
    files="$(grep -rlE 'source: *\.(replay|mock)' Packages/*/Sources App/Sources Widgets/Sources 2>/dev/null \
        | grep -vE '^Packages/(ReplayKit|GlucoseCore)/Sources/')"
    unguarded=""
    if [ -n "$files" ]; then
        unguarded="$(awk '
            FNR == 1 { depth = 0 }
            /^[[:space:]]*#if[[:space:]]+DEBUG[[:space:]]*($|\/\/|&&)/ { depth++; st[depth] = 1; next }
            /^[[:space:]]*#if/                  { depth++; st[depth] = 0; next }
            /^[[:space:]]*#(else|elseif)/       { if (depth > 0) st[depth] = 0; next }
            /^[[:space:]]*#endif/               { if (depth > 0) depth--; next }
            /source:[[:space:]]*\.(replay|mock)/ {
                guarded = 0
                for (i = 1; i <= depth; i++) if (st[i] == 1) guarded = 1
                if (!guarded) printf "%s:%d ", FILENAME, FNR
            }' $files)"
    fi
    if [ -n "$unguarded" ]; then
        fail "S6: .replay/.mock readings constructed outside #if DEBUG at: $unguarded"
    else
        pass "S6: .replay/.mock construction outside ReplayKit is DEBUG-guarded"
    fi
}

# ---------------------------------------------------------------------------------------------
# Gate 4 — replay run in the simulator
# ---------------------------------------------------------------------------------------------
gate_replay() {
    note "== Gate 4: replay run =="
    xcodegen_generate || return
    sim_prepare || return
    log="$LOGS/test-app-replay.log"
    xcodebuild test -project Sensor.xcodeproj -scheme Sensor -destination "$SIM_DEST" \
        -derivedDataPath "$SIM_DD" -clonedSourcePackagesDirPath "$SPM_CHECKOUTS" \
        -only-testing:SensorUITests -only-testing:SensorTests/ReplayScenarioTests \
        $SIM_SIGNING > "$log" 2>&1
    status=$?
    if [ $status -ne 0 ]; then
        fail "replay run (exit $status, see $log)"
        grep -E "error:|failed" "$log" | head -20
        return
    fi
    for suite in ReplayScenarioTests SensorUITests.xctest; do
        if grep -qE "Test Suite '$suite' passed" "$log"; then
            pass "replay run — suite $suite passed"
        else
            fail "replay run — suite $suite did not run (see $log)"
        fi
    done
}

if [ "${1:-}" = "--verify-certify" ]; then
    verify_certify "${2:-}" "${3:-}"
    exit $?
fi
start_run

wants build  && gate_build
wants tests  && gate_tests
wants safety && gate_safety
wants replay && gate_replay

note ""
note "Elapsed $(( $(date +%s) - RUN_START )) s in build slot ${SLOT:-none} of $CHECK_SLOTS (waited $SLOT_WAITED s); load now $(load_average)"
note "== Summary ($LOGS) =="
printf '%b\n' "$SUMMARY" | sed '/^$/d'
if [ "$FAILURES" -ne 0 ]; then
    note "$FAILURES gate check(s) failed."
    exit 1
fi
note "All requested gates passed."
