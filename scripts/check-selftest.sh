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
# run of only some gates, with failures). Runs after the planted-defect passes, in the same worktree.
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

if [ $mode_missing -ne 0 ]; then
    echo "check-selftest: FAILED (D60 mode checks) — fast-mode output in $OUT_FAST"
    cp "$OUT_FAST" "$ROOT/.build-logs/check-selftest-last-fast.txt" 2>/dev/null
    exit 1
fi
echo "check-selftest: fast runs are marked and never pass --verify-certify."
