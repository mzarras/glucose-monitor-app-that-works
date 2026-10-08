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
#           `validateAllowingReplay` absent from Release objects, present in Debug); S6 caller checks;
#           D57 forecast isolation (manifests: ForecastKit's two targets only and no dependencies,
#           no unsafeFlags in any package, nothing depends on ForecastKit; its sources import only
#           Foundation; outside an allowlist of App files (Forecast*/Predict*, Screens/Predict;
#           reading, alert, Trio, upload, widget, intent and Now code denied) no Swift file names
#           ForecastKit at all; no @_exported, no symlinks; project.yml, as XcodeGen resolves it,
#           compiles only scanned directories and links ForecastKit only as a package dependency of
#           Sensor and its test targets; no module-alias/import-module flags).
#   replay  SensorUITests (app launched on each ReplayKit scenario) and SensorTests/ReplayScenarioTests
#           (alert assertions) on the iOS simulator; both suites must run and pass.
#
# Bash 3.2 compatible (macOS /bin/bash). Logs go to .build-logs/<timestamp>/.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

GATES="${GATES:-build,tests,safety,replay}"
ALL_PACKAGES="GlucoseCore G7Kit GlucoseStore GlucoseStats AlertEngine TrioBridge NightscoutKit ReplayKit WidgetCore ForecastKit"
PACKAGES="${PACKAGES:-$ALL_PACKAGES}"
SAFETY_RULES="${SAFETY_RULES:-S1 S2 S3 S4 S5 S6 S7 S8}"
SIM_DEST="${SIM_DEST:-platform=iOS Simulator,name=iPhone 17,OS=latest}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOGS="$ROOT/.build-logs/$STAMP"
# Fresh per run so every compile (and therefore every warning) is seen; package checkouts are shared.
BUILD_DD="$LOGS/dd"
SIM_DD="$ROOT/.derived/sim"
SPM_CHECKOUTS="$ROOT/.derived/SourcePackages"
# Simulator test runs are signed ad hoc ("Sign to Run Locally") so entitlements such as Keychain
# access apply to the hosted tests; no team or provisioning profile is needed for the simulator.
SIM_SIGNING="CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES"
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
        ForecastKit)  echo 90 ;;
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

# S2/S6 safety tests built in the Release configuration (no DEBUG), so `#else` branches such as
# AlertEngine's test_S6_releaseBuildRefusesReplayReadings run too (Phase 3 audit m3). The debug
# runs of gate 2 never compile them. `-enable-testing` keeps `@testable import` working.
RELEASE_SAFETY_PACKAGES="GlucoseCore AlertEngine TrioBridge NightscoutKit"

release_safety_tests() {
    pkg="$1"
    log="$LOGS/reltest-$pkg.log"
    scratch="$LOGS/spm-rel-$pkg"
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

    forecast_isolation_checks
}

