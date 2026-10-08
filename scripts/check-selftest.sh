#!/usr/bin/env bash
# Proves scripts/check.sh fails on planted defects (Phase 0 review B1, M3, m6).
# Runs in a throwaway git worktree of HEAD; never touches your working tree.
#
# Planted: a Release-only failing S2 test, a compiler warning in GlucoseCore (after warming a cache, so a cached build would hide
# it), a skipped safety test, a safety test that "passes" via XCTExpectFailure (separate files), a
# ReplayKit symbol that leaks into Release, a .mock reading built outside #if DEBUG, and a package
# with zero tests (WidgetCore's Phase 0 placeholder, if still present). Every plant must be reported.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/check-selftest.XXXXXX")"
WT="$TMP/wt"
trap 'git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1; rm -rf "$TMP"' EXIT

git -C "$ROOT" worktree add --detach --quiet "$WT" HEAD || exit 2
cd "$WT"

cat >> Packages/GlucoseCore/Sources/GlucoseCore/GlucoseUnit.swift <<'SWIFT'

func checkSelftestPlantedWarning() { let unusedValue = 1 }
SWIFT
cat > Packages/GlucoseCore/Tests/GlucoseCoreTests/CheckSelftestSkip.swift <<'SWIFT'
import XCTest

final class CheckSelftestSkip: XCTestCase {
    func test_S5_plantedSkip() throws { throw XCTSkip("planted by check-selftest") }
}
SWIFT
cat > Packages/GlucoseCore/Tests/GlucoseCoreTests/CheckSelftestExpectFailure.swift <<'SWIFT'
import XCTest

final class CheckSelftestExpectFailure: XCTestCase {
    func test_S7_plantedExpectedFailure() { XCTExpectFailure("planted"); XCTFail("planted") }
}
SWIFT
# A safety test that fails only in the Release configuration (gate 2 runs debug, so only the
# Release S2/S6 step can catch it; Phase 3 review m7).
cat > Packages/GlucoseCore/Tests/GlucoseCoreTests/CheckSelftestReleaseOnly.swift <<'SWIFT'
import XCTest

#if !DEBUG
final class CheckSelftestReleaseOnly: XCTestCase {
    func test_S2_plantedReleaseOnlyFailure() { XCTFail("planted by check-selftest") }
}
#endif
SWIFT
# A Release symbol leak: ReplayKit code outside #if DEBUG.
cat > Packages/ReplayKit/Sources/ReplayKit/CheckSelftestLeak.swift <<'SWIFT'
public enum CheckSelftestLeak { public static func leaked() -> Int { 1 } }
SWIFT
# A .mock reading constructed outside an #if DEBUG block, in a file that has one elsewhere.
cat > App/Sources/CheckSelftestMock.swift <<'SWIFT'
import Foundation
import GlucoseCore

#if DEBUG
let checkSelftestGuarded = 1
#endif

let checkSelftestMock = GlucoseReading(
    id: "x", date: .distantPast, value: .mgdl(100), trendRate: nil, isBackfill: false,
    source: .mock, sensorSerial: ""
)
SWIFT
# Warm a cache the way a developer would before running the gate.
(cd Packages/GlucoseCore && swift build) > /dev/null 2>&1

OUT="$TMP/out.txt"
GATES=build,tests,safety PACKAGES="GlucoseCore WidgetCore" SAFETY_RULES="S5 S7" scripts/check.sh > "$OUT" 2>&1
status=$?

missing=0
expect() {
    if grep -qE "$1" "$OUT"; then echo "ok    reported: $2"; else echo "MISS  not reported: $2"; missing=1; fi
}
expect '^FAIL  build Debug has warnings' "warning in app Debug build"
expect '^FAIL  GlucoseCore has warnings' "warning in swift test build"
expect '^FAIL  S5: 1 skipped safety test' "skipped safety test"
expect '^FAIL  safety tests live in files using XCTSkip/XCTExpectFailure:.*CheckSelftestSkip' "XCTSkip in a safety-test file"
expect '^FAIL  safety tests live in files using XCTSkip/XCTExpectFailure:.*CheckSelftestExpectFailure' "XCTExpectFailure in a safety-test file"
expect '^FAIL  S6: ReplayKit defines [0-9]+ symbols in Release' "ReplayKit symbol leak into Release"
expect '^FAIL  S2/S6 Release-configuration tests in GlucoseCore' "safety test failing only in Release"
expect '^FAIL  S6: .replay/.mock readings constructed outside #if DEBUG at: .*CheckSelftestMock.swift:[0-9]+' ".mock construction outside #if DEBUG"
if [ -f Packages/WidgetCore/Tests/WidgetCoreTests/Placeholder.swift ]; then
    expect '^FAIL  WidgetCore executed no tests' "package with zero tests"
