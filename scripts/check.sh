#!/usr/bin/env bash
# Runs the HANDOFF §10 validation gates locally and exits non-zero on any failure.
#
#   scripts/check.sh                       all gates: build, tests, safety, replay
#   GATES=build,tests scripts/check.sh     a subset (used for Phase 1 merges into `integration`)
#   PACKAGES="GlucoseStats" GATES=tests scripts/check.sh   one package's tests + coverage
#   SIM_DEST='platform=iOS Simulator,id=<udid>' scripts/check.sh   use your own simulator
#   scripts/check-selftest.sh              proves the gates fail on planted defects
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

GATES="${GATES:-build,tests,safety,replay}"
ALL_PACKAGES="GlucoseCore G7Kit GlucoseStore GlucoseStats AlertEngine TrioBridge NightscoutKit ReplayKit WidgetCore"
PACKAGES="${PACKAGES:-$ALL_PACKAGES}"
SAFETY_RULES="${SAFETY_RULES:-S1 S2 S3 S4 S5 S6 S7 S8}"
SIM_DEST="${SIM_DEST:-platform=iOS Simulator,name=iPhone 17,OS=latest}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOGS="$ROOT/.build-logs/$STAMP"
# Fresh per run so every compile (and therefore every warning) is seen; package checkouts are shared.
BUILD_DD="$LOGS/dd"
SIM_DD="$ROOT/.derived/sim"
SPM_CHECKOUTS="$ROOT/.derived/SourcePackages"
mkdir -p "$LOGS"

# Fresh build trees are ~0.5–1 GB per run; keep only the logs unless asked (KEEP_BUILD_DIRS=1).
cleanup_build_dirs() {
    [ "${KEEP_BUILD_DIRS:-}" = "1" ] && return
    rm -rf "$BUILD_DD" "$LOGS"/spm-*
}
trap cleanup_build_dirs EXIT

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

    for config in Debug Release; do
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
}

# ---------------------------------------------------------------------------------------------
# Gate 2 — unit tests (+ coverage)
# ---------------------------------------------------------------------------------------------
package_tests() {
    pkg="$1"
    dir="$ROOT/Packages/$pkg"
    log="$LOGS/test-$pkg.log"
    scratch="$LOGS/spm-$pkg"
    (cd "$dir" && swift test --enable-code-coverage --scratch-path "$scratch") > "$log" 2>&1
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
    xcodebuild test -project Sensor.xcodeproj -scheme Sensor -destination "$SIM_DEST" \
        -derivedDataPath "$SIM_DD" -clonedSourcePackagesDirPath "$SPM_CHECKOUTS" \
        -only-testing:SensorTests -skip-testing:SensorTests/ReplayScenarioTests \
        CODE_SIGNING_ALLOWED=NO > "$log" 2>&1
    status=$?
    count="$(executed_count "$log")"
    if [ $status -ne 0 ]; then
        fail "app unit tests (exit $status, see $log)"
        grep -E "error:|failed" "$log" | head -20
    elif [ -z "$count" ] || [ "$count" = "0" ]; then
        fail "app unit tests executed no tests"
    else
        pass "app unit tests — $count executed, 0 failures"
    fi
}

gate_tests() {
    note "== Gate 2: unit tests =="
    for pkg in $PACKAGES; do package_tests "$pkg"; done
    if [ "$PACKAGES" = "$ALL_PACKAGES" ] || [ "${APP_TESTS:-}" = "1" ]; then app_tests; fi
}

# ---------------------------------------------------------------------------------------------
# Gate 3 — safety tests (test_S1_… through test_S8_…) and S6 compile-out checks
# ---------------------------------------------------------------------------------------------

# Defined symbols matching $2 in the object files of package $1 built in configuration $3.
symbol_count() {
    pkg="$1"; pattern="$2"; config="$3"
    scratch="$LOGS/spm-nm-$pkg-$config"
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

    # S6: replay code and the replay-accepting gate must not exist in Release builds.
    compiled_out_check ReplayKit '$s9ReplayKit' "ReplayKit"
    compiled_out_check GlucoseCore 'validateAllowingReplay' "LiveReadingGate.validateAllowingReplay"

    # S6 / D11: only the alert engine and the app's replay wiring may call validateAllowingReplay.
    callers="$(grep -rl 'validateAllowingReplay' Packages/*/Sources App/Sources Widgets/Sources 2>/dev/null \
        | grep -vE '^Packages/(GlucoseCore|AlertEngine)/Sources/|^App/Sources/')"
    if [ -n "$callers" ]; then
        fail "S6: validateAllowingReplay used outside AlertEngine/App: $(echo $callers)"
    else
        pass "S6: validateAllowingReplay only in GlucoseCore, AlertEngine, App"
    fi

    # S6: non-test code outside ReplayKit that constructs .replay/.mock readings must sit inside an
    # `#if DEBUG` block (tracked per line through nested #if/#else/#endif; an #else branch of
    # `#if DEBUG` is not guarded).
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
    log="$LOGS/test-app-replay.log"
    xcodebuild test -project Sensor.xcodeproj -scheme Sensor -destination "$SIM_DEST" \
        -derivedDataPath "$SIM_DD" -clonedSourcePackagesDirPath "$SPM_CHECKOUTS" \
        -only-testing:SensorUITests -only-testing:SensorTests/ReplayScenarioTests \
        CODE_SIGNING_ALLOWED=NO > "$log" 2>&1
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