# ---------------------------------------------------------------------------------------------
# D57 forecast isolation (run at the end of gate 3). A forecast is never a reading.
#   Packages  every Packages/*/Package.swift as SwiftPM reads it (`swift package dump-package`):
#             ForecastKit has exactly the targets ForecastKit (regular) and ForecastKitTests (test),
#             no package dependencies, no target dependency except ForecastKitTests -> ForecastKit,
#             and no unsafeFlags, linkedLibrary, linkedFramework or plugin usage (binary,
#             system-library and plugin targets fail "exactly"). No package uses unsafeFlags, and no
#             other package depends on a package that is ForecastKit (by name or by real path).
#   Imports   in every file under App/, Widgets/, Packages/, AppTests/ and AppUITests/ (the scan
#             roots; Packages/*/.build skipped):
#             - allowlist (forecast_import_allowed): only files under App/ named Forecast*, Predict*,
#               *+Forecast.swift or *+Predict.swift, anything under App/Sources/Screens/Predict/,
#               AppTests/, AppUITests/ and Packages/ForecastKit/ may name ForecastKit; a deny list
#               (reading, alert, Trio, upload, sharing, history import, sensor, widget, intent and
#               Now-screen code) is applied first and wins;
#             - backstop: a Swift file outside the allowlist that contains the word ForecastKit
#               anywhere (code, comment or string; any line endings) fails. This is what makes the
#               check fail-safe; the matcher (forecast_imports) adds precise import messages;
#             - any `@_exported` fails (raw text, no parsing): it would make a module's names visible
#               in every file of the importing module;
#             - ForecastKit's sources may import Foundation only (the matcher).
#   Symlinks  none under App/, Widgets/, Packages/ (Packages/*/.build skipped), AppTests/,
#             AppUITests/ or Config/: the scans do not follow them, the build would.
#   Project   project.yml as XcodeGen resolves it (`xcodegen dump`: includes, anchors, escapes and
#             templates resolved; fails closed if XcodeGen cannot resolve it):
#             - every target's source paths lie under App/, Widgets/, AppTests/ or AppUITests/;
#               Resources/ only as resources (`buildPhase: resources` or `type: folder`), so the
#               scans above read everything that is compiled;
#             - only Sensor, SensorTests and SensorUITests depend on the ForecastKit package (under
#               any key whose entry names it), and in them ForecastKit appears only as such a
#               dependency, never in sources, settings, config files or schemes; outside `packages:`
#               and those targets nothing names it.
#   Flags     no `module-alias` or `import-module` (which import or rename a module with no import
#             line) in project.yml, Config/*.xcconfig, any Package.swift, their resolved dumps, or
#             this run's build logs (when gate 1 ran: the compile commands themselves).
#   Vacuity   a missing or Swift-free scan root, a missing project.yml, an unreadable manifest and a
#             matcher that finds no import in ForecastKit's sources each fail.
# Out of reach: an allowed file can still hand a forecast value to other code of the same module
# through an app type; with SE-0444 (MemberImportVisibility, enabled on the Sensor target) using its
# members there without importing ForecastKit is a compile error, so the import rules above hold for
# member access too. Run scripts and other build phases are not inspected (review rule,
# docs/forecast.md "Enforcement").
FORECAST_SCAN_DIRS="App Widgets Packages AppTests AppUITests"
FORECAST_SYMLINK_DIRS="App Widgets Packages AppTests AppUITests Config"