fi
if [ $status -eq 0 ]; then echo "MISS  check.sh exited 0"; missing=1; else echo "ok    check.sh exited $status"; fi

if [ $missing -ne 0 ]; then
    echo "check-selftest: FAILED — output in $OUT"; cp "$OUT" "$ROOT/.build-logs/check-selftest-last.txt" 2>/dev/null
    exit 1
fi
echo "check-selftest: all planted defects were caught."

# ---------------------------------------------------------------------------------------------
# D60: a fast run announces itself, still fails when a check fails, and its logs never pass
# `check.sh --verify-certify`, even with the MODE file rewritten; nor do pass 1's logs (a certify
# run of only some gates, with failures). Certify refuses ONLY_TESTING/PKG_FILTER. Synthetic logs:
# a complete certify log passes --verify-certify and each single change to it fails. Runs after
# the planted-defect passes, in the same worktree.
# ---------------------------------------------------------------------------------------------
BANNER='FAST MODE: incremental; warnings in unchanged files are not re-reported; NOT valid for merge'
mode_missing=0
mode_ok()   { echo "ok    $*"; }
mode_miss() { echo "MISS  $*"; mode_missing=1; }
logs_of()   { sed -n 's/^== Summary (\(.*\)) ==$/\1/p' "$1" | tail -n 1; }

OUT_FAST="$TMP/out-fast.txt"
CHECK_MODE=fast GATES=safety PACKAGES=GlucoseCore SAFETY_RULES=S5 scripts/check.sh > "$OUT_FAST" 2>&1
status=$?
if [ "$(head -n 1 "$OUT_FAST")" = "$BANNER" ]; then mode_ok "fast mode: the banner is the first line"; else mode_miss "fast mode: the first line is not the banner"; fi
if [ "$(tail -n 1 "$OUT_FAST")" = "$BANNER" ]; then mode_ok "fast mode: the banner is the last line"; else mode_miss "fast mode: the last line is not the banner"; fi
if [ $status -ne 0 ]; then mode_ok "fast mode: exited $status on a failing check"; else mode_miss "fast mode: exited 0 although a check failed"; fi
FAST_LOGS="$(logs_of "$OUT_FAST")"
case "$FAST_LOGS" in
    *-fast) mode_ok "fast mode: log directory name ends in -fast" ;;
    *) mode_miss "fast mode: log directory '$FAST_LOGS' is not named *-fast" ;;
esac
if [ "$(cat "$FAST_LOGS/MODE" 2>/dev/null)" = "fast" ]; then mode_ok "fast mode: MODE file says fast"; else mode_miss "fast mode: MODE file does not say fast"; fi

# verify_rejects <log dir> <regex the rejection must print> <label>
verify_rejects() {
    if scripts/check.sh --verify-certify "$1" > "$TMP/verify.txt" 2>&1; then
        mode_miss "--verify-certify accepted $3"; cat "$TMP/verify.txt"; return
    fi
    if grep -qE "$2" "$TMP/verify.txt"; then mode_ok "--verify-certify rejects $3"
    else mode_miss "--verify-certify rejected $3 without reporting: $2"; cat "$TMP/verify.txt"; fi
}
verify_rejects "$FAST_LOGS" '^  - mode is fast' "a fast run's logs"
FORGED="$TMP/fast-logs-relabelled"
cp -R "$FAST_LOGS" "$FORGED" && echo certify > "$FORGED/MODE"
verify_rejects "$FORGED" '^  - RUN record says mode=fast' "fast logs relabelled certify (run record)"
verify_rejects "$FORGED" '^  - build trees not fresh: generic-iOS derived data was .*/\.derived/fast-build' "fast logs relabelled certify (build trees)"
verify_rejects "$(logs_of "$OUT")" '^  - gates were ' "pass 1's certify logs (some gates only)"
verify_rejects "$(logs_of "$OUT")" '^  - exit status 1' "pass 1's certify logs (exit 1)"

