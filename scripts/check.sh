#!/usr/bin/env bash
# Runs the HANDOFF §10 validation gates locally and exits non-zero on any failure.
#
#   scripts/check.sh                       all gates: build, tests, safety, replay
#   GATES=build,tests scripts/check.sh     a subset (used for Phase 1 merges into `integration`)
#   PACKAGES="GlucoseStats" GATES=tests scripts/check.sh   one package's tests + coverage
#   SIM_DEST='platform=iOS Simulator,id=<udid>' scripts/check.sh   use your own simulator
#
# Gates:
#   build   xcodegen generate; xcodebuild app scheme for generic/platform=iOS, Debug and Release,
#           zero warnings (Swift 6, strict concurrency complete, warnings are errors).
#   tests   `swift test` for every package on the macOS host with coverage + minimums; the app's
#           hosted unit tests (SensorTests) on the iOS simulator.
#   safety  at least one passing `test_S<n>_…` for every rule S1…S8 and no failing ones; ReplayKit
#           compiles to nothing in Release (S6).
#   replay  SensorUITests (app launched on each ReplayKit scenario) and SensorTests/Replay* alert
#           assertions on the iOS simulator.
#
# Bash 3.2 compatible (macOS /bin/bash). Logs go to .build-logs/<timestamp>/.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

GATES="${GATES:-build,tests,safety,replay}"
ALL_PACKAGES="GlucoseCore G7Kit GlucoseStore GlucoseStats AlertEngine TrioBridge NightscoutKit ReplayKit WidgetCore"
PACKAGES="${PACKAGES:-$ALL_PACKAGES}"
SAFETY_RULES="${SAFETY_RULES:-S1 S2 S3 S4 S5 S6 S7 S8}"
SIM_DEST="${SIM_DEST:-platform=iOS Simulator,name=iPhone 17,OS=latest}"
DERIVED="$ROOT/.derived"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOGS="$ROOT/.build-logs/$STAMP"
mkdir -p "$LOGS"

FAILURES=0
SUMMARY=""