# `find` over regular files under the given directories, skipping only SwiftPM's build output
# Packages/<name>/.build (a `.build` anywhere else is compiled by XcodeGen, so it is read). The
# directories come first, then "--", then the rest of the expression, which must end in an action
# (-print or -exec … {} +).
FORECAST_PRUNE="Packages/*/.build"
forecast_find() {
    dirs=""
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do dirs="$dirs $1"; shift; done
    [ $# -gt 0 ] && shift
    find $dirs \( -path "$FORECAST_PRUNE" ! -path 'Packages/*/*/*' \) -prune -o -type f "$@"
}

# Every import declaration, one per line: "path:line<TAB>module". Line endings are normalised first
# (CRLF and CR-only, which awk would read as one record). With strip=1 each file is read with its
# // and /* */ comments removed (nested block comments are tracked across lines); with strip=0 as
# written; forecast_imports lists the union. Each line is split into statements at ";", backticks
# become blanks, and a statement holding only attributes, access modifiers, `import` and an import
# kind (no module yet) is joined with the next non-empty one, so a declaration split over several
# lines is read whole. The matcher is not proof against a "//" or "/*" inside a string combined
# with a comment between the tokens; the backstop is. Grammar: The Swift Programming Language,
# "Declarations > Import Declaration" (import-kind: typealias, struct, class, enum, protocol, let,
# var, func), plus access-level imports (SE-0409).
FORECAST_IMPORTS_AWK='
BEGIN {
    ATTR = "@[A-Za-z_][A-Za-z0-9_]*([[:space:]]*[(][^)]*[)])?"
    MOD = "(public|internal|package|private|fileprivate|open)"
    KIND = "(typealias|struct|class|enum|protocol|let|var|func)"
    LEAD = "((" ATTR ")[[:space:]]*|" MOD "[[:space:]]+)*"
    HEAD = "^" LEAD "import[[:space:]]+(" KIND "[[:space:]]+)?"
    PREFIX_ONLY = "^" LEAD "(import[[:space:]]+(" KIND "[[:space:]]+)?)?$"
}
function without_comments(text,    out, i, n, two, at) {
    if (depth == 0 && index(text, "/*") == 0) {
        at = index(text, "//")
        return at ? substr(text, 1, at - 1) : text
    }
    out = ""; n = length(text); i = 1
    while (i <= n) {
        two = substr(text, i, 2)
        if (depth > 0) {
            if (two == "/*") { depth++; i += 2 }
            else if (two == "*/") { depth--; i += 2; if (depth == 0) out = out " " }
            else i++
            continue
        }
        if (two == "//") break
        if (two == "/*") { depth = 1; i += 2; continue }
        out = out substr(text, i, 1); i++
    }
    return out
}
function scan(text,    n, p, s, head, rest) {
    if (strip) text = without_comments(text)
    gsub(/`/, " ", text)
    n = split(text, parts, ";")
    for (p = 1; p <= n; p++) {
        s = parts[p]
        sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s)
        if (s == "") continue
        if (pending != "") { s = pending " " s; pending = "" }
        if ((s " ") ~ PREFIX_ONLY) { pending = s; continue }
        if (match(s, HEAD)) {
            head = substr(s, 1, RLENGTH)
            rest = substr(s, RLENGTH + 1)
            if (match(rest, /^[A-Za-z_][A-Za-z0-9_]*/))
                printf "%s:%d\t%s\n", FILENAME, line, substr(rest, 1, RLENGTH)
        }
    }
}
FNR == 1 { pending = ""; depth = 0; line = 0 }
{
    record = $0
    sub(/\r$/, "", record)                 # CRLF
    count = split(record, lines, "\r")     # a CR-only file arrives as one record
    if (count == 0) { count = 1; lines[1] = "" }
    for (k = 1; k <= count; k++) {
        line++
        text = lines[k]
        if (line == 1 && substr(text, 1, 3) == "\357\273\277") text = substr(text, 4)
        scan(text)
    }
}'

# The import declarations in every Swift file under the given directories.
forecast_imports() {
    for strip in 0 1; do
        forecast_find "$@" -- -name '*.swift' -exec env LC_ALL=C awk -v strip="$strip" "$FORECAST_IMPORTS_AWK" {} +
    done | sort -u
}

# Succeeds if the file at repo-relative path $1 may import or name ForecastKit. The deny list comes
# first and wins over the names below it.
forecast_import_allowed() {
    case "$1" in
        Widgets/*) return 1 ;;
        App/Sources/Pipeline/*|App/Sources/WidgetBridge/*|App/Sources/Intents/*) return 1 ;;
        App/Sources/Screens/Now/*|App/Sources/Screens/Alerts/*|App/Sources/ViewState/Now*) return 1 ;;
        App/Sources/Composition/AlertPorts*|App/Sources/Model/ViewStateMapping*|App/Sources/Model/NowMapping*) return 1 ;;
        App/Sources/*Alert*|App/Sources/*Trio*|App/Sources/*Upload*|App/Sources/*Sharing*) return 1 ;;
        App/Sources/*Widget*|App/Sources/*Pipeline*|App/Sources/*HistoryImport*|App/Sources/*SensorDevice*) return 1 ;;
    esac
    case "$1" in
        Packages/ForecastKit/*|App/Sources/Screens/Predict/*|AppTests/*|AppUITests/*) return 0 ;;
        App/*) ;;
        *) return 1 ;;
    esac
    case "${1##*/}" in
        Forecast*|Predict*|*+Forecast.swift|*+Predict.swift) return 0 ;;
    esac
    return 1
}

# The file with LF line endings (CRLF and CR-only converted), for line numbers.
forecast_lf() { sed "s/$(printf '\r')\$//" "$1" | tr '\r' '\n'; }

forecast_import_checks() {
    roots=""
    for dir in $FORECAST_SCAN_DIRS; do
        if [ -d "$dir" ] && [ -n "$(forecast_find "$dir" -- -name '*.swift' -print | head -n 1)" ]; then
            roots="$roots $dir"
        else
            fail "D57: scan root $dir is missing or holds no Swift files"
        fi
    done
    [ -n "$roots" ] || return

    # Backstop: the word ForecastKit anywhere in a Swift file outside the allowlist.
    forecast_find $roots -- -name '*.swift' -exec grep -alw ForecastKit {} + > "$LOGS/forecast-word-files.txt" 2>/dev/null
    named=""; allowed_files=0
    while IFS= read -r file; do
        if forecast_import_allowed "$file"; then allowed_files=$((allowed_files + 1)); continue; fi
        lines="$(forecast_lf "$file" | grep -anw ForecastKit | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')"
        named="$named $file:${lines:-?}"
    done < "$LOGS/forecast-word-files.txt"
    if [ -n "$named" ]; then
        fail "D57: ForecastKit named outside its allowlist:$named"
    else
        pass "D57: ForecastKit named only in allowlisted files ($allowed_files files)"
    fi

    # `@_exported` in any file, as raw text.
    exported="$(forecast_find $roots -- -exec grep -aHn '@_exported' {} + 2>/dev/null | cut -d: -f1,2)"
    if [ -n "$exported" ]; then
        fail "D57: @_exported (re-exports a module to every file of the importer): $(echo $exported)"
    else
        pass "D57: no @_exported under the scan roots"
    fi

    # The matcher: precise messages for imports outside the allowlist, and Foundation-only sources.
    imports="$LOGS/forecast-imports.tsv"
    forecast_imports $roots > "$imports"
    tab="$(printf '\t')"
    own=0; foreign=""; outside=""
    while IFS="$tab" read -r place module; do
        file="${place%:*}"
        case "$file" in
            Packages/ForecastKit/Sources/*)
                if [ "$module" = "Foundation" ]; then own=$((own + 1)); else foreign="$foreign $place($module)"; fi ;;
        esac
        if [ "$module" = "ForecastKit" ] && ! forecast_import_allowed "$file"; then outside="$outside $place"; fi
    done < "$imports"
    if [ -n "$foreign" ]; then
        fail "D57: ForecastKit imports modules other than Foundation:$foreign"
    elif [ "$own" -eq 0 ]; then
        fail "D57: the import matcher found no import in ForecastKit's sources; the import checks would pass vacuously"
    else
        pass "D57: ForecastKit sources import only Foundation ($own imports)"
    fi
    if [ -n "$outside" ]; then
        fail "D57: ForecastKit imported outside its allowlist:$outside"
    fi
}

forecast_symlink_check() {
    links=""
    for dir in $FORECAST_SYMLINK_DIRS; do
        [ -e "$dir" ] || continue
        links="$links $(find "$dir" \( -path "$FORECAST_PRUNE" ! -path 'Packages/*/*/*' \) -prune -o -type l -print)"
    done
    if [ -n "$(echo $links)" ]; then
        fail "D57: symbolic links (the scans do not follow them; the build would): $(echo $links)"
    else
        pass "D57: no symbolic links under $FORECAST_SYMLINK_DIRS"
    fi
}

# `plutil -extract KEYPATH raw` prints a string, an array's element count, or a dictionary's keys
# one per line; nothing (and a failure) if the key path does not exist or holds null.
forecast_field() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

forecast_manifest_check() {
    manifest="$LOGS/package-ForecastKit.json"
    if ! (cd "$ROOT/Packages/ForecastKit" && swift package dump-package) > "$manifest" 2> "$LOGS/forecastkit-manifest.log"; then
        fail "D57: could not read Packages/ForecastKit/Package.swift (see $LOGS/forecastkit-manifest.log)"
        return
    fi
    problems=0
    deps="$(forecast_field "$manifest" dependencies)"
    if [ "$deps" != "0" ]; then
        fail "D57: ForecastKit declares ${deps:-unknown} package dependencies; it must depend on nothing"
        problems=1
    fi
    count="$(forecast_field "$manifest" targets)"
    targets=""; edges=""; i=0
    while [ "$i" -lt "${count:-0}" ]; do
        name="$(forecast_field "$manifest" "targets.$i.name")"
        targets="$targets $name($(forecast_field "$manifest" "targets.$i.type"))"
        n="$(forecast_field "$manifest" "targets.$i.dependencies")"
        j=0
        while [ "$j" -lt "${n:-0}" ]; do
            dep=""
            for kind in byName target product; do
                found="$(forecast_field "$manifest" "targets.$i.dependencies.$j.$kind.0")"
                if [ -n "$found" ]; then dep="$kind:$found"; break; fi
            done
            case "$name->$dep" in
                "ForecastKitTests->byName:ForecastKit"|"ForecastKitTests->target:ForecastKit") ;;
                *) edges="$edges $name->${dep:-unknown}" ;;
            esac
            j=$((j + 1))
        done
        plugins="$(forecast_field "$manifest" "targets.$i.pluginUsages")"
        if [ -n "$plugins" ] && [ "$plugins" != "0" ]; then edges="$edges $name->plugins"; fi
        i=$((i + 1))
    done
    targets="$(printf '%s\n' $targets | sort | tr '\n' ' ')"
    if [ "$targets" != "ForecastKit(regular) ForecastKitTests(test) " ]; then
        fail "D57: ForecastKit's targets are: ${targets}but must be exactly ForecastKit(regular) ForecastKitTests(test)"
        problems=1
    fi
    if [ -n "$edges" ]; then
        fail "D57: ForecastKit has target dependencies other than ForecastKitTests->ForecastKit:$edges"
        problems=1
    fi
    settings="$(grep -oE '"(unsafeFlags|linkedLibrary|linkedFramework)"' "$manifest" | tr -d '"' | sort -u | tr '\n' ' ')"
    if [ -n "$settings" ]; then
        fail "D57: ForecastKit's manifest uses settings it may not: $settings"
        problems=1
    fi
    if [ "$problems" -eq 0 ]; then
        pass "D57: ForecastKit manifest: targets ForecastKit and ForecastKitTests only, no dependencies, no unsafe flags, linked libraries or plugins"
    fi
}

# Every other package, as SwiftPM reads it: no unsafeFlags, and no dependency that is ForecastKit
# (its identity names it, or a local path resolves to Packages/ForecastKit).
forecast_package_checks() {
    forecastkit="$(cd "$ROOT/Packages/ForecastKit" 2>/dev/null && pwd -P)"
    unsafe=""; depends=""; unreadable=""; checked=0
    for manifest_file in Packages/*/Package.swift; do
        pkg="${manifest_file#Packages/}"; pkg="${pkg%/Package.swift}"
        [ "$pkg" = "ForecastKit" ] && continue
        dump="$LOGS/package-$pkg.json"
        if ! (cd "$ROOT/Packages/$pkg" && swift package dump-package) > "$dump" 2> "$LOGS/package-$pkg.log"; then
            unreadable="$unreadable $pkg"; continue
        fi
        checked=$((checked + 1))
        if grep -q '"unsafeFlags"' "$dump"; then unsafe="$unsafe $pkg"; fi
        n="$(forecast_field "$dump" dependencies)"
        i=0
        while [ "$i" -lt "${n:-0}" ]; do
            entry="$(plutil -extract "dependencies.$i" json -o - "$dump" 2>/dev/null)"
            path="$(forecast_field "$dump" "dependencies.$i.fileSystem.0.path")"
            real="$( [ -n "$path" ] && cd "$path" 2>/dev/null && pwd -P)"
            if printf '%s' "$entry" | grep -qiw forecastkit || { [ -n "$real" ] && [ "$real" = "$forecastkit" ]; }; then
                depends="$depends $pkg"
            fi
            i=$((i + 1))
        done
    done
    if [ -n "$unreadable" ]; then fail "D57: could not read the manifests of:$unreadable (see $LOGS/package-*.log)"; fi
    if [ -n "$unsafe" ]; then fail "D57: unsafeFlags in the manifests of:$unsafe"; fi
    if [ -n "$depends" ]; then fail "D57: packages depending on ForecastKit:$depends"; fi
    if [ -z "$unreadable$unsafe$depends" ]; then
        pass "D57: $checked other packages: no unsafeFlags, none depends on ForecastKit"
    fi
}

# Linkage, from two XcodeGen dumps of project.yml: "json" is the resolved spec (includes merged, YAML
# anchors and escapes resolved; templates not yet applied; a dependency's `products:` kept) and
# "parsed-json" is the project XcodeGen builds from it (templates applied; `products:` dropped).
FORECAST_LINK_TARGETS="Sensor SensorTests SensorUITests"

# Succeeds if the value at key path $2 of dump $1 contains one of $words, or cannot be read.
# (`json` refuses a bare string or number; `raw` prints those.)
forecast_dump_names() {
    value="$(plutil -extract "$2" json -o - "$1" 2>/dev/null || plutil -extract "$2" raw -o - "$1" 2>/dev/null)" || return 0
    for word in $words; do
        printf '%s' "$value" | grep -qw "$word" && return 0
    done
    return 1
}

# Succeeds if a source entry may be compiled into a target: under App/, Widgets/, AppTests/ or
# AppUITests/, or under Resources/ as resources only. $1 path, $2 buildPhase, $3 type. Absolute
# paths and ".." are refused rather than resolved.
forecast_source_allowed() {
    path="$(printf '%s' "$1" | tr -s '/')"
    while :; do case "$path" in ./*) path="${path#./}" ;; *) break ;; esac; done
    path="${path%/}"
    case "$path" in ''|/*|..|../*|*/..|*/../*) return 1 ;; esac
    case "$path" in
        App|App/*|Widgets|Widgets/*|AppTests|AppTests/*|AppUITests|AppUITests/*) return 0 ;;
        Resources|Resources/*) [ "$2" = "resources" ] || [ "$3" = "folder" ] ;;
        *) return 1 ;;
    esac
}

forecast_project_check() {
    if ! command -v xcodegen > /dev/null 2>&1; then
        fail "D57: xcodegen not installed; the project checks cannot run"
        return
    fi
    spec="$LOGS/xcodegen-spec.json"; built="$LOGS/xcodegen-project.json"
    if [ ! -f project.yml ] \
        || ! xcodegen dump --type json --file "$spec" > "$LOGS/xcodegen-dump.log" 2>&1 \
        || ! xcodegen dump --type parsed-json --file "$built" >> "$LOGS/xcodegen-dump.log" 2>&1 \
        || [ -z "$(forecast_field "$spec" targets)" ] || [ -z "$(forecast_field "$built" targets)" ]; then
        fail "D57: XcodeGen could not resolve project.yml (see $LOGS/xcodegen-dump.log); the project checks cannot run"
        return
    fi

    # Source paths of every target (parsed-json: templates applied).
    sources=""
    for target in $(forecast_field "$built" targets); do
        n="$(forecast_field "$built" "targets.$target.sources")"
        i=0
        while [ "$i" -lt "${n:-0}" ]; do
            path="$(forecast_field "$built" "targets.$target.sources.$i.path")"
            phase="$(forecast_field "$built" "targets.$target.sources.$i.buildPhase")"
            kind="$(forecast_field "$built" "targets.$target.sources.$i.type")"
            if ! forecast_source_allowed "$path" "$phase" "$kind"; then sources="$sources $target:${path:-?}"; fi
            i=$((i + 1))
        done
    done
    if [ -n "$sources" ]; then
        fail "D57: target sources outside App/, Widgets/, AppTests/, AppUITests/ (or Resources/ as resources):$sources"
    else
        pass "D57: every target compiles only from App/, Widgets/, AppTests/, AppUITests/ (Resources/ as resources)"
    fi

    # The package keys that are ForecastKit: the key itself, or any entry whose path or URL names
    # it (an unreadable entry counts, to fail closed).
    keys=""
    for key in $(forecast_field "$built" packages); do
        words="ForecastKit"
        if [ "$key" = "ForecastKit" ] || forecast_dump_names "$built" "packages.$key"; then keys="$keys $key"; fi
    done
    words="ForecastKit$(printf ' %s' $keys)"
    links=""
    # parsed-json: other targets' package dependencies, templates applied.
    for target in $(forecast_field "$built" targets); do
        case " $FORECAST_LINK_TARGETS " in *" $target "*) continue ;; esac
        if ! plutil -extract "targets.$target" json -o - "$built" > /dev/null 2>&1; then
            links="$links targets.$target(unreadable)"; continue
        fi
        n="$(forecast_field "$built" "targets.$target.dependencies")"
        i=0
        while [ "$i" -lt "${n:-0}" ]; do
            package="$(forecast_field "$built" "targets.$target.dependencies.$i.package")"
            case " $keys " in *" $package "*) links="$links targets.$target->$package" ;; esac
            i=$((i + 1))
        done
    done
    # json: in the allowed targets, ForecastKit only as a package dependency on a ForecastKit key;
    # anywhere else outside `packages:`, not at all (another target's `products:`, a template, a
    # scheme, settings, config files, anything).
    for section in $(plutil -p "$spec" | sed -n 's/^  "\([^"]*\)" => .*/\1/p'); do
        case "$section" in
            packages) ;;
            targets)
                for target in $(forecast_field "$spec" targets); do
                    case " $FORECAST_LINK_TARGETS " in
                        *" $target "*)
                            n="$(forecast_field "$spec" "targets.$target.dependencies")"
                            i=0
                            while [ "$i" -lt "${n:-0}" ]; do
                                if forecast_dump_names "$spec" "targets.$target.dependencies.$i"; then
                                    package="$(forecast_field "$spec" "targets.$target.dependencies.$i.package")"
                                    case " $keys " in *" $package "*) ;; *) links="$links targets.$target.dependencies.$i" ;; esac
                                fi
                                i=$((i + 1))
                            done
                            rest="$LOGS/xcodegen-target-$target.json"
                            if ! plutil -extract "targets.$target" json -o "$rest" "$spec" 2>/dev/null; then
                                links="$links targets.$target(unreadable)"; continue
                            fi
                            plutil -remove dependencies "$rest" > /dev/null 2>&1
                            for word in $words; do
                                if grep -qw "$word" "$rest"; then links="$links targets.$target(outside-dependencies)"; break; fi
                            done ;;
                        *)
                            if forecast_dump_names "$spec" "targets.$target"; then links="$links targets.$target"; fi ;;
                    esac
                done ;;
            *)
                if forecast_dump_names "$spec" "$section"; then links="$links $section"; fi ;;
        esac
    done
    if [ -n "$links" ]; then
        fail "D57: project.yml links or names ForecastKit outside the Sensor app's and its tests' package dependencies: $(printf '%s\n' $links | sort -u | tr '\n' ' ')"
    else
        pass "D57: ForecastKit only a package dependency of the Sensor app and its test targets (project.yml as XcodeGen resolves it)"
    fi
}

# Swift flags that import or rename a module without an import line in the source.
FORECAST_FLAG_RE='module-alias|import-module|moduleAliases'

forecast_flag_checks() {
    found="$(grep -nE "$FORECAST_FLAG_RE" project.yml Config/*.xcconfig Packages/*/Package.swift 2>/dev/null | cut -d: -f1,2)"
    for dump in "$LOGS"/xcodegen-spec.json "$LOGS"/xcodegen-project.json "$LOGS"/package-*.json; do
        if [ -f "$dump" ] && grep -qE "$FORECAST_FLAG_RE" "$dump"; then found="$found ${dump##*/}"; fi
    done
    logs_read=""
    for log in "$LOGS"/build-*.log; do
        [ -f "$log" ] || continue
        logs_read="$logs_read ${log##*/}"
        if grep -qE -- '(^|[[:space:]"])-(module-alias|import-module)([[:space:]=]|$)' "$log"; then found="$found ${log##*/}"; fi
    done
    if [ -n "$found" ]; then
        fail "D57: module-alias/import-module (imports or renames a module without an import line): $(echo $found)"
    else
        pass "D57: no module-alias/import-module in project.yml, Config/*.xcconfig or the manifests${logs_read:+, nor in the compile commands of$logs_read}"
    fi
}

forecast_isolation_checks() {
    forecast_manifest_check
    forecast_package_checks
    forecast_import_checks
    forecast_symlink_check
    forecast_project_check
    forecast_flag_checks
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