# Certify refuses a test selection before doing any work: an exported ONLY_TESTING or PKG_FILTER
# must never narrow a merge run (D18).
for selection in PKG_FILTER=test_ ONLY_TESTING=SensorTests/AppShellTests; do
    logs_before="$(ls .build-logs 2>/dev/null | wc -l)"
    env "$selection" scripts/check.sh > "$TMP/refused.txt" 2>&1
    status=$?
    logs_after="$(ls .build-logs 2>/dev/null | wc -l)"
    if [ $status -eq 2 ] && grep -q 'targeted runs need CHECK_MODE=fast' "$TMP/refused.txt" \
        && [ "$logs_before" = "$logs_after" ] && ! grep -q '^== Gate' "$TMP/refused.txt"; then
        mode_ok "certify with $selection exits 2 before any work"
    else
        mode_miss "certify with $selection: exit $status, log directories $logs_before -> $logs_after:"; cat "$TMP/refused.txt"
    fi
done

# --verify-certify on synthetic logs (nothing is built): a complete certify log is ACCEPTED, and
# each single change to it is REJECTED, for the reason named in the table below.
GOOD="$TMP/certify-good"
mkdir -p "$GOOD"
HEAD_SHA="$(git rev-parse HEAD)"
SYN_PACKAGES="$(sed -n 's/^ALL_PACKAGES="\(.*\)"$/\1/p' scripts/check.sh)"
echo certify > "$GOOD/MODE"
echo 0 > "$GOOD/EXIT_STATUS"
scripts/check.sh --certify-requirements | sed -e 's/<n>/1/g' -e 's/^/PASS  /' > "$GOOD/summary.txt"
cat > "$GOOD/RUN" <<RUN
mode=certify
logs=$GOOD
commit=$HEAD_SHA
branch=selftest
dirty=0
check_sh=$(git hash-object scripts/check.sh)
gates=build,tests,safety,replay
packages=$SYN_PACKAGES
all_packages=$SYN_PACKAGES
safety_rules=S1 S2 S3 S4 S5 S6 S7 S8
only_testing=
pkg_filter=
build_dd=$GOOD/dd
spm_scratch=$GOOD/spm-<pkg>
sim_dest_given=
sim=sensor-check-1 (synthetic)
sim_reset=erased
complete=yes
commit_end=$HEAD_SHA
dirty_end=0
RUN
# verify_case <label> accept|reject <regex the output must contain> <log dir> [<commit>]
verify_case() {
    scripts/check.sh --verify-certify "$4" ${5:+"$5"} > "$TMP/verify.txt" 2>&1
    status=$?
    case "$2:$status" in
        accept:0|reject:1)
            if grep -qE -- "$3" "$TMP/verify.txt"; then mode_ok "--verify-certify ${2}s $1"
            else mode_miss "--verify-certify ${2}ed $1 without reporting: $3"; cat "$TMP/verify.txt"; fi ;;
        *)  mode_miss "--verify-certify on $1: exit $status, expected to $2"; cat "$TMP/verify.txt" ;;
    esac
}
verify_case "a complete certify log (positive control, no commit given)" accept 'no commit given' "$GOOD"
verify_case "a complete certify log of the given commit (positive control)" accept '^verify-certify: OK' "$GOOD" "$HEAD_SHA"
cp -R "$GOOD" "$TMP/certify-simdest" && echo "sim_dest_given=platform=iOS Simulator,id=X" >> "$TMP/certify-simdest/RUN"
verify_case "a complete certify log on the caller's SIM_DEST (with a warning)" accept "caller's SIM_DEST" "$TMP/certify-simdest" "$HEAD_SHA"