note()  { printf '%s\n' "$*"; }
pass()  { SUMMARY="$SUMMARY\nPASS  $*"; note "PASS  $*"; }
fail()  { SUMMARY="$SUMMARY\nFAIL  $*"; note "FAIL  $*"; FAILURES=$((FAILURES + 1)); }
wants() { case ",$GATES," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

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

# Project warnings, ignoring third-party checkouts and known tool noise (listed, not hidden).
project_warnings() {
    grep -E ': warning: |^warning: ' "$1" \
        | grep -v '/SourcePackages/checkouts/' \
        | grep -v '/\.build/checkouts/' \
        | grep -v 'appintentsmetadataprocessor.*Metadata extraction skipped' \
        | sort -u
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
    for config in Debug Release; do
        log="$LOGS/build-$config.log"
        xcodebuild build -project Sensor.xcodeproj -scheme Sensor -configuration "$config" \
            -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
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
            pass "build $config, zero warnings"
        fi
    done
}

# ---------------------------------------------------------------------------------------------
# Gate 2 — unit tests (+ coverage)
# ---------------------------------------------------------------------------------------------
package_tests() {
    pkg="$1"
    dir="$ROOT/Packages/$pkg"
    log="$LOGS/test-$pkg.log"
    (cd "$dir" && swift test --enable-code-coverage) > "$log" 2>&1
    status=$?
    warnings="$(project_warnings "$log")"
    executed="$(grep -E "Executed [0-9]+ tests?" "$log" | tail -1 | sed -E 's/^[[:space:]]*//')"
    if [ $status -ne 0 ]; then
        fail "$pkg tests (exit $status, see $log)"
        grep -E "error:|failed" "$log" | head -20
        return
    fi
    if [ -n "$warnings" ]; then
        fail "$pkg has warnings:"
        printf '%s\n' "$warnings" | head -20
    fi
    pass "$pkg tests — $executed"

    # Coverage: llvm-cov over the package's own sources only.
    bin_dir="$(cd "$dir" && swift build --show-bin-path 2>/dev/null)"
    profdata="$bin_dir/codecov/default.profdata"
    xctest_bin="$bin_dir/${pkg}PackageTests.xctest/Contents/MacOS/${pkg}PackageTests"
    scope="$dir/$(coverage_scope "$pkg")"
    min="$(coverage_min "$pkg")"
    if [ ! -f "$profdata" ] || [ ! -f "$xctest_bin" ]; then
        [ -n "$min" ] && fail "$pkg coverage: no profile data" || note "      $pkg coverage: no profile data"
        return
    fi
    scope_files="$(find "$scope" -name '*.swift' 2>/dev/null | sort)"
    if [ -z "$scope_files" ]; then
        [ -n "$min" ] && fail "$pkg coverage: no sources under $(coverage_scope "$pkg")" || true
        return
    fi
    # Pass the files explicitly; llvm-cov ignores directory arguments and would report dependencies too.
    report="$(xcrun llvm-cov report "$xctest_bin" -instr-profile="$profdata" $scope_files 2>/dev/null)"
    printf '%s\n' "$report" > "$LOGS/coverage-$pkg.txt"
    # TOTAL row columns: Regions Missed Cover Functions Missed Executed Lines Missed Cover ...
    lines_cover="$(printf '%s\n' "$report" | awk '/^TOTAL/ { gsub("%", "", $10); print $10 }')"
    if [ -z "$lines_cover" ]; then
        [ -n "$min" ] && fail "$pkg coverage: could not read report" || note "      $pkg coverage: n/a"
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
    xcodebuild test -project Sensor.xcodeproj -scheme Sensor -destination "$SIM_DEST" \
        -derivedDataPath "$DERIVED" -only-testing:SensorTests -skip-testing:SensorTests/ReplayScenarioTests \
        CODE_SIGNING_ALLOWED=NO > "$log" 2>&1
    status=$?
    executed="$(grep -E "Executed [0-9]+ tests?" "$log" | tail -1 | sed -E 's/^[[:space:]]*//')"
    if [ $status -ne 0 ]; then
        fail "app unit tests (exit $status, see $log)"
        grep -E "error:|failed" "$log" | head -20
    else
        pass "app unit tests — ${executed:-0 tests}"
    fi
}

gate_tests() {
    note "== Gate 2: unit tests =="
    for pkg in $PACKAGES; do package_tests "$pkg"; done
    if [ "$PACKAGES" = "$ALL_PACKAGES" ] || [ "${APP_TESTS:-}" = "1" ]; then app_tests; fi
}

# ---------------------------------------------------------------------------------------------
# Gate 3 — safety tests (test_S1_… through test_S8_…)
# ---------------------------------------------------------------------------------------------
gate_safety() {
    note "== Gate 3: safety tests =="
    logs="$(ls "$LOGS"/test-*.log 2>/dev/null)"
    if [ -z "$logs" ]; then
        fail "safety: no test logs in this run (run with the tests gate)"
        return
    fi
    for rule in $SAFETY_RULES; do
        # XCTest prints: Test Case '-[Module.Class test_S1_name]' passed (0.001 seconds).
        passed="$(cat $logs | grep -E "Test Case .*test_${rule}_[A-Za-z0-9_]*\]' passed" | sort -u | wc -l | tr -d ' ')"
        failed="$(cat $logs | grep -E "Test Case .*test_${rule}_[A-Za-z0-9_]*\]' failed" | sort -u | wc -l | tr -d ' ')"
        if [ "$failed" != "0" ]; then
            fail "$rule: $failed failing safety test(s)"
        elif [ "$passed" = "0" ]; then
            fail "$rule: no passing test_${rule}_… test"
        else
            pass "$rule: $passed passing safety test(s)"
        fi
    done

    # S6: ReplayKit must compile to nothing in Release. Build it alone in release and in debug
    # and compare the symbols defined in its own module ($s9ReplayKit… is its Swift mangling prefix).
    rk="$ROOT/Packages/ReplayKit"
    (cd "$rk" && swift build -c release) > "$LOGS/replaykit-release.log" 2>&1 || { fail "S6: ReplayKit release build failed"; return; }
    rel_objs="$(find "$rk/.build/release/ReplayKit.build" -name '*.o' 2>/dev/null)"
    rel_syms=0
    [ -n "$rel_objs" ] && rel_syms="$(nm -U $rel_objs 2>/dev/null | grep -c '\$s9ReplayKit')"
    if [ "$rel_syms" = "0" ]; then
        pass "S6: ReplayKit defines no symbols in Release"
    else
        fail "S6: ReplayKit defines $rel_syms symbols in Release — wrap every source in #if DEBUG"
    fi
}

# ---------------------------------------------------------------------------------------------
# Gate 4 — replay run in the simulator
# ---------------------------------------------------------------------------------------------
gate_replay() {
    note "== Gate 4: replay run =="
    xcodegen_generate || return
    if ! ls "$ROOT"/AppTests/Replay*.swift >/dev/null 2>&1; then
        fail "replay: no AppTests/Replay*.swift (alert assertions per ReplayKit scenario) — lands in Phase 2"
    fi
    log="$LOGS/test-app-replay.log"
    xcodebuild test -project Sensor.xcodeproj -scheme Sensor -destination "$SIM_DEST" \
        -derivedDataPath "$DERIVED" -only-testing:SensorUITests -only-testing:SensorTests/ReplayScenarioTests \
        CODE_SIGNING_ALLOWED=NO > "$log" 2>&1
    status=$?
    executed="$(grep -E "Executed [0-9]+ tests?" "$log" | tail -1 | sed -E 's/^[[:space:]]*//')"
    count="$(printf '%s' "$executed" | sed -E 's/^Executed ([0-9]+).*/\1/')"
    if [ $status -ne 0 ]; then
        fail "replay run (exit $status, see $log)"
        grep -E "error:|failed" "$log" | head -20
    elif [ -z "$count" ] || [ "$count" = "0" ]; then
        fail "replay run executed no tests"
    else
        pass "replay run — $executed"
    fi
}

wants build  && gate_build
wants tests  && gate_tests
wants safety && gate_safety
wants replay && gate_replay

note ""
note "== Summary ($LOGS) =="
printf '%b\n' "$SUMMARY" | sed '/^$/d'
if [ "$FAILURES" -ne 0 ]; then
    note "$FAILURES gate check(s) failed."
    exit 1
fi
note "All requested gates passed."