# mutate <case> <dir>: one change to the complete log. drop:<regex> removes summary lines.
mutate() {
    case "$1" in
        drop:*)        grep -vE "${1#drop:}" "$2/summary.txt" > "$2/s.tmp"; mv "$2/s.tmp" "$2/summary.txt" ;;
        exit-1)        echo 1 > "$2/EXIT_STATUS" ;;
        exit-missing)  rm "$2/EXIT_STATUS" ;;
        interrupted)   echo "interrupted (exit 143)" > "$2/EXIT_STATUS"; echo complete=no >> "$2/RUN" ;;
        not-complete)  echo complete=no >> "$2/RUN" ;;
        skip-line)     echo "SKIP  build Release (fast mode; FAST_RELEASE=1 builds it)" >> "$2/summary.txt" ;;
        fail-line)     echo "FAIL  S5: 1 skipped safety test(s)" >> "$2/summary.txt" ;;
        no-summary)    rm "$2/summary.txt" ;;
        no-run)        rm "$2/RUN" ;;
        mode-fast)     echo fast > "$2/MODE" ;;
        mode-missing)  rm "$2/MODE" ;;
        set:*)         echo "${1#set:}" >> "$2/RUN" ;;
        other-commit)  : ;;
    esac
}
case_n=0
while IFS='|' read -r change reason; do
    [ -n "$change" ] || continue
    case_n=$((case_n + 1))
    C="$TMP/certify-case-$case_n"
    cp -R "$GOOD" "$C"
    mutate "$change" "$C"
    if [ "$change" = other-commit ]; then verify_case "$change" reject "$reason" "$C" "$(git rev-parse HEAD~1)"
    else verify_case "$change" reject "$reason" "$C" "$HEAD_SHA"; fi
done <<'TABLE'
exit-1|exit status 1
exit-missing|exit status missing
interrupted|did not reach its summary
not-complete|did not reach its summary
skip-line|1 SKIP line
fail-line|1 FAIL line
no-summary|no summary.txt
no-run|no RUN record
mode-fast|mode is fast
mode-missing|no MODE file
set:mode=fast|RUN record says mode=fast
other-commit|commit is [0-9a-f]+, not
drop:^PASS  S8: |no PASS line for: .*S8: <n> passing
drop:^PASS  build Release|no PASS line for: .*build Release
drop:suite SensorUITests|no PASS line for: .*suite SensorUITests
drop:suite ReplayScenarioTests|no PASS line for: .*suite ReplayScenarioTests
drop:^PASS  GlucoseStats line coverage|no PASS line for: .*GlucoseStats line coverage
drop:^PASS  GlucoseCore tests|no PASS line for: .*GlucoseCore tests
drop:writeSentinel|no PASS line for: .*writeSentinel
drop:mock construction|no PASS line for: .*mock construction
drop:validateAllowingReplay only in|no PASS line for: .*validateAllowingReplay only in
drop:ReplayKit absent from Release|no PASS line for: .*ReplayKit absent from Release
drop:in NightscoutKit|no PASS line for: .*Release-configuration tests in NightscoutKit
set:dirty=2|2 uncommitted change.* at the start
set:dirty_end=1|uncommitted change.* at the end
set:commit_end=0000000000000000000000000000000000000000|HEAD moved during the run
set:only_testing=SensorTests/AppShellTests|ONLY_TESTING was set
set:pkg_filter=test_|PKG_FILTER was set
set:build_dd=/wt/.derived/fast-build|build trees not fresh: generic-iOS
set:spm_scratch=/wt/.derived/fast-spm/<pkg>|build trees not fresh: SwiftPM
set:gates=build,tests,safety|gates were 'build,tests,safety'
set:packages=GlucoseCore AlertEngine|packages were
set:safety_rules=S1 S2 S3|safety rules were
set:check_sh=0000000|another scripts/check.sh
TABLE

if [ $mode_missing -ne 0 ]; then
    echo "check-selftest: FAILED (D60 mode checks) — fast-mode output in $OUT_FAST"
    cp "$OUT_FAST" "$ROOT/.build-logs/check-selftest-last-fast.txt" 2>/dev/null
    exit 1
fi
echo "check-selftest: fast runs are marked, certify refuses test selections, and --verify-certify accepts only a complete certify log."
